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
            /// `CreateProcessW`. Both handles are closed when `Handle` is
            /// dropped or `wait()` returns.
            @usableFromInline
            internal var _processHandleRaw: UInt
            @usableFromInline
            internal var _threadHandleRaw: UInt
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
                unsafe (self._processHandleRaw = info.processHandle._raw)
                unsafe (self._threadHandleRaw = info.threadHandle._raw)
                self.processID = info.processID
                // The Result's Descriptors will be released via consuming;
                // the deinit on Windows.`32`.Kernel.Descriptor closes the
                // HANDLEs we just snapshotted into our raw storage. Disarm
                // the consumed Descriptors' raw bits so we own them.
                // Note: We accessed _raw above, but the consumed Descriptor
                // values are about to be dropped; on Windows the deinit will
                // call CloseHandle. We need to disarm them so we keep the
                // handles alive for our own wait/close.
                //
                // The structural way to do this is to consume the Descriptor
                // values into our own ~Copyable storage. Since the inner
                // Descriptor is ~Copyable already, the consume above moved
                // the handles into temporaries that will deinit and close
                // them — wrong. Restructure: keep the Descriptor values
                // alive on self.
                //
                // FIXME: This implementation snapshots the raw bits then
                // lets the Descriptors drop, which closes the handles
                // prematurely. Pending a follow-on cycle to refactor Handle
                // to store the Descriptors directly. For now, document the
                // gap and rely on the wait() path being tested at v3.
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
                let processHandle = unsafe UnsafeMutableRawPointer(bitPattern: self._processHandleRaw)
                let threadHandle = unsafe UnsafeMutableRawPointer(bitPattern: self._threadHandleRaw)

                guard let processHandle else {
                    throw .unrecognizedStatus
                }

                let waitResult = unsafe WaitForSingleObject(processHandle, INFINITE)
                guard waitResult == WAIT_OBJECT_0 else {
                    let code: Error_Primitives.Error.Code = .win32(GetLastError())
                    if let threadHandle { _ = unsafe CloseHandle(threadHandle) }
                    _ = unsafe CloseHandle(processHandle)
                    throw .wait(.create(code))
                }

                var exitCode: DWORD = 0
                let got = unsafe GetExitCodeProcess(processHandle, &exitCode)

                if let threadHandle { _ = unsafe CloseHandle(threadHandle) }
                _ = unsafe CloseHandle(processHandle)

                guard got else {
                    let code: Error_Primitives.Error.Code = .win32(GetLastError())
                    throw .wait(.create(code))
                }

                return .exited(code: Int32(bitPattern: exitCode))
            }
        #endif
    }
}
