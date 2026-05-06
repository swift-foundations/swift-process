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

extension Process.Spawn {
    /// Spawn parameters: executable, arguments, environment, and
    /// per-stream disposition.
    ///
    /// ## Argument & environment encoding
    ///
    /// `executable`, `arguments`, and `environment` entries cross
    /// the platform-string boundary via ``Path/scope/array(_:_:_:)``.
    /// Strings with interior NUL bytes are rejected at spawn time
    /// with ``Process/Error/invalidPath(index:)``.
    ///
    /// ## Environment semantics
    ///
    /// - `nil` (default): inherit the parent process's full
    ///   environment.
    /// - non-`nil`: replace the parent's environment with the
    ///   given dictionary.
    ///
    /// Mixing inheritance with overrides is out of scope for v1;
    /// callers compose `nil` (inherit) or supply a complete
    /// snapshot.
    ///
    /// ## Working directory
    ///
    /// v1 inherits the parent's current working directory.
    /// `posix_spawn`'s `posix_spawn_file_actions_addchdir_np` is
    /// available on modern Darwin / glibc but is not yet wrapped
    /// in ``swift-iso-9945``; the `workingDirectory` field is
    /// reserved for v2.
    public struct Configuration: Sendable {
        /// Path to the executable.
        public let executable: Swift.String

        /// Arguments to pass to the child (excluding `argv[0]`).
        ///
        /// `argv[0]` is set to ``executable`` automatically. Pass
        /// only the post-program arguments here.
        public let arguments: [Swift.String]

        /// Environment for the child process. `nil` inherits the
        /// parent's environment.
        public let environment: [Swift.String: Swift.String]?

        /// Disposition of the child's standard input.
        public let stdin: Process.Stream

        /// Disposition of the child's standard output.
        public let stdout: Process.Stream

        /// Disposition of the child's standard error.
        public let stderr: Process.Stream

        public init(
            executable: Swift.String,
            arguments: [Swift.String] = [],
            environment: [Swift.String: Swift.String]? = nil,
            stdin: Process.Stream = .inherit,
            stdout: Process.Stream = .inherit,
            stderr: Process.Stream = .inherit
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.stdin = stdin
            self.stdout = stdout
            self.stderr = stderr
        }
    }
}
