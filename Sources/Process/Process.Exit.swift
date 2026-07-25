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

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    public import POSIX_Kernel_Process
#elseif os(Windows)
    public import Windows_Kernel_Process
#endif

extension Process {
    /// Process termination operations.
    ///
    /// ISO 9945 defines two termination calls because they serve two
    /// different jobs, and this namespace mirrors both:
    ///
    /// | | ``normal(_:)`` — `exit(3)` | ``now(_:)`` — `_exit(2)` |
    /// |---|---|---|
    /// | `atexit` handlers | run | skipped |
    /// | stdio buffers | flushed | **discarded** |
    /// | safe after `fork()` | no | yes |
    ///
    /// A program terminating *itself* wants ``normal(_:)``. ``now(_:)``
    /// is the `fork()`-child primitive.
    ///
    /// The namespace is platform-independent; only the implementations
    /// below are conditional. On Windows ``normal(_:)`` is currently
    /// unavailable — see its note.
    public enum Exit: Sendable {}
}

// MARK: - POSIX

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)

    extension Process.Exit {
        /// Terminates the current process normally: runs `atexit`
        /// handlers and flushes stdio buffers before terminating.
        ///
        /// This is the correct call for an ordinary program ending itself.
        ///
        /// Composes ``POSIX/Kernel/Process/Exit/normal(_:)``, which
        /// pass-throughs to the L2 typed wrapper over `exit(3)`.
        ///
        /// - Parameter status: The exit status. 0 typically indicates
        ///   success; non-zero indicates failure. Standard conventions:
        ///   - `0`: success
        ///   - `1`: general error
        ///   - `64` (`EX_USAGE`): usage error
        /// - Returns: Never returns; the process is terminated.
        @inlinable
        public static func normal(_ status: Int32) -> Never {
            POSIX.Kernel.Process.Exit.normal(status)
        }

        /// Terminates the current process immediately, bypassing `atexit`
        /// handlers and **discarding** unflushed stdio buffers.
        ///
        /// This is the `fork()`-child primitive. Prefer ``normal(_:)``
        /// anywhere a process is terminating itself: discarding stdio is
        /// invisible on a terminal, where stdout is line-buffered and every
        /// `print` has already flushed, and silently drops *all* output the
        /// moment stdout is a pipe or a file and becomes block-buffered.
        ///
        /// Composes ``POSIX/Kernel/Process/Exit/now(_:)``, which
        /// pass-throughs to the L2 typed wrapper over `_exit(2)`.
        ///
        /// - Parameter status: The exit status.
        /// - Returns: Never returns; the process is terminated immediately.
        @inlinable
        public static func now(_ status: Int32) -> Never {
            POSIX.Kernel.Process.Exit.now(status)
        }
    }

// MARK: - Windows

#elseif os(Windows)

    extension Process.Exit {
        /// Terminates the current process immediately, bypassing CRT
        /// `atexit` handlers and **discarding** unflushed stdio buffers.
        ///
        /// Composes ``Windows/Kernel/Process/Exit/now(_:)``
        /// (`ExitProcess`).
        ///
        /// - Parameter status: The exit status.
        /// - Returns: Never returns; the process is terminated immediately.
        @inlinable
        public static func now(_ status: Int32) -> Never {
            // Win32 `ExitProcess` takes UINT; the signed argument maps via
            // bitPattern to preserve negative exit-code semantics across
            // POSIX / Windows.
            Windows.Kernel.Process.Exit.now(UInt32(bitPattern: status))
        }

        /// Normal termination — **not modeled on Windows yet.**
        ///
        /// The POSIX counterpart flushes stdio and runs `atexit` handlers.
        /// The Windows analogue is presumed to be the CRT `exit()` rather
        /// than `ExitProcess`, but that parallel is **unverified** and the
        /// call is not modeled at L2 (`swift-windows-32` declares only
        /// ``Windows/Kernel/Process/Exit/now(_:)``, whose own doc claim of
        /// equivalence to `_exit()` is likewise unverified).
        ///
        /// This is deliberately `unavailable` rather than aliased to
        /// ``now(_:)``: silently substituting the non-flushing call would
        /// reintroduce, on Windows only, exactly the discard-under-
        /// redirection defect this API exists to fix. A build error naming
        /// the missing work is the safer failure.
        @available(
            *,
            unavailable,
            message: """
                Normal (stdio-flushing) termination is not modeled on Windows. \
                Requires a Win32 L2 model of CRT exit() in swift-windows-32; \
                the ExitProcess/exit() parallel is unverified.
                """
        )
        public static func normal(_ status: Int32) -> Never {
            fatalError("unavailable")
        }
    }

#endif

// MARK: - Legacy spelling

extension Process {
    /// Terminates the current process with the given exit status,
    /// bypassing `atexit` handlers and **discarding** unflushed stdio
    /// buffers — `_exit(2)` semantics, despite the spelling.
    ///
    /// - Important: This is a spelling of ``Process/Exit/now(_:)``, NOT of
    ///   C's `exit(3)`. A program terminating itself almost always wants
    ///   ``Process/Exit/normal(_:)`` instead; using this call there
    ///   discards any buffered stdout, which is invisible on a terminal
    ///   and drops all output under redirection.
    ///
    /// - Parameter status: The exit status. 0 typically indicates success;
    ///   non-zero indicates failure. Standard conventions:
    ///   - `0`: success
    ///   - `1`: general error
    ///   - `64` (`EX_USAGE`): usage error
    /// - Returns: Never returns; the process is terminated immediately.
    @inlinable
    public static func exit(_ status: Int32) -> Never {
        Process.Exit.now(status)
    }
}
