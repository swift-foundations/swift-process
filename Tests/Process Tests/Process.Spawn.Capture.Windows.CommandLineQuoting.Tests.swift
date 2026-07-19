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

// F-002 regression coverage. `_quoteWindowsCommandLineArgument` is a pure
// `String` transform with no WinSDK dependency (see the "Command-line
// quoting (platform-independent)" section of
// Process.Spawn.Capture.Windows.swift), so — unlike the rest of the
// Windows spawn path — it compiles and runs on every platform. This file
// is deliberately NOT gated behind `#if os(Windows)`: that is what makes
// it possible to capture real, verbatim pre-fix-FAILING /
// post-fix-PASSING `swift test` output on a non-Windows implementation
// host for this finding.

import Testing
@testable import Process

extension Process.Spawn {
    @Suite
    struct `Edge Case` {

        // MARK: - No quoting needed

        @Test("A simple token with no whitespace or quotes passes through unchanged")
        func plainTokenPassesThroughUnchanged() {
            #expect(Process.Spawn._quoteWindowsCommandLineArgument("hello") == "hello")
            #expect(
                Process.Spawn._quoteWindowsCommandLineArgument("C:\\Windows\\System32\\cmd.exe")
                    == "C:\\Windows\\System32\\cmd.exe"
            )
        }

        // MARK: - Injection surface: whitespace

        @Test("An argument containing a space is wrapped in quotes rather than naively space-joined")
        func argumentContainingSpaceIsQuoted() {
            // Pre-fix, `"echo hello" + " " + "two words"` naively space-joined
            // to `echo hello two words`, which CommandLineToArgvW on the
            // child side parses as FOUR argv entries, not two — the exact
            // argument-corruption bug F-002 reports.
            #expect(Process.Spawn._quoteWindowsCommandLineArgument("two words") == "\"two words\"")
        }

        @Test("An empty argument is quoted so it still occupies its own argv slot")
        func emptyArgumentIsQuoted() {
            #expect(Process.Spawn._quoteWindowsCommandLineArgument("") == "\"\"")
        }

        // MARK: - Injection surface: embedded quotes

        @Test("An embedded double quote is escaped, not passed through raw")
        func embeddedQuoteIsEscaped() {
            // Pre-fix, a caller-supplied argument like `foo" injected"` was
            // concatenated into the command line verbatim: the un-escaped
            // `"` let the child's argv parser treat the remainder as new,
            // attacker-controlled tokens — the injection half of F-002.
            #expect(Process.Spawn._quoteWindowsCommandLineArgument("say \"hi\"") == "\"say \\\"hi\\\"\"")
        }

        // MARK: - Backslash-run edge cases (Microsoft's documented algorithm)

        @Test("A trailing backslash run is doubled before the closing quote")
        func trailingBackslashRunIsDoubled() {
            // "a\" (one trailing backslash needing quoting because of the
            // embedded space) → `"a\\ "` is wrong; the correct expansion
            // doubles only the trailing run, then closes the quote.
            #expect(Process.Spawn._quoteWindowsCommandLineArgument("a\\ b\\") == "\"a\\ b\\\\\"")
        }

        @Test("A backslash run immediately before an embedded quote is doubled-plus-one, then the quote is escaped")
        func backslashRunBeforeEmbeddedQuoteIsDoubledPlusOne() {
            // `a\"b` (one backslash directly preceding a literal `"`)
            // expands to two backslashes (escaping the run) + an escaped
            // quote + the rest: `"a\\\"b"`.
            #expect(Process.Spawn._quoteWindowsCommandLineArgument("a\\\"b") == "\"a\\\\\\\"b\"")
        }

        @Test("A backslash run not adjacent to a quote is left literal")
        func backslashRunNotAdjacentToQuoteStaysLiteral() {
            // Backslashes that never abut a `"` are ordinary path
            // separators and must NOT be doubled, or Windows paths break.
            #expect(
                Process.Spawn._quoteWindowsCommandLineArgument("C:\\Program Files\\App")
                    == "\"C:\\Program Files\\App\""
            )
        }

        // MARK: - Executable token is quoted too

        @Test("The executable token itself is quoted when it contains a space, not just the arguments")
        func executableTokenIsQuotedWhenItContainsASpace() {
            // Pre-fix, only a naive space-join was used for the whole
            // command line — `configuration.executable` was never quoted
            // even though it is the first token CreateProcessW's
            // lpCommandLine parser splits on.
            #expect(
                Process.Spawn._quoteWindowsCommandLineArgument("C:\\Program Files\\App\\app.exe")
                    == "\"C:\\Program Files\\App\\app.exe\""
            )
        }
    }
}
