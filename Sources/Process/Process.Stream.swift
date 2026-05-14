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

extension Process {
    /// Disposition of a child process's standard stream
    /// (`stdin`, `stdout`, `stderr`).
    ///
    /// ## v2 Coverage
    ///
    /// v2 ships ``inherit`` and ``pipe``. The pipe case routes the
    /// stream through an anonymous pipe pair: the child sees one end,
    /// the parent reads/writes the other.
    ///
    /// The slot determines who-gets-which-end:
    ///
    /// | Slot   | Child gets       | Parent gets       |
    /// |--------|------------------|-------------------|
    /// | stdin  | read end         | write end         |
    /// | stdout | write end        | read end          |
    /// | stderr | write end        | read end          |
    ///
    /// When stdout or stderr is ``pipe``, ``Process/Spawn/run(_:)``
    /// drains the parent-side read end synchronously and surfaces the
    /// captured bytes via ``Process/Output``.
    ///
    /// ## Reserved for v3
    ///
    /// Further redirection forms (gated on additional
    /// `posix_spawn_file_actions_*` adoption in ``swift-iso-9945``):
    ///
    ///   - `discard`: redirect to `/dev/null`.
    ///   - `file(Path)`: redirect to a caller-supplied file.
    public enum Stream: Sendable, Equatable {
        /// Child inherits the parent's open file descriptor.
        ///
        /// Implemented via `posix_spawn` without file actions, which
        /// preserves the parent's stream as the child's same stream
        /// (POSIX `posix_spawn(3)` default).
        case inherit

        /// Child's stream is connected to one end of an anonymous pipe;
        /// the parent owns the other end.
        ///
        /// See the per-slot table on ``Stream`` for which side the
        /// child and parent each see. Captured output from
        /// `pipe`-routed stdout / stderr is surfaced via
        /// ``Process/Output`` when the call goes through
        /// ``Process/Spawn/run(_:)``.
        case pipe
    }
}
