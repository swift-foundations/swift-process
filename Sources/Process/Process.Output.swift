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

extension Process {
    /// Result of ``Process/Spawn/run(_:)``: the child's exit status
    /// plus any captured `stdout` / `stderr` bytes.
    ///
    /// `stdout` and `stderr` are populated when the corresponding
    /// stream in ``Process/Spawn/Configuration`` was set to
    /// ``Process/Stream/pipe``; otherwise they are `nil`.
    ///
    /// ## Encoding
    ///
    /// The captured bytes are returned uninterpreted as `[UInt8]`.
    /// Callers that expect text apply the appropriate decoding —
    /// typically `Swift.String(decoding: bytes, as: UTF8.self)` for
    /// modern toolchain output.
    public struct Output: Sendable, Equatable {
        /// The child's terminal status.
        public let status: Process.Status

        /// Captured `stdout` bytes, or `nil` if the configuration's
        /// `stdout` was not ``Process/Stream/pipe``.
        public let stdout: [UInt8]?

        /// Captured `stderr` bytes, or `nil` if the configuration's
        /// `stderr` was not ``Process/Stream/pipe``.
        public let stderr: [UInt8]?

        public init(
            status: Process.Status,
            stdout: [UInt8]? = nil,
            stderr: [UInt8]? = nil
        ) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
        }
    }
}
