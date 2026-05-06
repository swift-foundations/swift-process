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
    /// ## v1 Coverage
    ///
    /// v1 ships ``inherit`` only — the default behavior of
    /// ``ISO_9945/Kernel/Process/Spawn/spawn(path:argv:envp:)``
    /// (passing `nil` for `posix_spawn_file_actions_t`).
    ///
    /// Reserved for v2 (gated on adding
    /// `posix_spawn_file_actions_addclose` /
    /// `posix_spawn_file_actions_addopen` /
    /// `posix_spawn_file_actions_adddup2` to ``swift-iso-9945``):
    ///
    ///   - `discard`: redirect to `/dev/null` (`addopen` to
    ///     `/dev/null`).
    ///   - `file(Path)`: redirect to a file (`addopen` with caller-
    ///     supplied path + flags).
    ///   - `pipe(Kernel.Pipe.Descriptors.Side)`: redirect to one
    ///     end of an anonymous pipe (`adddup2`).
    ///
    /// Authoring guidance: stream values appear in
    /// ``Process/Spawn/Configuration``'s `stdin` / `stdout` /
    /// `stderr` slots; cross-references in those positions document
    /// the scope of the v1 behavior so it is clear what callers can
    /// expect.
    public enum Stream: Sendable, Equatable {
        /// Child inherits the parent's open file descriptor.
        ///
        /// Implemented via `posix_spawn` with `nil` file_actions,
        /// which preserves the parent's stream as the child's same
        /// stream (POSIX `posix_spawn(3)` default).
        case inherit
    }
}
