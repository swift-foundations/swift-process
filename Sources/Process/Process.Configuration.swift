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
    /// Spawn parameters: executable, arguments, environment,
    /// per-stream disposition, and working directory.
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
    /// Mixing inheritance with overrides is out of scope; callers
    /// compose `nil` (inherit) or supply a complete snapshot.
    ///
    /// ## Working directory
    ///
    /// `workingDirectory` defaults to `nil`, which inherits the
    /// parent's current working directory. A non-`nil` value
    /// invokes `posix_spawn_file_actions_addchdir(3)` so the child
    /// is positioned in that directory before `execve(2)`.
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

        /// Working directory the child changes to before `execve(2)`.
        ///
        /// `nil` (default) inherits the parent's cwd. A non-`nil`
        /// value is applied via `posix_spawn_file_actions_addchdir(3)`.
        public let workingDirectory: Swift.String?

        public init(
            executable: Swift.String,
            arguments: [Swift.String] = [],
            environment: [Swift.String: Swift.String]? = nil,
            stdin: Process.Stream = .inherit,
            stdout: Process.Stream = .inherit,
            stderr: Process.Stream = .inherit,
            workingDirectory: Swift.String? = nil
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.stdin = stdin
            self.stdout = stdout
            self.stderr = stderr
            self.workingDirectory = workingDirectory
        }
    }
}
