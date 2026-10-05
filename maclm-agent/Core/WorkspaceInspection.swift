import Foundation

/// Read metadata only; never invokes git or another process.
enum GitHeadReader {
    static func read(workingDirectory: String) -> String? {
        let root = URL(fileURLWithPath: workingDirectory)
        var git = root.appendingPathComponent(".git")
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git.path, isDirectory: &directory) else { return nil }
        if !directory.boolValue {
            guard let text = try? String(contentsOf: git, encoding: .utf8),
                  text.hasPrefix("gitdir:") else { return nil }
            let path = text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            git = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
        }
        guard let text = try? String(contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8)
        else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("ref: refs/heads/") {
            return String(value.dropFirst(16))
        }
        guard value.count >= 7, value.allSatisfy(\.isHexDigit) else { return nil }
        return String(value.prefix(7)) + " (detached)"
    }
}

struct WorkspaceFile: Identifiable, Sendable {
    let url: URL
    let isDirectory: Bool
    var id: String {
        url.path
    }
}

struct WorkspaceDirectoryPage: Sendable {
    let files: [WorkspaceFile]
    let remaining: Int
    static func read(_ url: URL) throws -> Self {
        let urls = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        let sorted = urls
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let files = try sorted.prefix(500).map { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return WorkspaceFile(url: url, isDirectory: values.isDirectory == true && values.isSymbolicLink != true)
        }
        return Self(files: files, remaining: max(0, urls.count - files.count))
    }
}
