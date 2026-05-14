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

internal import Path_Primitives
internal import POSIX_Kernel
internal import POSIX_Kernel_File

extension Process.Spawn {
    /// Slow path: configurations with ``Process/Stream/pipe`` streams
    /// or a non-`nil`
    /// ``Process/Spawn/Configuration/workingDirectory``.
    ///
    /// Steps:
    /// 1. Build a ``ISO_9945/Kernel/Process/Spawn/Actions`` builder.
    /// 2. For each `.pipe` stream, create an anonymous pipe and add
    ///    a `dup2` action mapping the appropriate end into the
    ///    child's slot.
    /// 3. If `workingDirectory` is set, add an `addchdir` action.
    /// 4. Spawn the child with the actions.
    /// 5. Close the parent's copy of the child-side ends (so the
    ///    child sees EOF when it exits) and retain the parent-side
    ///    ends for draining.
    /// 6. Drain stdout, then stderr, into `[UInt8]` buffers.
    /// 7. `wait` for the child and bundle into ``Process/Output``.
    ///
    /// Implementation note: each `.pipe` slot has its own linear
    /// branch to keep the `~Copyable` pipe descriptors out of an
    /// `Optional`. `Optional<~Copyable>` cannot be borrowed across
    /// the dup2-setup and post-spawn-close phases — a single
    /// consume per Optional is the language constraint, and pipes
    /// must outlive both phases.
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
    /// Actions object holding only the chdir action and spawn.
    @usableFromInline
    internal static func _runWithoutPipes(
        _ configuration: Configuration
    ) throws(Process.Error) -> Process.Output {
        var actions = try _makeActions()
        try _addChdir(&actions, cwd: configuration.workingDirectory)

        let pid = try _spawnWithActions(configuration, actions: actions)
        let handle = Process.Handle(processID: pid)
        let status = try handle.wait()
        return Process.Output(status: status)
    }

    @usableFromInline
    internal static func _runWithStdoutPipe(
        _ configuration: Configuration
    ) throws(Process.Error) -> Process.Output {
        var actions = try _makeActions()
        let stdoutPipe = try _makePipe()

        do throws(ISO_9945.Kernel.Process.Error) {
            try actions.add(dup2: stdoutPipe.write, to: .stdout)
            try actions.add(close: .init(stdoutPipe.read))
        } catch {
            throw .spawn(error)
        }

        try _addChdir(&actions, cwd: configuration.workingDirectory)

        let pid = try _spawnWithActions(configuration, actions: actions)
        let stdoutRead = try _closeWriteEnd(stdoutPipe)
        let captured = try _drainBytes(stdoutRead)
        let handle = Process.Handle(processID: pid)
        let status = try handle.wait()
        return Process.Output(status: status, stdout: captured, stderr: nil)
    }

    @usableFromInline
    internal static func _runWithStderrPipe(
        _ configuration: Configuration
    ) throws(Process.Error) -> Process.Output {
        var actions = try _makeActions()
        let stderrPipe = try _makePipe()

        do throws(ISO_9945.Kernel.Process.Error) {
            try actions.add(dup2: stderrPipe.write, to: .stderr)
            try actions.add(close: .init(stderrPipe.read))
        } catch {
            throw .spawn(error)
        }

        try _addChdir(&actions, cwd: configuration.workingDirectory)

        let pid = try _spawnWithActions(configuration, actions: actions)
        let stderrRead = try _closeWriteEnd(stderrPipe)
        let captured = try _drainBytes(stderrRead)
        let handle = Process.Handle(processID: pid)
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

        do throws(ISO_9945.Kernel.Process.Error) {
            try actions.add(dup2: stdoutPipe.write, to: .stdout)
            try actions.add(close: .init(stdoutPipe.read))
            try actions.add(dup2: stderrPipe.write, to: .stderr)
            try actions.add(close: .init(stderrPipe.read))
        } catch {
            throw .spawn(error)
        }

        try _addChdir(&actions, cwd: configuration.workingDirectory)

        let pid = try _spawnWithActions(configuration, actions: actions)
        let stdoutRead = try _closeWriteEnd(stdoutPipe)
        let stderrRead = try _closeWriteEnd(stderrPipe)

        // Drain stdout then stderr. See `run(_:)`'s doc-comment for
        // the pipe-buffer limitation.
        let capturedStdout = try _drainBytes(stdoutRead)
        let capturedStderr = try _drainBytes(stderrRead)

        let handle = Process.Handle(processID: pid)
        let status = try handle.wait()
        return Process.Output(
            status: status,
            stdout: capturedStdout,
            stderr: capturedStderr
        )
    }
}

// MARK: - Helpers

extension Process.Spawn {
    @usableFromInline
    internal static func _makeActions() throws(Process.Error) -> ISO_9945.Kernel.Process.Spawn.Actions {
        do throws(ISO_9945.Kernel.Process.Error) {
            return try ISO_9945.Kernel.Process.Spawn.Actions()
        } catch {
            throw .spawn(error)
        }
    }

