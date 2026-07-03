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

    @Suite("Process pipe capture + workingDirectory")
    struct ProcessSpawnCaptureTests {

        // MARK: - stdout capture

        @Test("echo hello → captured stdout is 'hello\\n'")
        func captureEchoStdout() throws {
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: "/bin/echo",
                    arguments: ["hello"],
                    stdout: .pipe
                )
            )
            #expect(output.status == .exited(code: 0))
            #expect(output.stderr == nil)

            let bytes = try #require(output.stdout)
            let text = Swift.String(decoding: bytes, as: UTF8.self)
            #expect(text == "hello\n")
        }

        // MARK: - stderr capture

        @Test("sh -c 'echo err >&2' → captured stderr is 'err\\n'")
        func captureStderrFromSubshell() throws {
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: "/bin/sh",
                    arguments: ["-c", "echo err 1>&2"],
                    stderr: .pipe
                )
            )
            #expect(output.status == .exited(code: 0))
            #expect(output.stdout == nil)

            let bytes = try #require(output.stderr)
            let text = Swift.String(decoding: bytes, as: UTF8.self)
            #expect(text == "err\n")
        }

        // MARK: - both captures

        @Test("sh -c '… stdout … stderr …' → both captured")
        func captureBothStreams() throws {
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: "/bin/sh",
                    arguments: ["-c", "echo out; echo err 1>&2"],
                    stdout: .pipe,
                    stderr: .pipe
                )
            )
            #expect(output.status == .exited(code: 0))

            let outBytes = try #require(output.stdout)
            let errBytes = try #require(output.stderr)
            #expect(Swift.String(decoding: outBytes, as: UTF8.self) == "out\n")
            #expect(Swift.String(decoding: errBytes, as: UTF8.self) == "err\n")
        }

        // MARK: - workingDirectory

        @Test("pwd with workingDirectory: '/tmp' → child cwd is /tmp")
        func workingDirectoryPwd() throws {
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: "/bin/pwd",
                    stdout: .pipe,
                    workingDirectory: "/tmp"
                )
            )
            #expect(output.status == .exited(code: 0))

            let bytes = try #require(output.stdout)
            let text = Swift.String(decoding: bytes, as: UTF8.self)
                .trimmingTrailingNewlines
            // macOS resolves /tmp to /private/tmp; both forms are accepted.
            #expect(text == "/tmp" || text == "/private/tmp", "got: \(text)")
        }

        // MARK: - error paths

        @Test("stdin: .pipe is rejected with streamPolicyUnsupported (v2)")
        func stdinPipeRejected() throws {
            do throws(Process.Error) {
                _ = try Process.Spawn.run(
                    Process.Spawn.Configuration(
                        executable: "/usr/bin/cat",
                        stdin: .pipe,
                        stdout: .pipe
                    )
                )
                Issue.record("expected throw")
            } catch {
                #expect(error == .streamPolicyUnsupported)
            }
        }

        @Test("spawn() rejects .pipe streams (run() is the v2 entry point)")
        func spawnRejectsPipe() throws {
            do throws(Process.Error) {
                _ = try Process.Spawn.spawn(
                    Process.Spawn.Configuration(
                        executable: "/usr/bin/true",
                        stdout: .pipe
                    )
                )
                Issue.record("expected throw")
            } catch {
                #expect(error == .streamPolicyUnsupported)
            }
        }

        @Test("spawn() rejects non-nil workingDirectory")
        func spawnRejectsWorkingDirectory() throws {
            do throws(Process.Error) {
                _ = try Process.Spawn.spawn(
                    Process.Spawn.Configuration(
                        executable: "/usr/bin/true",
                        workingDirectory: "/tmp"
                    )
                )
                Issue.record("expected throw")
            } catch {
                #expect(error == .streamPolicyUnsupported)
            }
        }
    }

    // MARK: - String trimming helper

    extension Swift.String {
        fileprivate var trimmingTrailingNewlines: Swift.String {
            var s = self
            while s.last == "\n" || s.last == "\r" {
                s.removeLast()
            }
            return s
        }
    }

#endif  // !os(Windows)
