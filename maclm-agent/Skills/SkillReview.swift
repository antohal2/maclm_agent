import Foundation

struct SkillFileChange: Identifiable, Sendable {
    enum Kind: Sendable {
        case added, removed, changed, current
        var title: String {
            switch self {
            case .added: String(localized: "Добавлен")
            case .removed: String(localized: "Удалён")
            case .changed: String(localized: "Изменён")
            case .current: String(localized: "Текущий файл")
            }
        }
    }

    let path: String
    let kind: Kind
    let oldSize: Int?
    let newSize: Int?
    var id: String {
        path
    }
}

struct SkillReview: Identifiable, Sendable {
    let current: SkillSnapshot
    let referenceHash: String?
    let changes: [SkillFileChange]
    let diff: UnifiedDiff?
    var id: String {
        current.id
    }

    var hasSnapshot: Bool {
        diff != nil
    }

    static func make(
        current: SkillSnapshot, referenceHash: String?, files: [SkillFile]?, text: String?
    ) throws -> Self {
        let old = Dictionary(uniqueKeysWithValues: (files ?? []).map { ($0.path, $0) })
        let new = Dictionary(uniqueKeysWithValues: current.files.map { ($0.path, $0) })
        let changes = Set(old.keys).union(new.keys).sorted().compactMap { path -> SkillFileChange? in
            let before = old[path], after = new[path]
            if files == nil {
                return .init(path: path, kind: .current, oldSize: nil, newSize: after?.size)
            }
            if before == after {
                return nil
            }
            return .init(
                path: path,
                kind: before == nil ? .added : after == nil ? .removed : .changed,
                oldSize: before?.size,
                newSize: after?.size
            )
        }
        return try Self(
            current: current,
            referenceHash: referenceHash,
            changes: changes,
            diff: text.map { try FilePreviewService.unifiedDiff(old: $0, new: current.text) }
        )
    }
}
