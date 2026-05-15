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
#endif

internal import Strings

extension Process {
    /// Subprocess spawn operations.
    ///
    /// Two entry points:
    ///
    /// - ``spawn(_:)`` — spawns and returns a ``Process/Handle``;
    ///   caller invokes ``Process/Handle/wait()`` themselves. Pipes
    ///   and working-directory configuration are NOT supported on
    ///   this path; use ``run(_:)`` for those.
    /// - ``run(_:)`` — spawns, drains any ``Process/Stream/pipe``
    ///   captures, waits, and returns the bundled
    ///   ``Process/Output``. Supports the full configuration
    ///   surface (``Process/Stream/pipe`` streams,
    ///   ``Process/Spawn/Configuration/workingDirectory``).
    ///
    /// ## Platforms
    ///
    /// - **POSIX (macOS / iOS / tvOS / watchOS / visionOS / Linux):**
    ///   both entry points go through ``POSIX/Kernel/Process/Spawn``
    ///   (a thin pass-through over ``ISO_9945/Kernel/Process/Spawn``'s
    ///   `posix_spawn(3)` typed wrapper). `posix_spawn` does not
    ///   duplicate the parent's address space and is safe to call
    ///   from multithreaded Swift processes (including those running
    ///   Swift Testing).
    /// - **Windows:** both entry points go through
    ///   ``Windows/32/Kernel/Process/Spawn``, which wraps
    ///   `CreateProcessW` with `STARTUPINFOEX` and
    ///   `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` for precise child-handle
    ///   inheritance discipline.
    public enum Spawn: Sendable {}
}

