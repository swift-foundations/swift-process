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

    internal import Path_Primitives
    internal import POSIX_Kernel

    extension Process.Spawn.Executable {
        /// `PATH` list separator on POSIX.
        @usableFromInline
        internal static var _listSeparator: Character { ":" }

        /// A value containing `/` is a path and is used as-is.
        @usableFromInline
        internal static func _containsSeparator(_ executable: Swift.String) -> Bool {
            executable.contains("/")
        }

        /// POSIX environment names are case-sensitive.
        @usableFromInline
        internal static func _environmentNamesMatch(_ key: Substring, _ name: Swift.String) -> Bool
        {
            key == name
        }

        /// Searches the parent's `PATH` for `name`.
        ///
        /// Mirrors `execvp(3)`: entries are tried in order, an empty
        /// entry denotes the current directory, and the first regular
        /// file with any execute bit set wins. Candidates that cannot
        /// be `stat(2)`ed (missing, unreadable, interior NUL) are
        /// skipped.
        @usableFromInline
        internal static func _searchPath(_ name: Swift.String) -> Swift.String? {
            guard let path = _environmentValue("PATH") else { return nil }
            for directory in _splitSearchList(path) {
                let candidate: Swift.String
                if directory.isEmpty {
                    candidate = name
                } else if directory.hasSuffix("/") {
                    candidate = Swift.String(directory) + name
                } else {
                    candidate = Swift.String(directory) + "/" + name
                }
                if _isExecutableFile(candidate) {
                    return candidate
                }
            }
            return nil
        }

        /// `true` when `candidate` is a regular file with any execute
        /// bit set (following symlinks).
        @usableFromInline
        internal static func _isExecutableFile(_ candidate: Swift.String) -> Bool {
            let stats: ISO_9945.Kernel.File.Stats
            do throws(Path.String.Error<ISO_9945.Kernel.File.Stats.Error>) {
                stats = try Path.scope(candidate) {
                    (
                        view: borrowing Path.Borrowed
                    ) throws(ISO_9945.Kernel.File.Stats.Error)
                        -> ISO_9945.Kernel.File.Stats in
                    try ISO_9945.Kernel.File.Stats.get(path: view)
                }
            } catch {
                return false
            }
            guard stats.type == .regular else { return false }
            let anyExecute: ISO_9945.Kernel.File.Permissions =
                .ownerExecute | .groupExecute | .otherExecute
            return (stats.permissions & anyExecute) != .none
        }
    }

#endif
