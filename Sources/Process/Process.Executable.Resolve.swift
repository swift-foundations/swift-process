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

internal import Path_Primitives
internal import Strings

#if os(Windows)
    internal import Windows_Kernel_File
#else
    internal import POSIX_Kernel
#endif

extension Process.Executable {
    /// Resolves a command name against the effective process environment.
    ///
    /// Values containing a platform path designator are explicit paths and
    /// are returned unchanged. Bare command names are searched in `PATH`.
    /// Windows additionally applies `PATHEXT` in its declared order.
    ///
    /// An explicit `environment` is a complete replacement environment, just
    /// like ``Process/Spawn/Configuration/environment``. Passing `nil`
    /// searches the parent process's inherited environment.
    ///
    /// - Parameters:
    ///   - command: A command name or explicit executable path.
    ///   - environment: The environment whose `PATH` policy should be used.
    /// - Returns: The resolved executable path, or `command` unchanged when it
    ///   was already explicit.
    /// - Throws: ``Process/Error/missing(command:)`` when no executable is
    ///   available under the effective search policy.
    public static func resolve(
        _ command: Swift.String,
        environment: [Swift.String: Swift.String]? = nil
    ) throws(Process.Error) -> Swift.String {
        if _isExplicit(command) {
            return command
        }

        guard let search = _value(named: "PATH", in: environment) else {
            throw .missing(command: command)
        }

        #if os(Windows)
            let directories = search.split(separator: ";", omittingEmptySubsequences: false)
        #else
            let directories = search.split(separator: ":", omittingEmptySubsequences: false)
        #endif

        let names = _names(for: command, environment: environment)
        for directorySlice in directories {
            let directory = directorySlice.isEmpty ? "." : Swift.String(directorySlice)
            for name in names {
                let candidate: Swift.String?
                do throws(Path.String.Conversion.Error) {
                    candidate = try Path.scope(directory, name) { directory, name in
                        let path = directory.appending(name)
                        guard _isExecutable(path) else {
                            return nil
                        }
                        return Swift.String(path)
                    }
                } catch {
                    switch error {
                    case .interiorNUL(index: 1):
                        throw .invalidPath(index: 0)
                    case .interiorNUL:
                        continue
                    }
                }

                if let candidate {
                    return candidate
                }
            }
        }

        throw .missing(command: command)
    }
}

extension Process.Executable {
    private static func _isExplicit(_ command: Swift.String) -> Bool {
        #if os(Windows)
            command.contains("/") || command.contains("\\") || command.contains(":")
        #else
            command.contains("/")
        #endif
    }

    private static func _names(
        for command: Swift.String,
        environment: [Swift.String: Swift.String]?
    ) -> [Swift.String] {
        #if os(Windows)
            let value = _value(named: "PATHEXT", in: environment) ?? ".COM;.EXE;.BAT;.CMD"
            let extensions = value.split(separator: ";", omittingEmptySubsequences: true).map {
                let value = Swift.String($0)
                return value.hasPrefix(".") ? value : "." + value
            }
            let normalized = command.lowercased()
            if extensions.contains(where: { normalized.hasSuffix($0.lowercased()) }) {
                return [command]
            }
            return [command] + extensions.map { command + $0 }
        #else
            [command]
        #endif
    }

    private static func _value(
        named requested: Swift.String,
        in environment: [Swift.String: Swift.String]?
    ) -> Swift.String? {
        if let environment {
            #if os(Windows)
                if let exact = environment[requested] {
                    return exact
                }
                let normalized = requested.lowercased()
                guard
                    let key = environment.keys.sorted().first(where: {
                        $0.lowercased() == normalized
                    })
                else {
                    return nil
                }
                return environment[key]
            #else
                return environment[requested]
            #endif
        }

        #if os(Windows)
            guard var entries = Kernel.Environment.entries() else {
                return nil
            }
        #else
            var entries = Kernel.Environment.entries()
        #endif

        while let entry = entries.next() {
            let name: Swift.String
            let value: Swift.String
            do throws(UTF8.ValidationError) {
                name = try Swift.String(entry.name)
                value = try Swift.String(entry.value)
            } catch {
                continue
            }

            #if os(Windows)
                if name.lowercased() == requested.lowercased() {
                    return value
                }
            #else
                if name == requested {
                    return value
                }
            #endif
        }
        return nil
    }

    #if os(Windows)
        private static func _isExecutable(_ path: borrowing Path) -> Bool {
            guard let attributes = Windows.`32`.Kernel.File.getAttributes(path: path) else {
                return false
            }
            return !attributes.contains(.directory)
        }
    #else
        private static func _isExecutable(_ path: borrowing Path) -> Bool {
            do throws(ISO_9945.Kernel.File.Stats.Error) {
                let stats = try ISO_9945.Kernel.File.Stats.get(path: path.view)
                return stats.type == .regular && (stats.permissions.rawValue & 0o111) != 0
            } catch {
                return false
            }
        }
    #endif
}

extension Process.Spawn {
    @usableFromInline
    internal static func _resolvingExecutable(
        in configuration: Configuration
    ) throws(Process.Error) -> Configuration {
        let executable = try Process.Executable.resolve(
            configuration.executable,
            environment: configuration.environment
        )
        return Configuration(
            executable: executable,
            arguments: configuration.arguments,
            environment: configuration.environment,
            stdin: configuration.stdin,
            stdout: configuration.stdout,
            stderr: configuration.stderr,
            workingDirectory: configuration.workingDirectory,
            timeout: configuration.timeout
        )
    }
}
