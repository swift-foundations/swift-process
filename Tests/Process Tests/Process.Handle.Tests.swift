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

#if os(Windows)

    // F-001 regression coverage. Pre-fix, `Process.Handle.init(processInfo:)`
    // snapshotted the raw HANDLE bit patterns and then let the spawn
    // result's `~Copyable` `Descriptor` values drop immediately — which
    // calls `CloseHandle` on both the process and thread HANDLE right
    // there, before `wait()` is ever invoked. `wait()` then called
    // `WaitForSingleObject` / `GetExitCodeProcess` / a second `CloseHandle`
    // on a HANDLE value that was already closed (and potentially already
    // reassigned by the kernel to something else entirely). This is not a
    // rare race: it happens on every single Windows spawn, so any spawn
    // that reaches `wait()` should already have surfaced it deterministically.

    import Testing
    @testable import Process

    extension Process.Handle {
        @Suite
        struct Unit {
            @Test("wait() on a freshly spawned child returns its own exit code, not a stale/closed-HANDLE failure")
            func waitReturnsRealExitCodeAfterSpawn() throws {
                let output = try Process.Spawn.run(
                    Process.Spawn.Configuration(
                        executable: "C:\\Windows\\System32\\cmd.exe",
                        arguments: ["/C", "exit 7"]
                    )
                )
                #expect(output.status == .exited(code: 7))
            }

            @Test("Several sequential spawn+wait cycles each observe their own exit code (no HANDLE-reuse corruption)")
            func sequentialSpawnsEachReturnTheirOwnExitCode() throws {
                for code in 0..<8 {
                    let output = try Process.Spawn.run(
                        Process.Spawn.Configuration(
                            executable: "C:\\Windows\\System32\\cmd.exe",
                            arguments: ["/C", "exit \(code)"]
                        )
                    )
                    #expect(output.status == .exited(code: Int32(code)), "iteration \(code)")
                }
            }
        }
    }

#endif  // os(Windows)
