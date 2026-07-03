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

    import Testing
    @testable import Process

    @Suite("Process pipe capture + workingDirectory (Windows)")
    struct ProcessSpawnCaptureWindowsTests {

        // MARK: - stdout capture

        @Test("cmd.exe /C 'echo hello' → captured stdout is 'hello\\r\\n'")
        func captureEchoStdout() throws {
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: "C:\\Windows\\System32\\cmd.exe",
                    arguments: ["/C", "echo hello"],
                    stdout: .pipe
                )
            )
            #expect(output.status == .exited(code: 0))
            #expect(output.stderr == nil)

            let bytes = try #require(output.stdout)
            let text = Swift.String(decoding: bytes, as: UTF8.self)
            #expect(text == "hello\r\n")
        }

        // MARK: - stderr capture

        @Test("cmd.exe /C 'echo err 1>&2' → captured stderr is 'err\\r\\n'")
        func captureStderrFromCmd() throws {
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: "C:\\Windows\\System32\\cmd.exe",
                    arguments: ["/C", "echo err 1>&2"],
                    stderr: .pipe
                )
            )
            #expect(output.status == .exited(code: 0))
            #expect(output.stdout == nil)

            let bytes = try #require(output.stderr)
            let text = Swift.String(decoding: bytes, as: UTF8.self)
            #expect(text == "err\r\n")
        }

        // MARK: - both captures

        @Test("powershell.exe Write-Output 'out' + Write-Error 'err' → both captured")
        func captureBothStreams() throws {
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
                    arguments: [
                        "-NoProfile",
                        "-Command",
                        "Write-Output 'out'; Write-Error 'err'",
                    ],
                    stdout: .pipe,
                    stderr: .pipe
                )
            )
            // PowerShell Write-Error sets exit to non-zero by default; we just
            // verify both streams were captured.
            let outBytes = try #require(output.stdout)
            let errBytes = try #require(output.stderr)
            let outText = Swift.String(decoding: outBytes, as: UTF8.self)
            let errText = Swift.String(decoding: errBytes, as: UTF8.self)
            #expect(outText.contains("out"))
            #expect(errText.contains("err"))
        }

        // MARK: - workingDirectory

        @Test("cmd.exe /C 'echo %CD%' with workingDirectory: 'C:\\Windows' → cwd is C:\\Windows")
        func workingDirectoryCD() throws {
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: "C:\\Windows\\System32\\cmd.exe",
                    arguments: ["/C", "echo %CD%"],
                    stdout: .pipe,
                    workingDirectory: "C:\\Windows"
                )
            )
            #expect(output.status == .exited(code: 0))

            let bytes = try #require(output.stdout)
            let text = Swift.String(decoding: bytes, as: UTF8.self)
                .trimmingTrailingNewlinesWin
            // CD output ends with \r\n on Windows; trim and case-insensitive match.
            #expect(text.lowercased() == "c:\\windows", "got: \(text)")
        }

        // MARK: - error paths

        @Test("stdin: .pipe is rejected with streamPolicyUnsupported (v2)")
        func stdinPipeRejected() throws {
            do throws(Process.Error) {
                _ = try Process.Spawn.run(
                    Process.Spawn.Configuration(
                        executable: "C:\\Windows\\System32\\cmd.exe",
                        arguments: ["/C", "type CON"],
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
                        executable: "C:\\Windows\\System32\\cmd.exe",
                        arguments: ["/C", "exit 0"],
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
                        executable: "C:\\Windows\\System32\\cmd.exe",
                        arguments: ["/C", "exit 0"],
                        workingDirectory: "C:\\Windows"
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
        fileprivate var trimmingTrailingNewlinesWin: Swift.String {
            var s = self
            while s.last == "\n" || s.last == "\r" {
                s.removeLast()
            }
            return s
        }
    }

#endif  // os(Windows)
