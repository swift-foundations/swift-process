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

extension Process.Spawn.Executable {
    /// The directories of a `PATH`-style search list, split on the
    /// platform's list separator (`:` on POSIX, `;` on Windows).
    ///
    /// Empty entries are preserved so callers can honor the platform's
    /// own semantics for them (POSIX treats an empty entry as the
    /// current directory; Windows skips it). This is the public face of
    /// the split ``resolve(_:)`` performs internally, exposed so
    /// consumers asking "is this directory on `PATH`?" share the
    /// owner's separator semantics instead of hand-splitting on `:`.
    ///
    /// - Parameter list: a `PATH`-style search list.
    /// - Returns: the entries, in search order.
    public static func directories(in list: Swift.String) -> [Swift.Substring] {
        _splitSearchList(list)
    }
}
