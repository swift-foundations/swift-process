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
    public import POSIX_Kernel
#endif

#if os(Windows)
    internal import Windows_Kernel_Process
    internal import WinSDK
#endif

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
    /// `ECHILD` on POSIX or `ERROR_INVALID_HANDLE` on Windows).
    /// Marking the type `~Copyable` makes the single-wait invariant
    /// compiler-enforced.
    public struct Handle: ~Copyable, Sendable {
        #if !os(Windows)
            /// The PID of the spawned child (POSIX).
            public let processID: ISO_9945.Kernel.Process.ID
        #else
            /// The HANDLE of the spawned child process (Windows).
            ///
            /// Owns the process handle and (consumed) thread handle from
            /// `CreateProcessW` directly as `~Copyable` ``Descriptor``
            /// values. Both handles are closed on drop (`Descriptor.deinit`
            /// calls `CloseHandle`) — either when `Handle` itself is
            /// dropped without `wait()`, or when `wait()` consumes and
            /// releases them.
            @usableFromInline
            internal var _processHandle: Windows.`32`.Kernel.Descriptor
            @usableFromInline
            internal var _threadHandle: Windows.`32`.Kernel.Descriptor
            /// The numeric process ID (Windows).
            public let processID: UInt32
        #endif

        #if !os(Windows)
            @usableFromInline
            internal init(processID: ISO_9945.Kernel.Process.ID) {
                self.processID = processID
            }
        #else
            /// Adopts ownership of the spawn result's handles. The handles
            /// are closed when the Handle is dropped or wait() completes.
            @usableFromInline
            internal init(processInfo: consuming Windows.`32`.Kernel.Process.Spawn.Result) {
                let info = consume processInfo
                // Move the ~Copyable Descriptors themselves onto self —
                // never touch their raw bits here. Each Descriptor's own
                // deinit (CloseHandle) fires exactly once, whenever that
                // Descriptor value is finally dropped (self's deinit if
                // never waited, or wait()'s consuming scope-exit).
                self._processHandle = info.processHandle
                self._threadHandle = info.threadHandle
                self.processID = info.processID
            }
        #endif

        #if !os(Windows)
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
        #else
            /// Block until the child changes state to a terminal classification
            /// (exited or signaled).
            ///
            /// Consumes the handle so a second wait cannot follow.
            ///
            /// - Returns: The child's final ``Process/Status``.
            /// - Throws: ``Process/Error/wait(_:)`` if `WaitForSingleObject`
            ///   or `GetExitCodeProcess` fails;
            ///   ``Process/Error/unrecognizedStatus`` if the exit code does
            ///   not match a known classification.
            public consuming func wait() throws(Process.Error) -> Process.Status {
                // The thread handle is not needed for waiting; consume and
                // drop it immediately. Its deinit (CloseHandle) runs right
                // here — no manual CloseHandle call needed, and no risk of
                // double-closing a HANDLE some other Descriptor already owns.
                _ = consume self._threadHandle
                let processHandleDescriptor = consume self._processHandle

                let processHandle = unsafe UnsafeMutableRawPointer(bitPattern: processHandleDescriptor._rawValue)

                guard let processHandle else {
                    throw .unrecognizedStatus
                }

                let waitResult = unsafe WaitForSingleObject(processHandle, INFINITE)
                guard waitResult == WAIT_OBJECT_0 else {
                    let code: Error_Primitives.Error.Code = .win32(GetLastError())
                    throw .wait(.create(code))
                }

                var exitCode: DWORD = 0
                let got = unsafe GetExitCodeProcess(processHandle, &exitCode)

                guard got else {
                    let code: Error_Primitives.Error.Code = .win32(GetLastError())
                    throw .wait(.create(code))
                }

                // `processHandleDescriptor` closes via its own
                // `Descriptor.deinit` when this scope exits — on every
                // return path, including the throws above, since Swift
                // runs local deinitializers during structured error
                // unwinding.
                return .exited(code: Int32(bitPattern: exitCode))
            }
        #endif
    }
}
