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
internal import Strings

extension Process {
    /// Subprocess spawn operations.
    ///
    /// Two entry points:
    ///
    /// - ``spawn(_:)`` — spawns and returns a ``Process/Handle``;
    ///   caller invokes ``Process/Handle/wait()`` themselves.
    /// - ``run(_:)`` — spawns and waits in one call, returning
    ///   the child's ``Process/Status``.
    ///
    /// Both go through ``POSIX/Kernel/Process/Spawn`` (which is a
    /// thin pass-through over ``ISO_9945/Kernel/Process/Spawn``'s
    /// `posix_spawn(3)` typed wrapper). `posix_spawn` does not
    /// duplicate the parent's address space and is safe to call
    /// from multithreaded Swift processes (including those running
    /// Swift Testing).
    public enum Spawn: Sendable {}
}

extension Process.Spawn {
    /// Spawns a child process per the supplied configuration.
    ///
    /// Returns a ``Process/Handle`` that the caller must consume
    /// via ``Process/Handle/wait()`` to collect the exit status.
    ///
    /// - Parameter configuration: spawn parameters.
    /// - Returns: a handle to the spawned child.
    /// - Throws: ``Process/Error`` on configuration validation
    ///   failure (interior NUL bytes), unsupported stream policy,
    ///   or `posix_spawn(3)` failure.
    public static func spawn(
        _ configuration: Configuration
    ) throws(Process.Error) -> Process.Handle {
        try _check(stream: configuration.stdin)
        try _check(stream: configuration.stdout)
        try _check(stream: configuration.stderr)

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
    }

    /// Spawns a child and blocks until it terminates, returning
    /// the resulting status.
    ///
    /// - Parameter configuration: spawn parameters.
    /// - Returns: the child's final ``Process/Status``.
    /// - Throws: ``Process/Error`` on spawn or wait failure.
    public static func run(
        _ configuration: Configuration
    ) throws(Process.Error) -> Process.Status {
        let handle = try spawn(configuration)
        return try handle.wait()
    }
}

// MARK: - Internal helpers

extension Process.Spawn {
    @usableFromInline
    internal static func _check(stream: Process.Stream) throws(Process.Error) {
        switch stream {
        case .inherit: return
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
