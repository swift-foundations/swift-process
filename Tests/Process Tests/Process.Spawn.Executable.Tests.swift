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

extension Process.Spawn.Executable {
    /// Cross-platform executable resolution: bare name → `PATH` search;
    /// path with separator → as-is. Every test here runs on POSIX and
    /// Windows; only the program used differs per platform.
    @Suite
    struct Test {
        /// A program guaranteed present on every runner: the platform's
        /// command interpreter.
        #if os(Windows)
            static let interpreter = "cmd"
            static let interpreterPath = "C:\\Windows\\System32\\cmd.exe"
            static func exitArguments(_ code: Int) -> [Swift.String] { ["/C", "exit \(code)"] }
            static let echoArguments = ["/C", "echo hello"]
            static let separator: Character = "\\"
        #else
            static let interpreter = "sh"
            static let interpreterPath = "/bin/sh"
            static func exitArguments(_ code: Int) -> [Swift.String] { ["-c", "exit \(code)"] }
            static let echoArguments = ["-c", "echo hello"]
            static let separator: Character = "/"
        #endif

        @Test
        func `Bare interpreter name resolves to a path containing a separator`() throws {
            let resolved = try Process.Spawn.Executable.resolve(Self.interpreter)
            #expect(resolved.contains(Self.separator))
            #expect(resolved.lowercased().contains(Self.interpreter))
        }

        @Test
        func `Value containing a separator is returned as-is`() throws {
            let resolved = try Process.Spawn.Executable.resolve(Self.interpreterPath)
            #expect(resolved == Self.interpreterPath)
        }

        @Test
        func `Bare name spawns through the fast path and reports the child's exit code`() throws {
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: Self.interpreter,
                    arguments: Self.exitArguments(3)
                )
            )
            #expect(output.status == .exited(code: 3))
        }

        @Test
        func `Bare name spawns through the capture path and stdout is drained`() throws {
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: Self.interpreter,
                    arguments: Self.echoArguments,
                    stdout: .pipe
                )
            )
            #expect(output.status == .exited(code: 0))
            let stdout = try #require(output.stdout)
            #expect(stdout.starts(with: Array("hello".utf8)))
        }

        @Test
        func `Unresolvable bare name throws executableNotFound naming the program`() throws {
            let name = "swift-process-no-such-program-4f9c1e"
            do throws(Process.Error) {
                _ = try Process.Spawn.Executable.resolve(name)
                Issue.record("expected throw, got success")
            } catch {
                #expect(error == .executableNotFound(name))
            }
            do throws(Process.Error) {
                _ = try Process.Spawn.run(Process.Spawn.Configuration(executable: name))
                Issue.record("expected throw, got success")
            } catch {
                #expect(error == .executableNotFound(name))
            }
        }

        #if os(Windows)
            @Test
            func `PATHEXT supplies the .exe suffix for a bare Windows name`() throws {
                let resolved = try Process.Spawn.Executable.resolve("cmd")
                #expect(resolved.lowercased().hasSuffix("\\cmd.exe"))
            }

            @Test
            func `A bare Windows name that already carries .exe resolves too`() throws {
                let resolved = try Process.Spawn.Executable.resolve("cmd.exe")
                #expect(resolved.lowercased().hasSuffix("\\cmd.exe"))
            }
        #endif
    }
}
