// ===----------------------------------------------------------------------===//
//
// This source file is part of the swift-process open source project
//
// Copyright (c) 2026 Coen ten Thije Boonkkamp and the swift-process project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// ===----------------------------------------------------------------------===//

#if os(Windows)

    internal import Windows_Kernel_File
    internal import Windows_Kernel_Process
    internal import WinSDK

    extension Process.Spawn {
        /// Slow path: configurations with ``Process/Stream/pipe`` streams
        /// or a non-`nil`
        /// ``Process/Spawn/Configuration/workingDirectory``.
        ///
        /// Steps:
        /// 1. Build a ``Windows/32/Kernel/Process/Spawn/Actions`` builder.
        /// 2. For each `.pipe` stream, create an anonymous pipe via
        ///    `CreatePipe`, set the parent-side handle non-inheritable, and
        ///    mark the child-side handle inheritable + add it to the
        ///    `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` via the Actions builder.
        /// 3. If `workingDirectory` is set, pass it as `lpCurrentDirectory`
        ///    to `CreateProcessW` (no Actions step is needed; Win32 takes a
        ///    direct parameter).
        /// 4. Spawn the child with the actions.
        /// 5. Close the parent's copy of the child-side ends (so the
        ///    child sees EOF when it exits) and retain the parent-side
        ///    ends for draining.
        /// 6. Drain stdout, then stderr, into `[UInt8]` buffers.
        /// 7. Wait for the child and bundle into ``Process/Output``.
        ///
        /// Mirrors the POSIX branch's per-configuration linear flow so the
        /// `~Copyable` pipe descriptors don't have to flow through an
        /// `Optional` (single-consume constraint).
        @usableFromInline
        internal static func _runWithCapture(
            _ configuration: Configuration
        ) throws(Process.Error) -> Process.Output {
            if configuration.stdin == .pipe {
                throw .streamPolicyUnsupported
            }

            switch (configuration.stdout, configuration.stderr) {
            case (.inherit, .inherit):
                return try _runWithoutPipes(configuration)

            case (.pipe, .inherit):
                return try _runWithStdoutPipe(configuration)

            case (.inherit, .pipe):
                return try _runWithStderrPipe(configuration)

            case (.pipe, .pipe):
                return try _runWithBothPipes(configuration)
            }
        }
    }

    // MARK: - Per-configuration branches

    extension Process.Spawn {
        /// No pipes — only `workingDirectory` is non-default. Build an
        /// Actions object holding no handles and spawn with the
        /// `lpCurrentDirectory` parameter set.
        @usableFromInline
        internal static func _runWithoutPipes(
            _ configuration: Configuration
        ) throws(Process.Error) -> Process.Output {
            let actions = try _makeActions()
            let result = try _spawnWithActions(configuration, actions: actions)
            let handle = Process.Handle(processInfo: consume result)
            let status = try handle.wait()
            return Process.Output(status: status)
        }

        @usableFromInline
        internal static func _runWithStdoutPipe(
            _ configuration: Configuration
        ) throws(Process.Error) -> Process.Output {
            var actions = try _makeActions()
            let stdoutPipe = try _makePipe()

            try _wireChildHandle(stdoutPipe.write, into: &actions, slot: .stdout)

            let result = try _spawnWithActions(configuration, actions: actions)
            let stdoutRead = try _closeWriteEnd(stdoutPipe)
            let captured = try _drainBytes(stdoutRead)
            let handle = Process.Handle(processInfo: consume result)
            let status = try handle.wait()
            return Process.Output(status: status, stdout: captured, stderr: nil)
        }

        @usableFromInline
        internal static func _runWithStderrPipe(
            _ configuration: Configuration
        ) throws(Process.Error) -> Process.Output {
            var actions = try _makeActions()
            let stderrPipe = try _makePipe()

            try _wireChildHandle(stderrPipe.write, into: &actions, slot: .stderr)

            let result = try _spawnWithActions(configuration, actions: actions)
            let stderrRead = try _closeWriteEnd(stderrPipe)
            let captured = try _drainBytes(stderrRead)
            let handle = Process.Handle(processInfo: consume result)
            let status = try handle.wait()
            return Process.Output(status: status, stdout: nil, stderr: captured)
        }

        @usableFromInline
        internal static func _runWithBothPipes(
            _ configuration: Configuration
        ) throws(Process.Error) -> Process.Output {
            var actions = try _makeActions()
            let stdoutPipe = try _makePipe()
            let stderrPipe = try _makePipe()

            try _wireChildHandle(stdoutPipe.write, into: &actions, slot: .stdout)
            try _wireChildHandle(stderrPipe.write, into: &actions, slot: .stderr)

            let result = try _spawnWithActions(configuration, actions: actions)
            let stdoutRead = try _closeWriteEnd(stdoutPipe)
            let stderrRead = try _closeWriteEnd(stderrPipe)

            // Drain stdout then stderr. See `run(_:)`'s doc-comment for the
            // pipe-buffer limitation — note that Windows anonymous pipes default
            // to ~4 KiB per CreatePipe nSize=0, which is much smaller than POSIX's
            // typical 64 KiB. The drain-deadlock risk is therefore higher on
            // Windows; concurrent drain on the Windows path is reserved for a
            // future revision (v3 landed concurrent drain on POSIX only).
            let capturedStdout = try _drainBytes(stdoutRead)
            let capturedStderr = try _drainBytes(stderrRead)

            let handle = Process.Handle(processInfo: consume result)
            let status = try handle.wait()
            return Process.Output(
                status: status,
                stdout: capturedStdout,
                stderr: capturedStderr
            )
        }
    }

    // MARK: - Slot

    extension Process.Spawn {
        /// Internal slot identifier used by the per-platform wiring helpers.
        @usableFromInline
        internal enum _StdioSlot { case stdout, stderr }
    }

    // MARK: - Helpers

    extension Process.Spawn {
        @usableFromInline
        internal static func _makeActions() throws(Process.Error) -> Windows.`32`.Kernel.Process.Spawn.Actions {
            do throws(Windows.`32`.Kernel.Process.Error) {
                return try Windows.`32`.Kernel.Process.Spawn.Actions()
            } catch {
                switch error {
                case .create(let code), .wait(let code):
                    throw .spawn(_processErrorFromCode(code))

                case .platform(let err):
                    throw .spawn(_processErrorFromCode(err.code))
                }
            }
        }

        @usableFromInline
        internal static func _makePipe() throws(Process.Error) -> Windows.`32`.Kernel.Pipe.Descriptors {
            do throws(Windows.`32`.Kernel.Pipe.Error) {
                return try Windows.`32`.Kernel.Pipe.pipe()
            } catch {
                switch error {
                case .handle(let e):
                    throw .capture(.win32(UInt32(ERROR_INVALID_HANDLE)))

                case .platform(let e):
                    throw .capture(e.code)
                }
            }
        }

        @usableFromInline
        internal static func _wireChildHandle(
            _ descriptor: borrowing Windows.`32`.Kernel.Descriptor,
            into actions: inout Windows.`32`.Kernel.Process.Spawn.Actions,
            slot: _StdioSlot
        ) throws(Process.Error) {
            do throws(Windows.`32`.Kernel.Process.Error) {
                try actions.markHandleInheritable(descriptor)
                switch slot {
                case .stdout: actions.setStdout(descriptor)
                case .stderr: actions.setStderr(descriptor)
                }
            } catch {
                switch error {
                case .create(let code), .wait(let code):
                    throw .spawn(_processErrorFromCode(code))

                case .platform(let err):
                    throw .spawn(_processErrorFromCode(err.code))
                }
            }
        }

        @usableFromInline
        internal static func _spawnWithActions(
            _ configuration: Configuration,
            actions: borrowing Windows.`32`.Kernel.Process.Spawn.Actions
        ) throws(Process.Error) -> Windows.`32`.Kernel.Process.Spawn.Result {
            // Build a writable UTF-16 command line (CreateProcessW reserves the
            // right to mutate it in place). Format: "<exe>" arg1 arg2 ...
            // Every token — including the executable — is quoted per the
            // documented Win32 convention so that whitespace, embedded
            // quotes, and backslash runs in an argument cannot be
            // misparsed into extra argv entries or an argument-injection
            // surface on the child side (see `_quoteWindowsCommandLineArgument`).
            var commandLineString = _quoteWindowsCommandLineArgument(configuration.executable)
            for arg in configuration.arguments {
                commandLineString += " " + _quoteWindowsCommandLineArgument(arg)
            }
            var commandLineUnits: [WCHAR] = Array(commandLineString.utf16)
            commandLineUnits.append(0)  // NUL terminator

            // Build the UTF-16 environment block: each KEY=VALUE entry is
            // NUL-terminated and the block ends with an additional NUL.
            // Returns nil when the configuration inherits the parent's env.
            let envBlock: [WCHAR]? = _flattenWideEnvironment(configuration.environment)

            // Build the UTF-16 working directory NUL-terminated.
            let cwdUnits: [WCHAR]? = configuration.workingDirectory.map { dir in
                var units = Array(dir.utf16)
                units.append(0)
                return units
            }

            // Build the UTF-16 executable path NUL-terminated. Win32 distinguishes
            // lpApplicationName (the actual exe path) from lpCommandLine (which
            // includes argv[0]); we pass the executable explicitly.
            var executableUnits = Array(configuration.executable.utf16)
            executableUnits.append(0)

            do throws(Windows.`32`.Kernel.Process.Error) {
                // All four buffers (executable, command line, working
                // directory, environment) are accessed from inside one
                // nested `withUnsafe(Mutable)BufferPointer` scope stack, so
                // every pointer handed to `spawn` is provably live for the
                // duration of the call. `cwdUnits`/`envBlock` previously had
                // their pointers extracted via a top-level `?.withUnsafe...
                // { $0.baseAddress }`, which let the guaranteed-valid window
                // end before the pointer was ever used — nesting via
                // `_withOptionalWideBuffer` below closes that gap the same
                // way `executableUnits`/`commandLineUnits` already were.
                return try unsafe executableUnits.withUnsafeBufferPointer {
                    (exePtr: UnsafeBufferPointer<WCHAR>) throws(Windows.`32`.Kernel.Process.Error) -> Windows.`32`.Kernel.Process.Spawn.Result in
                    try unsafe commandLineUnits.withUnsafeMutableBufferPointer {
                        (cmdPtr: inout UnsafeMutableBufferPointer<WCHAR>) throws(Windows.`32`.Kernel.Process.Error) -> Windows.`32`.Kernel.Process.Spawn.Result in
                        try _withOptionalWideBuffer(cwdUnits) {
                            (cwdPtr: UnsafePointer<WCHAR>?) throws(Windows.`32`.Kernel.Process.Error) -> Windows.`32`.Kernel.Process.Spawn.Result in
                            try _withOptionalWideBuffer(envBlock) {
                                (envPtr: UnsafePointer<WCHAR>?) throws(Windows.`32`.Kernel.Process.Error) -> Windows.`32`.Kernel.Process.Spawn.Result in
                                try unsafe Windows.`32`.Kernel.Process.Spawn.spawn(
                                    executable: exePtr.baseAddress,
                                    commandLine: cmdPtr.baseAddress!,
                                    environment: envPtr.map { unsafe UnsafeMutableRawPointer(mutating: $0) },
                                    workingDirectory: cwdPtr,
                                    actions: actions
                                )
                            }
                        }
                    }
                }
            } catch {
                switch error {
                case .create(let code), .wait(let code):
                    throw .spawn(_processErrorFromCode(code))

                case .platform(let err):
                    throw .spawn(_processErrorFromCode(err.code))
                }
            }
        }

        /// Runs `body` with a pointer to `array`'s contents kept alive and
        /// valid for the entire call, or `nil` when `array` is `nil`.
        ///
        /// `array?.withUnsafeBufferPointer { $0.baseAddress }` (the prior
        /// shape of this call site) lets the pointer's guaranteed-valid
        /// window end the instant that inner call returns — the returned
        /// pointer is only "live" by accident of the allocator not having
        /// reused the backing storage yet before the caller dereferences
        /// it. Nesting `body` *inside* `withUnsafeBufferPointer` instead
        /// keeps `array` provably alive for every use of the pointer.
        @usableFromInline
        internal static func _withOptionalWideBuffer<R: ~Copyable>(
            _ array: [WCHAR]?,
            _ body: (UnsafePointer<WCHAR>?) throws(Windows.`32`.Kernel.Process.Error) -> R
        ) throws(Windows.`32`.Kernel.Process.Error) -> R {
            guard let array else {
                return try body(nil)
            }
            return try unsafe array.withUnsafeBufferPointer {
                (buffer: UnsafeBufferPointer<WCHAR>) throws(Windows.`32`.Kernel.Process.Error) -> R in
                try body(unsafe buffer.baseAddress)
            }
        }

        /// Closes the write end of `pipe` (parent's copy after the child
        /// has been spawned with the write end inherited) and returns the
        /// read end. Errors flow back as ``Process/Error/capture(_:)``.
        @usableFromInline
        internal static func _closeWriteEnd(
            _ pipe: consuming Windows.`32`.Kernel.Pipe.Descriptors
        ) throws(Process.Error) -> Windows.`32`.Kernel.Descriptor {
            // The Tagged-Pair Descriptors does not have a typed Close.write
            // helper on the Windows side yet (v2 ships the read accessor and
            // deinit-close). Extract the read end manually.
            let pair = consume pipe
            let read = pair.read
            // The write end is closed when pair goes out of scope (deinit
            // calls CloseHandle).
            _ = pair.write
            return read
        }

        @usableFromInline
        internal static func _drainBytes(
            _ descriptor: consuming Windows.`32`.Kernel.Descriptor
        ) throws(Process.Error) -> [UInt8] {
            var buffer: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 4096)

            let handle = unsafe UnsafeMutableRawPointer(bitPattern: descriptor._raw)
            guard let handle else {
                throw .capture(.win32(UInt32(ERROR_INVALID_HANDLE)))
            }

            while true {
                var bytesRead: DWORD = 0
                let success = unsafe chunk.withUnsafeMutableBufferPointer { ptr in
                    ReadFile(
                        handle,
                        ptr.baseAddress,
                        DWORD(ptr.count),
                        &bytesRead,
                        nil
                    )
                }
                if !success {
                    let err = unsafe GetLastError()
                    if err == ERROR_BROKEN_PIPE {
                        break
                    }
                    throw .capture(.win32(err))
                }
                if bytesRead == 0 { break }
                buffer.append(contentsOf: chunk.prefix(Int(bytesRead)))
            }
            // Descriptor's deinit closes the handle.
            _ = consume descriptor
            return buffer
        }

        /// Flattens the configuration's environment dictionary into a UTF-16
        /// NUL-separated, double-NUL-terminated block suitable for
        /// `CreateProcessW`'s `lpEnvironment` parameter (with
        /// `CREATE_UNICODE_ENVIRONMENT`).
        @usableFromInline
        internal static func _flattenWideEnvironment(
            _ environment: [Swift.String: Swift.String]?
        ) -> [WCHAR]? {
            guard let environment else { return nil }
            var block: [WCHAR] = []
            for key in environment.keys.sorted() {
                let value = environment[key] ?? ""
                let entry = "\(key)=\(value)"
                block.append(contentsOf: entry.utf16)
                block.append(0)
            }
            block.append(0)  // double-NUL terminator
            return block
        }

        /// Maps a raw Win32 error code into ``Windows/32/Kernel/Process/Error``.
        @usableFromInline
        internal static func _processErrorFromCode(
            _ code: Error_Primitives.Error.Code
        ) -> Windows.`32`.Kernel.Process.Error {
            .create(code)
        }
    }

