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

#if !os(Windows)

internal import Path_Primitives
internal import POSIX_Kernel
internal import POSIX_Kernel_File
@_spi(Syscall) internal import ISO_9945_Kernel_Poll

#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#elseif canImport(Musl)
internal import Musl
#endif

extension Process.Spawn {
    /// Slow path: configurations with ``Process/Stream/pipe`` streams,
    /// a non-`nil`
    /// ``Process/Spawn/Configuration/workingDirectory``, or a non-`nil`
    /// ``Process/Spawn/Configuration/timeout``.
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
    /// 6. If a timeout is configured, arm a watchdog (self-pipe
    ///    coordinated thread) that sends `SIGKILL` to the child when
    ///    the deadline elapses.
    /// 7. Drain configured pipes — concurrently via `poll(2)` for the
    ///    both-pipes case (v3) so neither pipe's kernel buffer
    ///    (typically 64 KiB) can wedge the other; sequentially for
    ///    single-pipe configurations (single-pipe ordering cannot
    ///    deadlock).
    /// 8. `wait` for the child, disarm the watchdog, and bundle into
    ///    ``Process/Output``.
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
    /// No pipes — only `workingDirectory` and / or `timeout` is
    /// non-default. Build an Actions object holding only the chdir
    /// action and spawn.
    @usableFromInline
    internal static func _runWithoutPipes(
        _ configuration: Configuration
    ) throws(Process.Error) -> Process.Output {
        var actions = try _makeActions()
        try _addChdir(&actions, cwd: configuration.workingDirectory)

        let pid = try _spawnWithActions(configuration, actions: actions)
        let watchdog = try _armWatchdog(pid: pid, timeout: configuration.timeout)
        let handle = Process.Handle(processID: pid)
        let status: Process.Status
        do throws(Process.Error) {
            status = try handle.wait()
        } catch {
            _disarmWatchdog(watchdog)
            throw error
        }
        _disarmWatchdog(watchdog)
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
        let watchdog = try _armWatchdog(pid: pid, timeout: configuration.timeout)

        let captured: [UInt8]
        do throws(Process.Error) {
            captured = try _drainBytes(stdoutRead)
        } catch {
            _disarmWatchdog(watchdog)
            throw error
        }

        let handle = Process.Handle(processID: pid)
        let status: Process.Status
        do throws(Process.Error) {
            status = try handle.wait()
        } catch {
            _disarmWatchdog(watchdog)
            throw error
        }
        _disarmWatchdog(watchdog)
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
        let watchdog = try _armWatchdog(pid: pid, timeout: configuration.timeout)

        let captured: [UInt8]
        do throws(Process.Error) {
            captured = try _drainBytes(stderrRead)
        } catch {
            _disarmWatchdog(watchdog)
            throw error
        }

        let handle = Process.Handle(processID: pid)
        let status: Process.Status
        do throws(Process.Error) {
            status = try handle.wait()
        } catch {
            _disarmWatchdog(watchdog)
            throw error
        }
        _disarmWatchdog(watchdog)
        return Process.Output(status: status, stdout: nil, stderr: captured)
    }

    /// Both stdout and stderr captured concurrently via `poll(2)`.
    ///
    /// Concurrent drain (v3) replaces v2's sequential drain, which
    /// would deadlock when the child wrote more than the kernel's
    /// pipe buffer (typically 64 KiB) to stderr while the parent was
    /// still draining stdout. With concurrent drain, neither pipe can
    /// wedge the other.
    ///
    /// Order-of-operations preservation: both reads complete (EOF)
    /// before `handle.wait()`, so the child's terminal state is
    /// observable only after all bytes are captured. Only the inner
    /// drain ordering changes (parallel instead of sequential).
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
        let watchdog = try _armWatchdog(pid: pid, timeout: configuration.timeout)

        let drained: (stdout: [UInt8], stderr: [UInt8])
        do throws(Process.Error) {
            drained = try _drainConcurrently(
                stdout: stdoutRead,
                stderr: stderrRead
            )
        } catch {
            _disarmWatchdog(watchdog)
            throw error
        }

