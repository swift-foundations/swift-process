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

    internal import Windows_Kernel_File
    internal import WinSDK

    extension Process.Spawn.Executable {
        /// `PATH` / `PATHEXT` list separator on Windows.
        @usableFromInline
        internal static var _listSeparator: Character { ";" }

        /// `PATHEXT` fallback when the variable is unset or empty.
        @usableFromInline
        internal static let _defaultExtensions: [Substring] = [".COM", ".EXE", ".BAT", ".CMD"]

        /// A value containing `\`, `/`, or a drive `:` is a path and is
        /// used as-is (`CreateProcessW` accepts either slash direction).
        @usableFromInline
        internal static func _containsSeparator(_ executable: Swift.String) -> Bool {
            executable.utf16.contains { unit in
                unit == 0x5C /* \ */ || unit == 0x2F /* / */ || unit == 0x3A /* : */
            }
        }

        /// Windows environment names are case-insensitive.
        @usableFromInline
        internal static func _environmentNamesMatch(_ key: Substring, _ name: Swift.String) -> Bool {
            key.count == name.count && key.uppercased() == name.uppercased()
        }

        /// Searches the parent's `PATH` for `name`, applying `PATHEXT`.
        ///
        /// Empty `PATH` entries are skipped (the current directory is
        /// deliberately not searched). Within a directory, a name that
        /// already carries an extension is tried verbatim first; every
        /// `PATHEXT` extension is then appended in order. The first
        /// existing non-directory wins.
        @usableFromInline
        internal static func _searchPath(_ name: Swift.String) -> Swift.String? {
            guard let path = _environmentValue("PATH") else { return nil }
            let extensions = _extensions()
            let hasExtension = name.utf16.contains(0x2E /* . */)
            for directory in _splitSearchList(path) where !directory.isEmpty {
                let base: Swift.String
                if directory.hasSuffix("\\") || directory.hasSuffix("/") {
                    base = Swift.String(directory) + name
                } else {
                    base = Swift.String(directory) + "\\" + name
                }
                if hasExtension, _isExecutableFile(base) {
                    return base
                }
                for ext in extensions {
                    let candidate = base + ext
                    if _isExecutableFile(candidate) {
                        return candidate
                    }
                }
            }
            return nil
        }

        /// `PATHEXT` entries, or ``_defaultExtensions`` when unset/empty.
        @usableFromInline
        internal static func _extensions() -> [Substring] {
            guard let pathext = _environmentValue("PATHEXT") else {
                return _defaultExtensions
            }
            let entries = _splitSearchList(pathext).filter { !$0.isEmpty }
            return entries.isEmpty ? _defaultExtensions : entries
        }

        /// `true` when `candidate` exists and is not a directory.
        @usableFromInline
        internal static func _isExecutableFile(_ candidate: Swift.String) -> Bool {
            var units: [WCHAR] = Array(candidate.utf16)
            units.append(0)
            return unsafe units.withUnsafeBufferPointer { (buffer: UnsafeBufferPointer<WCHAR>) -> Bool in
                guard let base = unsafe buffer.baseAddress else { return false }
                guard let attributes = unsafe Windows.`32`.Kernel.File.getAttributes(path: base) else {
                    return false
                }
                return !attributes.contains(.directory)
            }
        }
    }

#endif
