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

public import POSIX_Kernel

extension Process {
    /// A reference to a spawned child process whose lifecycle has
    /// not yet been collected via wait.
    ///
    /// `Handle` is `~Copyable`: each spawned child has exactly one
    /// handle, and that handle is consumed by ``wait()``. Splitting
    /// the spawn / wait pair across functions is supported by
    /// passing the handle as `consuming`.
    ///
    /// ## Lifecycle Contract
    ///
    /// Callers MUST eventually consume the handle via ``wait()``
    /// (or, when only the high-level result is needed, via
    /// ``Process/Spawn/run(_:)`` which spawn-and-waits in one
    /// call). Dropping a handle without waiting leaves the child
    /// as a zombie until the parent process itself exits — the
    /// standard POSIX trade-off; the wrapper does not silently
    /// reap to avoid racing with explicit waits and to keep the
    /// `consuming` semantics clean.
    ///
    /// ## Why ~Copyable
    ///
    /// A copy of a process handle would invite double-wait bugs
    /// (one wait drains the kernel's status; the second sees
    /// `ECHILD`). Marking the type `~Copyable` makes the
    /// single-wait invariant compiler-enforced.
    public struct Handle: ~Copyable, Sendable {
        /// The PID of the spawned child.
        public let processID: ISO_9945.Kernel.Process.ID

        @usableFromInline
        internal init(processID: ISO_9945.Kernel.Process.ID) {
            self.processID = processID
        }

        /// Block until the child changes state to a terminal
        /// classification (exited, signaled, or stopped).
        ///
        /// Consumes the handle so a second wait cannot follow.
        ///
        /// - Returns: The child's final ``Process/Status``.
        /// - Throws: ``Process/Error/wait(_:)`` if `waitpid(2)`
        ///   itself fails; ``Process/Error/unrecognizedStatus``
        ///   if the kernel returns a status the wrapper does
        ///   not yet classify.
        public consuming func wait() throws(Process.Error) -> Process.Status {
            let pid = self.processID
            let result: ISO_9945.Kernel.Process.Wait.Result?
            do throws(ISO_9945.Kernel.Process.Error) {
                result = try POSIX.Kernel.Process.Wait.wait(.process(pid))
            } catch {
                throw .wait(error)
            }
            guard let status = result?.status,
                  let lifted = Process.Status(status)
            else {
                throw .unrecognizedStatus
            }
            return lifted
        }
    }
}
