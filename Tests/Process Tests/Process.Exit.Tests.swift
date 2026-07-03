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

/// Structural compile-time tests for ``Process/exit(_:)``.
///
/// `Process.exit(_:)` cannot be unit-tested via invocation — it
/// terminates the test process. These tests verify the surface
/// exists, has the right type signature, and is reachable from the
/// public API surface, by referencing the function as a typed
/// `(Int32) -> Never` value without calling it.
@Suite("Process.exit structural tests")
struct ProcessExitStructuralTests {
    @Test("Process.exit(_:) is reachable as a typed function value")
    func exitIsReachable() {
        // Type-check: capture the static method as a function value.
        // If the surface compiled away, this would fail to compile.
        let fn: (Int32) -> Never = Process.exit(_:)
        // Reference the value to silence unused-binding warnings without
        // invoking it (invocation would terminate this test process).
        _ = fn
    }
}
