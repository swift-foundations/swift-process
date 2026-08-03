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
            /// The spawn result bundling the process/thread `Descriptor`s
            /// and IDs (Windows).
            ///
            /// `Windows.\`32\`.Kernel.Process.Spawn.Result` is `~Copyable`,
            /// non-`@frozen`, and defined in a different module — Swift
            /// disallows partially consuming (moving out) an individual
            /// stored property of a non-frozen `~Copyable` aggregate from
            /// outside its defining module, since doing so would require
            /// synthesizing a "destroy the remaining fields" operation
            /// that needs known layout. `Handle` therefore keeps the
            /// whole `Result` intact instead of splitting it into
            /// separate `_processHandle` / `_threadHandle` fields; both
            /// handles close together — via `Result`'s own field
            /// deinitializers — whenever `_spawnResult` is finally
            /// dropped, either at ``wait()``'s scope exit or at
            /// `Handle`'s own deinit if never waited.
            @usableFromInline
            internal var _spawnResult: Windows.`32`.Kernel.Process.Spawn.Result
            /// The numeric process ID (Windows).
            public let processID: UInt32
        #endif

        #if !os(Windows)
            @usableFromInline
            internal init(processID: ISO_9945.Kernel.Process.ID) {
                self.processID = processID
            }
        #else
            /// Adopts ownership of the spawn result. The handles inside
            /// it are closed when the Handle is dropped or wait()
            /// completes.
            @usableFromInline
            internal init(processInfo: consuming Windows.`32`.Kernel.Process.Spawn.Result) {
                // Read the (Copyable) processID before consuming the
                // whole value below — a borrow-read of a Copyable field
                // is unrestricted; only moving an individual ~Copyable
                // field out of `processInfo` is what cross-module
                // non-frozen resilience forbids (see `_spawnResult`'s
                // doc comment).
                self.processID = processInfo.processID
                self._spawnResult = consume processInfo
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
                // Read the process handle's raw representation via a
                // borrow — `_rawValue` is a Copyable `UInt`, so this is a
                // plain read, not a move of the `~Copyable` `Descriptor`
                // (see `_spawnResult`'s doc comment for why the
                // `Descriptor`s cannot be moved out individually). The
                // thread handle can no longer be dropped up front the
                // way a same-module `~Copyable` field could be; it stays
                // open until `self` (and its `_spawnResult`) deinitializes
                // at this function's scope exit, closing both handles
                // together. Windows does not require the thread handle
                // to close before waiting on the process handle, so this
                // is a timing difference only, not a correctness one.
                let processHandle = unsafe UnsafeMutableRawPointer(
                    bitPattern: self._spawnResult.processHandle._rawValue
                )

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

                // `self` — and its `_spawnResult` — deinitializes here at
                // scope exit on every return path, including the throws
                // above (Swift runs local deinitializers during
                // structured error unwinding), closing both the process
                // and thread `Descriptor`s together.
                return .exited(code: Int32(bitPattern: exitCode))
            }
        #endif
    }
}