        let handle = Process.Handle(processID: pid)
        let status: Process.Status
        do throws(Process.Error) {
            status = try handle.wait()
        } catch {
            _disarmWatchdog(watchdog)
            throw error
        }
        _disarmWatchdog(watchdog)
        return Process.Output(
            status: status,
            stdout: drained.stdout,
            stderr: drained.stderr
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

// MARK: - Concurrent drain (v3)

extension Process.Spawn {
    /// Drains both pipes concurrently via `poll(2)`.
    ///
    /// `poll(2)` reports readiness on either pipe as it occurs; we
    /// `read(2)` whichever pipe is ready and append into its buffer.
    /// Either pipe reaching EOF (`read` returns `0`) marks that pipe
    /// done; remaining traffic on the other pipe continues to be
    /// drained until it too reaches EOF.
    ///
    /// This replaces v2's sequential drain, which deadlocked when the
    /// child wrote more than the kernel's pipe buffer (typically
    /// 64 KiB) to stderr while the parent was still draining stdout —
    /// the child blocked on the stderr write, which prevented stdout
    /// from advancing.
    ///
    /// Consumes both descriptors; their `deinit`s close the parent
    /// copies once this function returns or throws.
    @usableFromInline
    internal static func _drainConcurrently(
        stdout stdoutDescriptor: consuming ISO_9945.Kernel.Descriptor,
        stderr stderrDescriptor: consuming ISO_9945.Kernel.Descriptor
    ) throws(Process.Error) -> (stdout: [UInt8], stderr: [UInt8]) {
        var stdoutBuffer: [UInt8] = []
        var stderrBuffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)

        var stdoutDone = false
        var stderrDone = false

        // Index 0 = stdout, index 1 = stderr (when both are still open).
        // After one closes, the closed slot's pollfd is masked out by
        // setting its descriptor field to `-1` (the canonical "ignore"
        // value the kernel honors regardless of `events`).
        while !(stdoutDone && stderrDone) {
            var entries: [ISO_9945.Kernel.Poll.Entry] = []
            entries.reserveCapacity(2)
            entries.append(
                ISO_9945.Kernel.Poll.Entry(
                    stdoutDescriptor,
                    requested: [.input]
                )
            )
            entries.append(
                ISO_9945.Kernel.Poll.Entry(
                    stderrDescriptor,
                    requested: [.input]
                )
            )

            if stdoutDone { unsafe (entries[0].descriptor = -1) }
            if stderrDone { unsafe (entries[1].descriptor = -1) }

            do throws(Error_Primitives.Error) {
                _ = try POSIX.Kernel.Poll.poll(&entries, timeout: -1)
            } catch {
                throw .capture(error.code)
            }

            if !stdoutDone, !entries[0].returned.isEmpty {
                let n: Int
                do throws(ISO_9945.Kernel.IO.Read.Error) {
                    n = try unsafe chunk.withUnsafeMutableBufferPointer {
                        (raw: inout UnsafeMutableBufferPointer<UInt8>) throws(ISO_9945.Kernel.IO.Read.Error) -> Int in
                        let bytes = UnsafeMutableRawBufferPointer(raw)
                        return try unsafe POSIX.Kernel.IO.Read.read(stdoutDescriptor, into: bytes)
                    }
                } catch {
                    throw .capture(error.code)
                }
                if n == 0 {
                    stdoutDone = true
                } else {
                    stdoutBuffer.append(contentsOf: chunk.prefix(n))
                }
            }

            if !stderrDone, !entries[1].returned.isEmpty {
                let n: Int
                do throws(ISO_9945.Kernel.IO.Read.Error) {
                    n = try unsafe chunk.withUnsafeMutableBufferPointer {
                        (raw: inout UnsafeMutableBufferPointer<UInt8>) throws(ISO_9945.Kernel.IO.Read.Error) -> Int in
                        let bytes = UnsafeMutableRawBufferPointer(raw)
                        return try unsafe POSIX.Kernel.IO.Read.read(stderrDescriptor, into: bytes)
                    }
                } catch {
                    throw .capture(error.code)
                }
                if n == 0 {
                    stderrDone = true
                } else {
                    stderrBuffer.append(contentsOf: chunk.prefix(n))
                }
            }
        }

        return (stdout: stdoutBuffer, stderr: stderrBuffer)
    }
}

// MARK: - Watchdog (v3 timeout)

extension Process.Spawn {
    /// In-flight watchdog state. Holding a non-empty value means a
    /// watchdog thread is running; `_disarmWatchdog` is a no-op for
    /// the empty (no-timeout) state.
    ///
    /// The two pipe ends are stored as raw `Int32` fds rather than
    /// typed `Descriptor`s because the watchdog thread needs to
    /// `read(2)` from one fd while the main thread writes to the
    /// other and ultimately joins. `~Copyable` `Descriptor` cannot
    /// cross an `@escaping @Sendable` closure boundary, and the
    /// language has no public "release-without-close" API for
    /// suppressing a typed wrapper's deinit. Raw fds wrapped at
    /// open / close boundaries inside this file avoid both pitfalls
    /// while keeping platform reach narrow (a single `import Darwin /
    /// Glibc / Musl` at the top of this file).
    @usableFromInline
    internal struct Watchdog: ~Copyable {
        @usableFromInline
        internal var thread: ISO_9945.Kernel.Thread.Handle?

