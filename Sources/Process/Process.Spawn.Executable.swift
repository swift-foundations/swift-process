extension Process.Spawn {

    public enum Executable: Sendable {}
}

extension Process.Spawn.Executable {

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

    @usableFromInline
    internal static func _splitSearchList(_ list: Swift.String) -> [Substring] {
        list.split(separator: _listSeparator, omittingEmptySubsequences: false)
    }

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