    @usableFromInline
    internal static func _makePipe() throws(Process.Error) -> ISO_9945.Kernel.Pipe.Descriptors {
        do throws(ISO_9945.Kernel.Pipe.Error) {
            return try POSIX.Kernel.Pipe.pipe()
        } catch {
            throw .capture(error.code)
        }
    }

    @usableFromInline
    internal static func _addChdir(
        _ actions: inout ISO_9945.Kernel.Process.Spawn.Actions,
        cwd: Swift.String?
    ) throws(Process.Error) {
        guard let cwd else { return }
        do throws(Path.String.Error<ISO_9945.Kernel.Process.Error>) {
            try Path.scope(cwd) {
                (borrowed: borrowing Path.Borrowed) throws(ISO_9945.Kernel.Process.Error) in
                try unsafe actions.add(chdir: borrowed.pointer)
            }
        } catch {
            switch error {
            case .conversion(.interiorNUL(let index)):
                throw .invalidPath(index: index)
            case .body(let posixError):
                throw .spawn(posixError)
            }
        }
    }

    @usableFromInline
    internal static func _spawnWithActions(
        _ configuration: Configuration,
        actions: borrowing ISO_9945.Kernel.Process.Spawn.Actions
    ) throws(Process.Error) -> ISO_9945.Kernel.Process.ID {
        let argv = [configuration.executable] + configuration.arguments
        let envp = _flattenEnvironment(configuration.environment)
        do throws(Path.String.Error<ISO_9945.Kernel.Process.Error>) {
            return try unsafe Path.scope.array(argv, envp) {
                (
                    argvPtr: UnsafePointer<UnsafePointer<Path.Char>?>,
                    envpPtr: UnsafePointer<UnsafePointer<Path.Char>?>
                ) throws(ISO_9945.Kernel.Process.Error) -> ISO_9945.Kernel.Process.ID in
                try unsafe ISO_9945.Kernel.Process.Spawn.spawn(
                    path: argvPtr[0]!,
                    argv: argvPtr,
                    envp: envpPtr,
                    actions: actions
                )
            }
        } catch {
            switch error {
            case .conversion(.interiorNUL(let index)):
                throw .invalidPath(index: index)
            case .body(let posixError):
                throw .spawn(posixError)
            }
        }
    }

    /// Extracts the underlying POSIX code from a
    /// ``ISO_9945/Kernel/Close/Error``. The type's two cases both
    /// carry a code; this helper centralises the destructure for
    /// call sites that route through ``Process/Error/capture(_:)``.
    @usableFromInline
    internal static func _closeErrorCode(
        _ error: ISO_9945.Kernel.Close.Error
    ) -> Error_Primitives.Error.Code {
        switch error {
        case .handle(let e): return e.code
        case .platform(let e): return e.code
        }
    }

    /// Closes the write end of `pipe` (parent's copy after the child
    /// has dup'd its own) and returns the read end. Errors flow back
    /// as ``Process/Error/capture(_:)``.
    @usableFromInline
    internal static func _closeWriteEnd(
        _ pipe: consuming ISO_9945.Kernel.Pipe.Descriptors
    ) throws(Process.Error) -> ISO_9945.Kernel.Descriptor {
        do throws(ISO_9945.Kernel.Close.Error) {
            return try ISO_9945.Kernel.Pipe.Close.write(pipe)
        } catch {
            throw .capture(_closeErrorCode(error))
        }
    }

    /// Drains `descriptor` to EOF; errors flow back as
    /// ``Process/Error/capture(_:)``.
    @usableFromInline
    internal static func _drainBytes(
        _ descriptor: consuming ISO_9945.Kernel.Descriptor
    ) throws(Process.Error) -> [UInt8] {
        do throws(ISO_9945.Kernel.IO.Read.Error) {
            return try _drain(descriptor)
        } catch {
            throw .capture(error.code)
        }
    }

    /// Reads `descriptor` to EOF, returning all bytes read. Consumes
    /// the descriptor (its `deinit` will close the fd when the read
    /// returns or throws).
    @usableFromInline
    internal static func _drain(
        _ descriptor: consuming ISO_9945.Kernel.Descriptor
    ) throws(ISO_9945.Kernel.IO.Read.Error) -> [UInt8] {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = try unsafe chunk.withUnsafeMutableBufferPointer {
                (raw: inout UnsafeMutableBufferPointer<UInt8>) throws(ISO_9945.Kernel.IO.Read.Error) -> Int in
                let bytes = UnsafeMutableRawBufferPointer(raw)
                return try unsafe POSIX.Kernel.IO.Read.read(descriptor, into: bytes)
            }
            if n == 0 { break }
            buffer.append(contentsOf: chunk.prefix(n))
        }
        return buffer
    }
}