extension Process.Spawn {
    /// Spawns a child process per the supplied configuration.
    ///
    /// Returns a ``Process/Handle`` that the caller must consume
    /// via ``Process/Handle/wait()`` to collect the exit status.
    ///
    /// This entry point supports only ``Process/Stream/inherit``
    /// streams and inherits the parent's current working directory.
    /// Configurations that request ``Process/Stream/pipe`` or set
    /// ``Process/Spawn/Configuration/workingDirectory`` MUST use
    /// ``run(_:)``.
    ///
    /// - Parameter configuration: spawn parameters.
    /// - Returns: a handle to the spawned child.
    /// - Throws: ``Process/Error`` on configuration validation
    ///   failure or platform spawn failure.
    public static func spawn(
        _ configuration: Configuration
    ) throws(Process.Error) -> Process.Handle {
        try _checkSpawnSupports(configuration)

        #if !os(Windows)
        let argv = [configuration.executable] + configuration.arguments
        let envp = _flattenEnvironment(configuration.environment)

        let pid: ISO_9945.Kernel.Process.ID
        do throws(Path.String.Error<ISO_9945.Kernel.Process.Error>) {
            pid = try unsafe Path.scope.array(argv, envp) {
                (
                    argvPtr: UnsafePointer<UnsafePointer<Path.Char>?>,
                    envpPtr: UnsafePointer<UnsafePointer<Path.Char>?>
                ) throws(ISO_9945.Kernel.Process.Error) -> ISO_9945.Kernel.Process.ID in
                try unsafe POSIX.Kernel.Process.Spawn.spawn(
                    path: unsafe argvPtr[0]!,
                    argv: argvPtr,
                    envp: envpPtr
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

        return Process.Handle(processID: pid)
        #else
        // Windows-side simple spawn: build an empty Actions list (no stdio
        // redirection, no working directory) and delegate to the Capture
        // file's _spawnWithActions helper.
        let actions: Windows.`32`.Kernel.Process.Spawn.Actions
        do throws(Windows.`32`.Kernel.Process.Error) {
            actions = try Windows.`32`.Kernel.Process.Spawn.Actions()
        } catch {
            switch error {
            case .create(let code), .wait(let code):
                throw .spawn(.create(code))
            case .platform(let err):
                throw .spawn(.create(err.code))
            }
        }
        let result = try _spawnWithActions(configuration, actions: actions)
        return Process.Handle(processInfo: consume result)
        #endif
    }

    /// Spawns a child, drains any captured pipes, waits for the
    /// child to terminate, and returns the bundled result.
    ///
    /// For ``Process/Stream/pipe`` streams, the child's slot is
    /// redirected to one end of an anonymous pipe pair; the parent
    /// drains the other end into the corresponding field of
    /// ``Process/Output`` (`stdout` and / or `stderr`). For
    /// ``Process/Stream/inherit`` streams, the corresponding field
    /// is `nil`.
    ///
    /// If
    /// ``Process/Spawn/Configuration/workingDirectory`` is non-`nil`,
    /// the child changes to that directory before `execve(2)`
    /// (POSIX) or via the `lpCurrentDirectory` parameter
    /// (Windows / `CreateProcessW`).
    ///
    /// - Parameter configuration: spawn parameters.
    /// - Returns: ``Process/Output`` with the child's status and any
    ///   captured stream bytes.
    /// - Throws: ``Process/Error`` on spawn / wait / capture failure.
    ///
    /// ## Concurrent drain (POSIX, v3)
    ///
    /// On POSIX, when both `stdout` and `stderr` are configured as
    /// pipes, `run` drains them concurrently via `poll(2)` so neither
    /// pipe can wedge the other. Children that emit more than the
    /// kernel's pipe buffer (typically 64 KiB on Darwin and Linux) to
    /// stderr while the parent is still reading stdout therefore
    /// complete without deadlock — the empirical trigger for promoting
    /// drain to concurrent in v3.
    ///
    /// Single-pipe configurations (only stdout or only stderr) retain
    /// the simpler sequential drain — single-pipe ordering cannot
    /// deadlock, so the simpler code path is preserved.
    ///
    /// On Windows, `run` still drains pipes sequentially (about 4 KiB
    /// per anonymous pipe via `CreatePipe(_, _, _, 0)`); concurrent
    /// drain on the Windows path is reserved for a future revision.
    /// For high-volume Windows captures, redirect stderr to a file or
    /// capture only one stream at a time.
    ///
    /// ## Timeout (POSIX, v3)
    ///
    /// On POSIX, if
    /// ``Process/Spawn/Configuration/timeout`` is non-`nil`, a
    /// background watchdog thread sends `SIGKILL` to the child when
    /// the deadline elapses. The child is reaped via the normal
    /// `wait(2)` path; the result reports
    /// ``Process/Status/signaled(signal:)`` with the platform's
    /// `SIGKILL` value (typically `9`). Captured stream bytes drained
    /// before the kill are preserved in
    /// ``Process/Output/stdout`` / ``Process/Output/stderr``. Callers
    /// wishing to distinguish "child timed out" from "child crashed"
    /// can match on the signal value.
    ///
    /// On Windows the `timeout` field is currently a no-op; deadline
    /// enforcement on the Windows path is reserved for a future
    /// revision.
    public static func run(
        _ configuration: Configuration
    ) throws(Process.Error) -> Process.Output {
        // Fast path: no pipes, no cwd, no timeout — reuse the simple
        // spawn + wait. Timeout pulls into the slow path because the
        // POSIX watchdog needs the slow-path's PID-keyed wait
        // bookkeeping.
        if configuration.stdin == .inherit
            && configuration.stdout == .inherit
            && configuration.stderr == .inherit
            && configuration.workingDirectory == nil
            && configuration.timeout == nil
        {
            let handle = try spawn(configuration)
            let status = try handle.wait()
            return Process.Output(status: status)
        }

        return try _runWithCapture(configuration)
    }
}

// MARK: - Internal helpers

extension Process.Spawn {
    /// Validates that `configuration` uses only the subset supported
    /// by the bare ``spawn(_:)`` entry point.
    @usableFromInline
    internal static func _checkSpawnSupports(
        _ configuration: Configuration
    ) throws(Process.Error) {
        switch configuration.stdin { case .inherit: break; case .pipe: throw .streamPolicyUnsupported }
        switch configuration.stdout { case .inherit: break; case .pipe: throw .streamPolicyUnsupported }
        switch configuration.stderr { case .inherit: break; case .pipe: throw .streamPolicyUnsupported }
        if configuration.workingDirectory != nil {
            throw .streamPolicyUnsupported
        }
    }

    /// Flattens an environment dictionary to `KEY=VALUE` strings,
    /// preserving deterministic order for stable spawn behavior.
    /// `nil` inherits the parent's environment.
    @usableFromInline
    internal static func _flattenEnvironment(
        _ environment: [Swift.String: Swift.String]?
    ) -> [Swift.String] {
        guard let environment else {
            return _inheritedEnvironment()
        }
        return environment.keys.sorted().map { key in
            "\(key)=\(environment[key] ?? "")"
        }
    }

    /// Captures the parent process's current environment as
    /// `KEY=VALUE` strings.
    ///
    /// Reads via ``Kernel/Environment/entries()`` so no platform-C
    /// imports leak into this package.
    @usableFromInline
    internal static func _inheritedEnvironment() -> [Swift.String] {
        var result: [Swift.String] = []
        #if os(Windows)
        guard var iterator = Kernel.Environment.entries() else {
            return result
        }
        #else
        var iterator = Kernel.Environment.entries()
        #endif
        while let entry = iterator.next() {
            guard let name = try? Swift.String(entry.name),
                  let value = try? Swift.String(entry.value)
            else { continue }
            result.append("\(name)=\(value)")
        }
        return result
    }
}
