import Darwin
import Foundation

enum PathCanonicalizer {
    /// Resolve components in order: a symlink followed by '..' uses its target's parent.
    /// Resolve existing ancestors even when the final file does not exist yet.
    static func canonicalize(_ path: String) -> String {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .expandingTildeInPath
        var current = URL(
            fileURLWithPath: expanded.hasPrefix("/")
                ? "/" : FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        for component in expanded.split(separator: "/") {
            if component == "." {
                continue
            }
            if component == ".." {
                current.deleteLastPathComponent(); continue
            }
            current.appendPathComponent(String(component))
            if let resolved = current.path.withCString({ realpath($0, nil) }) {
                defer { free(resolved) }
                current = URL(fileURLWithPath: String(cString: resolved))
            }
        }
        // standardizedFileURL also rewrites /private/etc back to /etc on macOS.
        // Components are already normalized; preserve the POSIX canonical path.
        return current.path
    }

    static func isCaseSensitive(_ path: String) -> Bool {
        var existing = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            existing.deleteLastPathComponent()
        }
        // Unknown/offline volumes use conservative case-insensitive matching.
        return (try? existing.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
    }

    static func canonicalizePattern(_ pattern: String) -> String {
        guard let wildcard = pattern.firstIndex(where: { "*?".contains($0) }) else {
            return canonicalize(pattern)
        }
        let prefix = pattern[..<wildcard]
        guard let separator = prefix.lastIndex(of: "/") else { return pattern }
        let literalRoot = String(pattern[..<separator])
        let suffix = String(pattern[pattern.index(after: separator)...])
        let root = canonicalize(literalRoot.isEmpty ? "/" : literalRoot)
        return (root == "/" ? root : root + "/") + suffix
    }
}

/// Pure glob matcher: '*' and '?' stay within a component; '**' crosses '/'.
/// '**/' also matches zero directories. No regex syntax is interpreted.
enum PathGlob {
    static func matches(_ path: String, pattern: String) -> Bool {
        let value = Array(path)
        let glob = Array(pattern)
        struct Position: Hashable { let value: Int; let glob: Int }
        var memo: [Position: Bool] = [:]
        // Preserve the existing recursive path-matching algorithm.
        // swiftlint:disable:next identifier_name
        func match(_ i: Int, _ j: Int) -> Bool {
            let position = Position(value: i, glob: j)
            if let cached = memo[position] {
                return cached
            }
            let result: Bool
            if j == glob.count {
                result = i == value.count
            } else if glob[j] == "*" {
                let recursive = j + 1 < glob.count && glob[j + 1] == "*"
                let next = j + (recursive ? 2 : 1)
                result = match(i, next)
                    || (recursive && next < glob.count && glob[next] == "/" && match(i, next + 1))
                    || (i < value.count && (recursive || value[i] != "/") && match(i + 1, j))
            } else if i < value.count {
                result = (glob[j] == value[i] || (glob[j] == "?" && value[i] != "/"))
                    && match(i + 1, j + 1)
            } else {
                result = false
            }
            memo[position] = result
            return result
        }
        if pattern.hasSuffix("/**"), path == String(pattern.dropLast(3)) {
            return true
        }
        return match(0, 0)
    }
}
