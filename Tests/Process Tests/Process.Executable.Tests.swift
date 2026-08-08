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

extension Process.Executable {
    @Suite
    struct Integration {
        @Test
        func `controlled PATH launches Swift by command name`() throws(Process.Error) {
            let explicit = try Process.Executable.resolve("swift")
            guard let directory = Self._directory(of: explicit) else {
                Issue.record("resolved Swift executable has no parent directory: \(explicit)")
                return
            }

            #if os(Windows)
                let environment = ["Path": directory, "PATHEXT": ".EXE"]
            #else
                let environment = ["PATH": directory]
            #endif

            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: "swift",
                    arguments: ["--version"],
                    environment: environment,
                    stdout: .pipe
                )
            )
            #expect(output.status == .exited(code: 0))
        }

        @Test
        func `explicit executable path is preserved`() throws(Process.Error) {
            let explicit = try Process.Executable.resolve("swift")
            let resolved = try Process.Executable.resolve(explicit, environment: [:])
            #expect(resolved == explicit)
        }

        @Test
        func `missing command is a typed process failure`() {
            let command = "swift-process-command-that-does-not-exist"
            #if os(Windows)
                let environment = ["Path": "", "PATHEXT": ".EXE"]
            #else
                let environment = ["PATH": ""]
            #endif

            do throws(Process.Error) {
                _ = try Process.Spawn.run(
                    Process.Spawn.Configuration(
                        executable: command,
                        environment: environment
                    )
                )
                Issue.record("expected a typed missing-command failure")
            } catch {
                #expect(error == .missing(command: command))
            }
        }

        private static func _directory(of executable: Swift.String) -> Swift.String? {
            #if os(Windows)
                let separator = executable.lastIndex(where: { $0 == "\\" || $0 == "/" })
            #else
                let separator = executable.lastIndex(of: "/")
            #endif
            guard let separator else {
                return nil
            }
            return Swift.String(executable[..<separator])
        }
    }
}
