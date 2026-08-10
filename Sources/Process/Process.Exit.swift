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
    /// below are conditional.
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

        /// Terminates the current process normally: runs `atexit`
        /// handlers and flushes stdio buffers before terminating.
        ///
        /// This is the correct call for an ordinary program ending itself.
        ///
        /// Composes ``Windows/Kernel/Process/Exit/normal(_:)``, the L2
        /// typed wrapper over CRT `exit()`. Per the Microsoft UCRT
        /// documentation, `exit` calls, in LIFO order, the functions
        /// registered by `atexit` and `_onexit`, then flushes all stream
        /// buffers before terminating — the verified parallel to POSIX
        /// `exit(3)`.
        ///
        /// - Parameter status: The exit status. 0 typically indicates
        ///   success; non-zero indicates failure. Standard conventions:
        ///   - `0`: success
        ///   - `1`: general error
        ///   - `64` (`EX_USAGE`): usage error
        /// - Returns: Never returns; the process is terminated.
        @inlinable
        public static func normal(_ status: Int32) -> Never {
            Windows.Kernel.Process.Exit.normal(status)
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
