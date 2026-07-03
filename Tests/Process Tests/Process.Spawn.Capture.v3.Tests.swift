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

    /// v3 regression suite — concurrent pipe drain (resolves the 64-KiB
    /// deadlock) plus per-spawn timeout.
    ///
    /// `.timeLimit` per test catches a regression-induced hang well before
    /// the test runner's default infinite wait.
    @Suite("Process v3: concurrent drain + timeout")
    struct ProcessSpawnV3Tests {

        // MARK: - Concurrent drain (the >64-KiB regression)

        /// The empirical trigger for promoting drain to concurrent in v3:
        /// the child writes 256 KiB to stderr while the parent is still
        /// reading stdout. With v2's sequential drain (stdout-then-stderr),
        /// the child blocks on the stderr write at the 64-KiB pipe-buffer
        /// boundary, stdout never advances, deadlock. With v3's concurrent
        /// drain, both pipes are serviced via `poll(2)` and the child
        /// completes.
        ///
        /// 256 KiB chosen as 4 * default Linux pipe-buffer size — large
        /// enough to wedge any plausible buffer size while still completing
        /// fast on a green run.
        @Test("256 KiB stderr does not deadlock (v2 would hang)", .timeLimit(.minutes(1)))
        func concurrentDrainStderr256KiB() throws {
            // `dd` is universally available on macOS / Linux and emits
            // exactly the requested byte count to whichever fd we redirect.
            // Shell redirection: `1>&2` first repoints fd 1 to where fd 2
            // currently points (the parent's stderr pipe); `2>/dev/null`
            // then silences dd's own diagnostic. Net: 256 KiB lands on
            // stderr, and a final `echo done` writes to stdout (which is
            // back to the parent's stdout pipe — `echo` is a separate
            // command in the sequence and inherits the original fds).
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "dd if=/dev/zero bs=1024 count=256 1>&2 2>/dev/null; echo done",
                    ],
                    stdout: .pipe,
                    stderr: .pipe
                )
            )
            #expect(output.status == .exited(code: 0))
            let stdoutBytes = try #require(output.stdout)
            let stderrBytes = try #require(output.stderr)
            // stdout: just the "done\n" from echo.
            let stdoutText = Swift.String(decoding: stdoutBytes, as: UTF8.self)
            #expect(stdoutText.contains("done"))
            // stderr: exactly 256 KiB of zero bytes from dd.
            #expect(
                stderrBytes.count == 256 * 1024,
                "expected exactly 256 KiB on stderr, got \(stderrBytes.count)"
            )
        }

        /// Mirror test: 256 KiB to stdout while stderr stays small. Same
        /// shape as the canonical regression but with the streams swapped
        /// — confirms concurrent drain works in either direction.
        @Test("256 KiB stdout does not deadlock", .timeLimit(.minutes(1)))
        func concurrentDrainStdout256KiB() throws {
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "dd if=/dev/zero bs=1024 count=256 2>/dev/null; echo err 1>&2",
                    ],
                    stdout: .pipe,
                    stderr: .pipe
                )
            )
            #expect(output.status == .exited(code: 0))
            let stdoutBytes = try #require(output.stdout)
            let stderrBytes = try #require(output.stderr)
            #expect(
                stdoutBytes.count >= 256 * 1024,
                "expected ≥ 256 KiB on stdout, got \(stdoutBytes.count)"
            )
            #expect(Swift.String(decoding: stderrBytes, as: UTF8.self) == "err\n")
        }

        /// Both pipes oversized in the same run: 128 KiB to each. Both
        /// must complete without one wedging the other.
        ///
        /// First `dd` writes 128 KiB to stdout (its diagnostic to the
        /// inherited stderr is suppressed). Second `dd` redirects its
        /// stdout (the data) to fd 2 first (`1>&2`), then silences its
        /// own diagnostic — 128 KiB lands on the parent's stderr pipe.
        @Test("128 KiB on both pipes does not deadlock", .timeLimit(.minutes(1)))
        func concurrentDrainBothPipes128KiB() throws {
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        """
                        dd if=/dev/zero bs=1024 count=128 2>/dev/null; \
                        dd if=/dev/zero bs=1024 count=128 1>&2 2>/dev/null
                        """,
                    ],
                    stdout: .pipe,
                    stderr: .pipe
                )
            )
            #expect(output.status == .exited(code: 0))
            let stdoutBytes = try #require(output.stdout)
            let stderrBytes = try #require(output.stderr)
            #expect(
                stdoutBytes.count == 128 * 1024,
                "expected exactly 128 KiB on stdout, got \(stdoutBytes.count)"
            )
            #expect(
                stderrBytes.count == 128 * 1024,
                "expected exactly 128 KiB on stderr, got \(stderrBytes.count)"
            )
        }

        // MARK: - Timeout enforcement

        /// `/bin/sleep 30` is killed by SIGKILL when the 1-second deadline
        /// elapses. Wall-clock should be ≈ 1 s, well under the 5-second
        /// test deadline.
        @Test(
            "timeout fires: sleep 30 with 1s timeout → .signaled(SIGKILL)",
            .timeLimit(.minutes(1))
        )
        func timeoutFires() throws {
            let started = ContinuousClock().now
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: "/bin/sleep",
                    arguments: ["30"],
                    timeout: .seconds(1)
                )
            )
            let elapsed = ContinuousClock().now - started

            // Status: signaled by SIGKILL (numeric value 9 on POSIX).
            guard case .signaled(let signal) = output.status else {
                Issue.record("expected .signaled, got \(output.status)")
                return
            }
            #expect(signal == 9, "expected SIGKILL (9), got \(signal)")

            // Wall-clock: deadline + grace. 5 seconds is generous; a
            // regression that ignores the timeout would block for 30s and
            // hit the test's timeLimit instead.
            #expect(elapsed < .seconds(5), "elapsed: \(elapsed)")
        }

        /// `/bin/echo` with a generous timeout completes naturally —
        /// timeout does NOT fire.
        @Test(
            "timeout does not fire when child is fast",
            .timeLimit(.minutes(1))
        )
        func timeoutDoesNotFire() throws {
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: "/bin/echo",
                    arguments: ["hello"],
                    timeout: .seconds(10)
                )
            )
            #expect(output.status == .exited(code: 0))
        }

        /// Timeout combined with both pipes: the watchdog must coexist
        /// with the concurrent-drain path. Sleep child writes nothing
        /// before being killed; both pipe captures should be present
        /// (possibly empty arrays).
        @Test(
            "timeout fires while pipes are armed",
            .timeLimit(.minutes(1))
        )
        func timeoutWithPipes() throws {
            let started = ContinuousClock().now
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: "/bin/sleep",
                    arguments: ["30"],
                    stdout: .pipe,
                    stderr: .pipe,
                    timeout: .seconds(1)
                )
            )
            let elapsed = ContinuousClock().now - started

            guard case .signaled(let signal) = output.status else {
                Issue.record("expected .signaled, got \(output.status)")
                return
            }
            #expect(signal == 9)
            #expect(elapsed < .seconds(5))
            // Both pipes were `.pipe`, so output fields are non-nil
            // (possibly empty since sleep emits nothing).
            #expect(output.stdout != nil)
            #expect(output.stderr != nil)
        }

        /// Captured bytes drained BEFORE the kill survive into the result.
        /// Uses `/usr/bin/yes` (an infinite stdout writer); the kill
        /// fires after enough bytes have flowed for us to verify
        /// non-empty capture.
        ///
        /// `yes` is the direct child (no sh wrapper) so SIGKILL
        /// propagation is straightforward — sh-wrapped variants reparent
        /// `sleep` etc. to init, leaving our pipe-end-holders alive.
        @Test(
            "partial capture survives the timeout kill",
            .timeLimit(.minutes(1))
        )
        func partialCaptureBeforeKill() throws {
            let started = ContinuousClock().now
            let output = try Process.Spawn.run(
                Process.Spawn.Configuration(
                    executable: "/usr/bin/yes",
                    arguments: ["HELLO_BEFORE_KILL"],
                    stdout: .pipe,
                    stderr: .pipe,
                    timeout: .seconds(1)
                )
            )
            let elapsed = ContinuousClock().now - started

            guard case .signaled(let signal) = output.status else {
                Issue.record("expected .signaled, got \(output.status)")
                return
            }
            #expect(signal == 9)
            // Wall-clock should be ~1 s; far less than the test timeLimit.
            #expect(elapsed < .seconds(5), "elapsed: \(elapsed)")

            let bytes = try #require(output.stdout)
            let text = Swift.String(decoding: bytes, as: UTF8.self)
            #expect(
                text.contains("HELLO_BEFORE_KILL"),
                "captured stdout (first 200 chars): \(text.prefix(200))"
            )
            #expect(bytes.count > 0, "expected non-empty capture")
        }

        /// Default timeout (`nil`) preserves v2 behavior: indefinite wait.
        /// Verifies the default-arg of the Configuration init is `nil`.
        @Test("nil timeout preserves indefinite-wait behavior")
        func nilTimeoutPreserved() throws {
            let configuration = Process.Spawn.Configuration(
                executable: "/usr/bin/true"
            )
            #expect(configuration.timeout == nil)
            let output = try Process.Spawn.run(configuration)
            #expect(output.status == .exited(code: 0))
        }
    }

#endif  // !os(Windows)