#endif  // os(Windows)

// MARK: - Command-line quoting (platform-independent)
//
// This algorithm has no dependency on WinSDK — it is a pure `String`
// transform — so it is compiled and unit-testable on every platform,
// unlike the rest of this file. Keeping it un-gated lets the regression
// test for F-002 run as a real `swift test` on any host, not only on a
// Windows CI runner that (per the accompanying remediation report) does
// not yet exist for this package.
extension Process.Spawn {
    /// Quotes a single command-line token per the documented Win32
    /// convention (mirrors `CommandLineToArgvW`'s parsing rules), so the
    /// child process reconstructs the exact `argv` the caller supplied.
    ///
    /// Without this, ``_spawnWithActions(_:actions:)`` previously joined
    /// `executable`/`arguments` with naive spaces: an argument
    /// containing a space split into two argv entries in the child, and
    /// an argument containing `"` (or a crafted backslash-quote
    /// sequence) could inject additional, attacker-controlled argv
    /// entries — including flags the caller never passed.
    ///
    /// Algorithm (Microsoft's documented backslash/quote escaping):
    /// - An argument with no whitespace, tab, or `"` and that is
    ///   non-empty needs no quoting and is passed through unchanged.
    /// - Otherwise the argument is wrapped in `"`. Within it, a run of
    ///   `N` backslashes immediately followed by a `"` becomes `2N + 1`
    ///   backslashes then `\"` (escaping both the run and the quote); a
    ///   run of `N` backslashes at the end of the argument (immediately
    ///   before the closing `"` this function appends) becomes `2N`
    ///   backslashes (only the run is escaped, since the following `"`
    ///   is the delimiter, not part of the argument).
    @usableFromInline
    internal static func _quoteWindowsCommandLineArgument(_ argument: Swift.String) -> Swift.String {
        let needsQuoting =
            argument.isEmpty
            || argument.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\u{0B}" || $0 == "\"" })
        guard needsQuoting else {
            return argument
        }

        var quoted: Swift.String = "\""
        var backslashRun = 0
        for character in argument {
            if character == "\\" {
                backslashRun += 1
                continue
            }
            if character == "\"" {
                // Escape every backslash in the run, then escape the quote.
                quoted += Swift.String(repeating: "\\", count: backslashRun * 2 + 1)
                quoted += "\""
                backslashRun = 0
                continue
            }
            if backslashRun > 0 {
                // An unescaped run followed by a non-quote character
                // stays literal — only runs abutting a `"` are doubled.
                quoted += Swift.String(repeating: "\\", count: backslashRun)
                backslashRun = 0
            }
            quoted.append(character)
        }
        // A trailing run sits immediately before the closing quote we
        // are about to append, so it must be doubled.
        quoted += Swift.String(repeating: "\\", count: backslashRun * 2)
        quoted += "\""
        return quoted
    }
}
