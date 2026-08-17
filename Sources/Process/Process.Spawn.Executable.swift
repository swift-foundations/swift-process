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

extension Process.Spawn {
    /// Executable resolution: turns
    /// ``Process/Spawn/Configuration/executable`` into the path handed
    /// to the platform spawn primitive.
    ///
    /// ## Contract (identical on every platform)
    ///
    /// - A value containing a path separator (`/` on POSIX; `/`, `\`,
    ///   or a drive `:` on Windows) is used **as-is**. Absolute and
    ///   relative paths are handed to the kernel unchanged.
    /// - A bare program name (no separator) is searched for in the
    ///   **parent process's** `PATH`, first match wins:
    ///   - POSIX: `PATH` split on `:`; an empty entry means the current
    ///     directory (as `execvp(3)` / `posix_spawnp(3)` do). A candidate
    ///     matches when it is a regular file with any execute bit set.
    ///   - Windows: `PATH` split on `;`; empty entries are skipped. A
    ///     candidate matches when the file exists and is not a
    ///     directory. If the name has no extension, each `PATHEXT`
    ///     extension (default `.COM;.EXE;.BAT;.CMD`) is appended in
    ///     order; if it has one, the name is tried verbatim first and
    ///     then with each `PATHEXT` extension.
    /// - No match throws ``Process/Error/executableNotFound(_:)``
    ///   naming the searched program.
    ///
    /// The search always consults the parent's environment, never
    /// ``Process/Spawn/Configuration/environment`` — matching
    /// `posix_spawnp(3)` and `CreateProcessW` (with a `nil`
    /// `lpApplicationName`), both of which resolve in the caller's
    /// environment before the child's is installed.
    ///
    /// The child's `argv[0]` (POSIX) / first command-line token
    /// (Windows) is the value the caller configured, not the resolved
    /// path, again matching the `posix_spawnp` convention.
    public enum Executable: Sendable {}
}

extension Process.Spawn.Executable {
    /// Resolves `executable` per the documented contract.
    ///
    /// - Parameter executable: ``Process/Spawn/Configuration/executable``.
    /// - Returns: the path to hand to the platform spawn primitive.
    /// - Throws: ``Process/Error/executableNotFound(_:)`` when a bare
    ///   name matches nothing on `PATH`.
    public static func resolve(
        _ executable: Swift.String
    ) throws(Process.Error) -> Swift.String {
        if _containsSeparator(executable) {
            return executable
        }
        if let resolved = _searchPath(executable) {
            return resolved
        }
        throw .executableNotFound(executable)
    }

    /// Splits a `PATH`-style list on the platform's list separator.
    @usableFromInline
    internal static func _splitSearchList(_ list: Swift.String) -> [Substring] {
        list.split(separator: _listSeparator, omittingEmptySubsequences: false)
    }

    /// Reads a variable from the parent process's environment.
    ///
    /// Composes ``Process/Spawn/_inheritedEnvironment()`` so no
    /// platform-C imports leak into this file. Names compare
    /// case-insensitively on Windows and exactly elsewhere.
    @usableFromInline
    internal static func _environmentValue(_ name: Swift.String) -> Swift.String? {
        for entry in Process.Spawn._inheritedEnvironment() {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = entry[entry.startIndex..<equals]
            guard _environmentNamesMatch(key, name) else { continue }
            return Swift.String(entry[entry.index(after: equals)...])
        }
        return nil
    }
}
