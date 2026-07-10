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
#endif

extension Process {
    /// The exit status of a finished child process.
    ///
    /// `Status` is the high-level cross-platform shape that callers
    /// switch over after waiting for a child. It collapses POSIX's
    /// raw status integer (with its `WIFEXITED`/`WEXITSTATUS` macro
    /// layer) into three semantic cases and is intended to grow a
    /// fourth Windows-specific case once Win32 process spawning
    /// lands.
    ///
    /// On POSIX, the value is derived from
    /// ``ISO_9945/Kernel/Process/Status`` (which wraps a raw
    /// `Int32` with typed accessors).
    public enum Status: Sendable, Equatable, Hashable {
        /// Child exited normally with the given exit code.
        ///
        /// Maps to `WIFEXITED` + `WEXITSTATUS`.
        case exited(code: Int32)

        /// Child was terminated by a signal.
        ///
        /// Maps to `WIFSIGNALED` + `WTERMSIG`.
        case signaled(signal: Int32)

        /// Child was stopped by a signal (job control).
        ///
        /// Maps to `WIFSTOPPED` + `WSTOPSIG`. Rare for the
        /// blocking-wait path; included for completeness.
        case stopped(signal: Int32)
    }
}

// MARK: - POSIX Status Bridging

#if !os(Windows)
    extension Process.Status {
        /// Lifts an ``ISO_9945/Kernel/Process/Status`` into the
        /// cross-platform ``Process/Status``.
        ///
        /// Returns `nil` if the underlying raw value does not match any
        /// of the three known classifications. The `posix_spawn(3)`
        /// + `waitpid(2)` flow used by ``Process/Spawn/run(_:)`` is not
        /// expected to produce such values for the blocking-wait path,
        /// but the `nil` return is reserved for safety.
        @usableFromInline
        internal init?(_ status: ISO_9945.Kernel.Process.Status) {
            if status.exited, let code = status.exit.code {
                self = .exited(code: code)
            } else if status.signaled, let signal = status.terminating.signal {
                self = .signaled(signal: signal.rawValue)
            } else if status.stopped, let signal = status.stop.signal {
                self = .stopped(signal: signal.rawValue)
            } else {
                return nil
            }
        }
    }
#endif
