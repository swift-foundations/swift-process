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

import Testing
@testable import Process

@Suite("Process spawn smoke tests")
struct ProcessSpawnTests {
    @Test("Spawning /usr/bin/true returns exit code 0")
    func spawnTrue() throws {
        let status = try Process.Spawn.run(
            Process.Spawn.Configuration(executable: "/usr/bin/true")
        )
        #expect(status == .exited(code: 0))
    }

    @Test("Spawning /usr/bin/false returns exit code 1")
    func spawnFalse() throws {
        let status = try Process.Spawn.run(
            Process.Spawn.Configuration(executable: "/usr/bin/false")
        )
        #expect(status == .exited(code: 1))
    }

    @Test("Spawning /usr/bin/env with explicit environment yields exit 0")
    func spawnWithEnvironment() throws {
        let status = try Process.Spawn.run(
            Process.Spawn.Configuration(
                executable: "/usr/bin/env",
                arguments: ["true"],
                environment: ["PATH": "/usr/bin:/bin"]
            )
        )
        #expect(status == .exited(code: 0))
    }

    @Test("Interior NUL in executable path is rejected at index 0")
    func interiorNULRejected() throws {
        do throws(Process.Error) {
            _ = try Process.Spawn.run(
                Process.Spawn.Configuration(executable: "/usr/bin/\0true")
            )
            Issue.record("expected throw, got success")
        } catch {
            #expect(error == .invalidPath(index: 0))
        }
    }

    @Test("Spawning a non-existent executable surfaces a typed spawn error")
    func nonexistentExecutable() throws {
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
