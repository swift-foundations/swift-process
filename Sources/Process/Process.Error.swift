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
    internal import POSIX_Kernel
#else
    internal import Windows_Kernel_Process
#endif

extension Process {
    /// Errors raised during subprocess spawning, waiting, or
    /// stream configuration.
    ///
    /// Each case carries domain-specific context so callers can
    /// distinguish failure modes without parsing strings.
    public enum Error: Swift.Error, Sendable, Equatable, Hashable {
        /// The kernel-level error payload wrapped by ``spawn(_:)`` and
        /// ``wait(_:)``.
        ///
        /// The spawn / wait primitives differ by platform, so this
        /// nested alias resolves to the matching typed kernel error:
        ///
        /// - **POSIX:** ``ISO_9945/Kernel/Process/Error`` (the
        ///   `posix_spawn(3)` / `waitpid(2)` wrapper).
        /// - **Windows:** ``Windows/32/Kernel/Process/Error`` (the
        ///   `CreateProcessW` / `WaitForSingleObject` wrapper).
        ///
        /// Both mirror each other's shape and are
        /// `Sendable` + `Equatable` + `Hashable`, so ``Error`` keeps a
        /// single, uniform conformance set on every platform.
        #if !os(Windows)
            public typealias Kernel = ISO_9945.Kernel.Process.Error
        #else
            public typealias Kernel = Windows.`32`.Kernel.Process.Error
        #endif

        /// The configured executable path contained an interior
        /// NUL byte, an argument did, or the environment did.
        ///
        /// `index` identifies which input failed conversion;
        /// `0` is the executable itself, `1...n` are arguments,
        /// and `n+1...` are environment entries.
        case invalidPath(index: Int)

        /// The platform spawn primitive failed with the wrapped kernel
        /// error: `posix_spawn(3)` on POSIX, `CreateProcessW` (with its
        /// `STARTUPINFOEX` / handle-list setup) on Windows.
        case spawn(Kernel)

        /// The platform wait primitive failed with the wrapped kernel
        /// error: `waitpid(2)` on POSIX, `WaitForSingleObject` /
        /// `GetExitCodeProcess` on Windows.
        case wait(Kernel)

        /// The wait operation completed but the child's status did
        /// not match a known classification (exited / signaled /
        /// stopped). Indicates a kernel/libc state the wrapper
        /// does not yet understand.
        case unrecognizedStatus

        /// Pipe / drain failure during a ``Process/Stream/pipe``
        /// capture: pipe creation, parent-side close after spawn,
        /// or read-to-EOF failed.
        case capture(Error_Primitives.Error.Code)

        /// A stream policy not yet supported on this entry point
        /// was supplied. Currently emitted by ``Spawn/spawn(_:)``
        /// when the configuration requests ``Stream/pipe`` or
        /// sets ``Spawn/Configuration/workingDirectory`` (which go
        /// through ``Spawn/run(_:)``), and by ``Spawn/run(_:)``
        /// when ``Stream/pipe`` is requested for ``stdin``
        /// (reserved for a future revision; v3 added concurrent
        /// stdout/stderr drain + timeout but not stdin pipe).
        case streamPolicyUnsupported

        /// The platform does not support subprocess spawning.
        ///
        /// Currently raised on platforms outside the POSIX family
        /// (e.g., Windows pre-CreateProcessW landing).
        case platformUnsupported
    }
}
