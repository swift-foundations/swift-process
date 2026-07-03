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

    extension Process {
        /// Terminates the current process with the given exit status.
        ///
        /// Bypasses atexit handlers and stdio buffer flushing (consistent
        /// with `_exit(2)` semantics on POSIX and `ExitProcess` on Windows).
        ///
        /// - Parameter status: The exit status. 0 typically indicates success;
        ///   non-zero indicates failure. Standard conventions:
        ///   - `0`: success
        ///   - `1`: general error
        ///   - `64` (`EX_USAGE`): usage error
        /// - Returns: Never returns; the process is terminated immediately.
        ///
        /// ## Architecture
        ///
        /// `Process.exit(_:)` is the L3-unifier consumer surface. It
        /// composes the L3-policy ``POSIX/Kernel/Process/Exit/now(_:)``
        /// directly, which in turn pass-throughs to the L2 typed wrapper
        /// over `_exit(2)` (POSIX) / `ExitProcess` (Win32).
        @inlinable
        public static func exit(_ status: Int32) -> Never {
            POSIX.Kernel.Process.Exit.now(status)
        }
    }

#elseif os(Windows)
    public import Windows_Kernel_Process

    extension Process {
        /// Terminates the current process with the given exit status.
        ///
        /// Bypasses atexit handlers and stdio buffer flushing (consistent
        /// with `_exit(2)` semantics on POSIX and `ExitProcess` on Windows).
        ///
        /// - Parameter status: The exit status. 0 typically indicates success;
        ///   non-zero indicates failure. Standard conventions:
        ///   - `0`: success
        ///   - `1`: general error
        ///   - `64` (`EX_USAGE`): usage error
        /// - Returns: Never returns; the process is terminated immediately.
        ///
        /// ## Architecture
        ///
        /// `Process.exit(_:)` is the L3-unifier consumer surface. It
        /// composes the L3-policy ``Windows/Kernel/Process/Exit/now(_:)``
        /// directly, which in turn pass-throughs to the L2 typed wrapper
        /// over `_exit(2)` (POSIX) / `ExitProcess` (Win32).
        @inlinable
        public static func exit(_ status: Int32) -> Never {
            // Win32 `ExitProcess` takes UINT; the signed argument maps via
            // bitPattern to preserve negative exit-code semantics across
            // POSIX / Windows.
            Windows.Kernel.Process.Exit.now(UInt32(bitPattern: status))
        }
    }

#endif
