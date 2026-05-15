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
    /// On POSIX, `executable`, `arguments`, and `environment` entries
    /// cross the platform-string boundary via
    /// ``Path/scope/array(_:_:_:)``. Strings with interior NUL bytes
    /// are rejected at spawn time with
    /// ``Process/Error/invalidPath(index:)``.
    ///
    /// On Windows, all entries are encoded as UTF-16 wide strings and
    /// passed to `CreateProcessW` with the `CREATE_UNICODE_ENVIRONMENT`
    /// flag, matching Win32 file-path encoding conventions throughout
    /// the platform.
    ///
    /// ## Environment semantics
    ///
    /// - `nil` (default): inherit the parent process's full
    ///   environment.
    /// - non-`nil`: replace the parent's environment with the
    ///   given dictionary.
    ///
    /// On Windows, the dictionary is flattened into a UTF-16
    /// `KEY=VALUE\0KEY=VALUE\0\0` block (per `CreateProcessW`
    /// `lpEnvironment` format with `CREATE_UNICODE_ENVIRONMENT`).
    /// On POSIX, the dictionary is flattened into a NUL-terminated
    /// `KEY=VALUE` `char *` array.
    ///
    /// Mixing inheritance with overrides is out of scope; callers
    /// compose `nil` (inherit) or supply a complete snapshot.
    ///
    /// ## Working directory
    ///
    /// `workingDirectory` defaults to `nil`, which inherits the
    /// parent's current working directory. A non-`nil` value is
    /// applied per-platform:
    ///
    /// - POSIX: `posix_spawn_file_actions_addchdir(3)` adds a chdir
    ///   action so the child is positioned in that directory before
    ///   `execve(2)`.
    /// - Windows: the path is passed directly to `CreateProcessW`
    ///   via the `lpCurrentDirectory` parameter — no Actions step is
    ///   needed; the kernel applies it before the child's first
    ///   instruction.
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
        ///
        /// On Windows the dictionary is encoded as UTF-16 and passed
        /// to `CreateProcessW` with `CREATE_UNICODE_ENVIRONMENT`. On
        /// POSIX it is flattened into a NUL-terminated `KEY=VALUE`
        /// `char *` array.
        public let environment: [Swift.String: Swift.String]?

        /// Disposition of the child's standard input.
        public let stdin: Process.Stream

        /// Disposition of the child's standard output.
        public let stdout: Process.Stream

        /// Disposition of the child's standard error.
        public let stderr: Process.Stream

        /// Working directory the child changes to before its first
        /// instruction.
        ///
        /// `nil` (default) inherits the parent's cwd. A non-`nil`
        /// value is applied per-platform:
        ///
        /// - POSIX: `posix_spawn_file_actions_addchdir(3)` before
        ///   `execve(2)`.
        /// - Windows: `CreateProcessW.lpCurrentDirectory`.
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
