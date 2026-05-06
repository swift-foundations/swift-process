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

/// Foundation-clean subprocess primitive.
///
/// `Process` is the cross-platform domain unifier for subprocess
/// spawning, waiting, and lifecycle management. It composes the
/// platform-typed primitives from ``swift-posix`` (POSIX) and, in
/// future, ``swift-windows`` (Win32 ``CreateProcessW``) per the
/// institute's L3-policy → L3-unifier convention.
///
/// ## Foundation-clean
///
/// `Process` does NOT import Apple's `Foundation` framework. It
/// composes typed L2 / L3-policy syscall wrappers exclusively. This
/// is the architectural difference from `Foundation.Process`, which
/// drags in the entire Foundation framework.
///
/// ## Usage
///
/// ```swift
/// let status = try Process.Spawn.run(
///     Process.Spawn.Configuration(
///         executable: "/usr/bin/echo",
///         arguments: ["hello", "world"]
///     )
/// )
/// guard case .exited(let code) = status, code == 0 else {
///     throw MyError.commandFailed
/// }
/// ```
///
/// ## Architecture (L3-unifier, [PLAT-ARCH-008h])
///
/// `Process` sits at the L3-unifier sub-tier of the platform stack.
/// It composes the L3-policy tier (``swift-posix``) directly per
/// [PLAT-ARCH-008e], following the same pattern as ``swift-systems``
/// and ``swift-environment``. Domain consumers (build tools,
/// process supervisors, IDE integrations) compose this package
/// rather than reaching into ``swift-posix`` directly.
public enum Process: Sendable {}
