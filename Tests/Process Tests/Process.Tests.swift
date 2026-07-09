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

    import Testing
    @testable import Process

    // MARK: - Process spawn smoke tests
    //
    // Merged into ``Process/Spawn/Test`` per [SWIFT-TEST-002]: the tested
    // type (`Process.Spawn`) already carries a `Test` suite (declared in
    // Process.Spawn.Capture.Tests.swift) and this suite's name has no
    // leftover distinguishing token once `ProcessSpawn` is stripped, so
    // these tests are merged in as additional members of that suite via
    // extension rather than a nested sub-suite.
    extension Process.Spawn.Test {
        @Test
        func `Spawning /usr/bin/true returns exit code 0`() throws {
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(executable: "/usr/bin/true")
            )
            #expect(output.status == .exited(code: 0))
            #expect(output.stdout == nil)
            #expect(output.stderr == nil)
        }

        @Test
        func `Spawning /usr/bin/false returns exit code 1`() throws {
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(executable: "/usr/bin/false")
            )
            #expect(output.status == .exited(code: 1))
        }

        @Test
        func `Spawning /usr/bin/env with explicit environment yields exit 0`() throws {
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: "/usr/bin/env",
                    arguments: ["true"],
                    environment: ["PATH": "/usr/bin:/bin"]
                )
            )
            #expect(output.status == .exited(code: 0))
        }

        @Test
        func `Interior NUL in executable path is rejected at index 0`() throws {
            do throws(Process.Error) {
                _ = try Process.Spawn.run(
                    Process.Spawn.Configuration(executable: "/usr/bin/\0true")
                )
                Issue.record("expected throw, got success")
            } catch {
                #expect(error == .invalidPath(index: 0))
            }
        }

        @Test
        func `Spawning a non-existent executable surfaces a typed spawn error`() throws {
            do throws(Process.Error) {
                _ = try Process.Spawn.run(
                    Process.Spawn.Configuration(executable: "/nonexistent/path/binary")
                )
                Issue.record("expected throw, got success")
            } catch {
                // We don't pin the exact POSIX errno (ENOENT vs EACCES vs platform
                // variation); we just assert this surfaces as a `.spawn` failure.
                switch error {
                case .spawn: break
                default: Issue.record("unexpected error: \(error)")
                }
            }
        }
    }

#endif  // !os(Windows)
