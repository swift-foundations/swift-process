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

internal import POSIX_Kernel

extension Process {
    /// Errors raised during subprocess spawning, waiting, or
    /// stream configuration.
    ///
    /// Each case carries domain-specific context so callers can
    /// distinguish failure modes without parsing strings.
    public enum Error: Swift.Error, Sendable, Equatable, Hashable {
        /// The configured executable path contained an interior
        /// NUL byte, an argument did, or the environment did.
        ///
        /// `index` identifies which input failed conversion;
        /// `0` is the executable itself, `1...n` are arguments,
        /// and `n+1...` are environment entries.
        case invalidPath(index: Int)

        /// `posix_spawn(3)` failed with the wrapped POSIX error.
        case spawn(ISO_9945.Kernel.Process.Error)

        /// `waitpid(2)` failed with the wrapped POSIX error.
        case wait(ISO_9945.Kernel.Process.Error)

        /// The wait operation completed but the child's status did
        /// not match a known classification (exited / signaled /
        /// stopped). Indicates a kernel/libc state the wrapper
        /// does not yet understand.
        case unrecognizedStatus

        /// A non-``Stream/inherit`` stream policy was supplied.
        ///
        /// v1 implements ``Stream/inherit`` only. Reserved cases
        /// trap here to make the unimplemented surface explicit
        /// rather than silently inheriting the wrong stream.
        case streamPolicyUnsupported

        /// The platform does not support subprocess spawning.
        ///
        /// Currently raised on platforms outside the POSIX family
        /// (e.g., Windows pre-CreateProcessW landing).
        case platformUnsupported
    }
}