        /// Parent-side write end of the self-pipe. `-1` means "armed
        /// but already disarmed" or "never armed".
        @usableFromInline
        internal var shutdownWriteFd: Int32

        /// Parent-side read end of the self-pipe. The watchdog thread
        /// also reads from this fd via the same int (shared, not
        /// duplicated). Closed only after `thread.join()` so there is
        /// no race with the watchdog's read.
        @usableFromInline
        internal var shutdownReadFd: Int32

        @usableFromInline
        internal init() {
            self.thread = nil
            self.shutdownWriteFd = -1
            self.shutdownReadFd = -1
        }
    }

    /// Arms a deadline-driven watchdog when `timeout` is non-`nil`.
    ///
    /// The watchdog is a separate OS thread that polls a self-pipe
    /// with the timeout as its deadline. Two outcomes:
    ///
    ///   - Deadline elapses first → watchdog `kill(pid, SIGKILL)`s the
    ///     child. The child's pipes close (parent sees EOF on drain)
    ///     and `wait` returns ``Process/Status/signaled(signal:)`` with
    ///     `SIGKILL`.
    ///   - `_disarmWatchdog` writes a byte to the self-pipe first →
    ///     watchdog wakes, observes the shutdown signal via `POLLIN`,
    ///     and exits without killing.
    ///
    /// Returns an empty `Watchdog` (no thread, fds == -1) when
    /// `timeout == nil`, in which case `_disarmWatchdog` is a no-op.
    @usableFromInline
    internal static func _armWatchdog(
        pid: ISO_9945.Kernel.Process.ID,
        timeout: Duration?
    ) throws(Process.Error) -> Watchdog {
        guard let timeout else {
            return Watchdog()
        }

        // Self-pipe via raw `pipe(2)` — the typed L2 wrapper is not a
        // fit because we need to share the read fd with a separate
        // thread without engaging the `~Copyable` `Descriptor` type
        // (which has no public "release-without-close" API).
        var fds: (Int32, Int32) = (-1, -1)
        let pipeResult: Int32 = unsafe withUnsafeMutablePointer(to: &fds) { tuple -> Int32 in
            unsafe tuple.withMemoryRebound(to: Int32.self, capacity: 2) { fdPtr -> Int32 in
                unsafe pipe(fdPtr)
            }
        }
        guard pipeResult == 0 else {
            throw .capture(.posix(unsafe errno))
        }

        let readFd = fds.0
        let writeFd = fds.1
        let timeoutMs = _durationToPollMilliseconds(timeout)
        let pidValue: Int32 = pid.rawValue

        let thread: ISO_9945.Kernel.Thread.Handle
        do throws(ISO_9945.Kernel.Thread.Error) {
            thread = try POSIX.Kernel.Thread.create {
                _watchdogBody(
                    shutdownReadFd: readFd,
                    pid: pidValue,
                    timeoutMilliseconds: timeoutMs
                )
            }
        } catch {
            // Thread creation failed: close both ends.
            unsafe _closeRawFd(readFd)
            unsafe _closeRawFd(writeFd)
            throw .capture(_threadErrorCode(error))
        }

        var watchdog = Watchdog()
        watchdog.thread = consume thread
        watchdog.shutdownWriteFd = writeFd
        watchdog.shutdownReadFd = readFd
        return watchdog
    }

    /// Disarms the watchdog (if armed): writes one byte to the
    /// self-pipe to wake it, then `pthread_join`s. After this returns
    /// the watchdog thread has exited and its captured PID is no
    /// longer touched.
    @usableFromInline
    internal static func _disarmWatchdog(_ watchdog: consuming Watchdog) {
        // Snapshot the fds before consuming; the optional `thread`
        // partial-reinitialization restriction means we can only
        // touch `watchdog.thread` once.
        let writeFd = watchdog.shutdownWriteFd
        let readFd = watchdog.shutdownReadFd
        let threadOpt: ISO_9945.Kernel.Thread.Handle? = consume watchdog.thread

        guard let thread = consume threadOpt else {
            return
        }

        if writeFd >= 0 {
            // Write one byte to wake the watchdog. Failure is
            // non-fatal — closing the write end below also raises
            // POLLHUP on the read end, which the watchdog observes.
            unsafe _writeWakeByte(writeFd)
            // Close the write end so the watchdog sees POLLHUP if
            // the byte was lost (defensive).
            unsafe _closeRawFd(writeFd)
        }

        // Block until the watchdog has exited. The watchdog never
        // touches `pid` — and never reads from `shutdownReadFd` —
        // after this point.
        thread.join()

        // Now safe to close the read end.
        if readFd >= 0 {
            unsafe _closeRawFd(readFd)
        }
    }

    /// Body of the watchdog thread.
    ///
    /// Polls `shutdownReadFd` (shared with main; neither side closes
    /// it before `pthread_join`) with `timeoutMilliseconds` as the
    /// deadline. Sends `SIGKILL` to `pid` if the deadline elapses
    /// before any wakeup.
    ///
    /// Plain free function (not method) so it composes with
    /// `@Sendable` closure capture without dragging `self` references.
    @usableFromInline
    internal static func _watchdogBody(
        shutdownReadFd: Int32,
        pid: Int32,
        timeoutMilliseconds: Int32
    ) {
        // Raw `poll(2)` with a single pollfd. We don't go through the
        // L2 typed wrapper here because that wrapper takes
        // `[Poll.Entry]`, and Poll.Entry's only public init takes a
        // `borrowing Descriptor` — same `~Copyable` snag as the pipe
        // construction. Direct platform call is the cleanest path.
        var pollfdEntry = pollfd(fd: shutdownReadFd, events: Int16(POLLIN), revents: 0)
        let result: Int32 = unsafe withUnsafeMutablePointer(to: &pollfdEntry) { ptr -> Int32 in
            // Retry on EINTR — same policy POSIX.Kernel.Poll.poll uses.
            while true {
                let r = unsafe poll(ptr, 1, timeoutMilliseconds)
                if r >= 0 { return r }
                if unsafe errno != EINTR { return r }
            }
        }

        if result == 0 {
            // Deadline fired — kill the child. ESRCH (race with
            // natural termination) and other errors are benign; the
            // main thread will reap whatever status `wait(2)` returns.
            do throws(ISO_9945.Kernel.Process.Error) {
                try POSIX.Kernel.Process.Kill.kill(
                    ISO_9945.Kernel.Process.ID(rawValue: pid),
                    .kill
                )
            } catch {
                // No-op.
            }
        }
        // Otherwise: shutdown signal arrived first (or poll error),
        // exit without kill.
    }

    /// Best-effort single-byte write to wake the watchdog. Failure is
    /// non-fatal — the subsequent close of the write fd also wakes
    /// the watchdog via POLLHUP.
    @usableFromInline
    internal static func _writeWakeByte(_ fd: Int32) {
        var byte: UInt8 = 0
        unsafe withUnsafePointer(to: &byte) { ptr in
            _ = unsafe write(fd, ptr, 1)
        }
    }

    /// Closes a raw fd, ignoring failure. Used only for self-pipe
    /// teardown where the fd is owned by this file's bookkeeping.
    @usableFromInline
    internal static func _closeRawFd(_ fd: Int32) {
        _ = unsafe close(fd)
    }

    /// Extracts the `Error_Primitives.Error.Code` from a
    /// ``ISO_9945/Kernel/Thread/Error``. All three cases carry a code;
    /// this helper centralises the destructure for call sites that
    /// route through ``Process/Error/capture(_:)``.
    @usableFromInline
    internal static func _threadErrorCode(
        _ error: ISO_9945.Kernel.Thread.Error
    ) -> Error_Primitives.Error.Code {
        switch error {
        case .create(let code): return code
        case .join(let code): return code
        case .detach(let code): return code
        }
    }

    /// Converts a `Duration` to the millisecond timeout that `poll(2)`
    /// expects.
    ///
    /// Negative-or-zero durations clamp to `0` (poll-now). Durations
    /// exceeding `Int32.max` ms (≈ 24.8 days) clamp to `Int32.max`.
    /// Sub-millisecond durations round UP so a non-zero `Duration` is
    /// never reported as `0` (which would mean "non-blocking poll" and
    /// fire the kill immediately).
    @usableFromInline
    internal static func _durationToPollMilliseconds(_ duration: Duration) -> Int32 {
        let components = duration.components
        let attosecondsPerMs: Int64 = 1_000_000_000_000_000
        let secondsPart = components.seconds
        let attosPart = components.attoseconds
        // Round attoseconds up to the next millisecond so any non-zero
        // sub-ms duration is treated as "wait at least 1 ms".
        let msFromAttos = (attosPart + attosecondsPerMs - 1) / attosecondsPerMs
        let secondsMs = secondsPart.multipliedReportingOverflow(by: 1000)
        if secondsMs.overflow { return Int32.max }
        let total = secondsMs.partialValue.addingReportingOverflow(msFromAttos)
        if total.overflow { return Int32.max }
        if total.partialValue <= 0 { return 0 }
        if total.partialValue > Int64(Int32.max) { return Int32.max }
        return Int32(total.partialValue)
    }
}

#endif // !os(Windows)
