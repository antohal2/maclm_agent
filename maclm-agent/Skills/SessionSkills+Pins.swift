import Foundation
import SwiftData

extension SessionSkills {
    var project: Project? {
        conversation.project
    }

    func isPinned(_ id: String) -> Bool {
        project?.pinnedSkills.contains { $0.id == id } == true
    }

    func pin(_ id: String) async throws {
        guard let project, let skill = attached.first(where: { $0.id == id }) else {
            throw SkillValidationError.unavailable
        }
        try await store.snapshotForPin(skill.reference)
        guard conversation.project?.id == project.id,
              attached.contains(where: { $0.reference == skill.reference })
        else {
            throw SkillValidationError.changedSincePreview
        }
        var pins = project.pinnedSkills
        if let index = pins.firstIndex(where: { $0.id == id }) {
            pins[index] = skill.reference
        } else {
            pins.append(skill.reference)
        }
        try savePins(pins, project: project, event: "skill.pin", reference: skill.reference)
        try await store.cleanupSnapshots()
    }

    func unpin(_ id: String) async throws {
        guard let project else { return }
        try SkillProjectActions.unpin(id, project: project, context: context)
        changedPins.removeAll { $0.id == id }
        try await store.cleanupSnapshots()
    }

    func confirmReview(_ review: SkillReview, pin: SkillAttachment) async throws {
        guard let project, project.pinnedSkills.contains(pin), review.current.id == pin.id,
              review.referenceHash == pin.hash, let hash = review.current.hash
        else {
            throw SkillValidationError.changedSincePreview
        }
        _ = try await store.reconfirm(pin.id, expectedHash: hash, referenceHash: pin.hash, projectID: project.id)
        guard conversation.project?.id == project.id, project.pinnedSkills.contains(pin) else {
            throw SkillValidationError.changedSincePreview
        }
        let reference = SkillAttachment(id: pin.id, hash: hash, source: review.current.source)
        let pins = project.pinnedSkills.map { $0.id == pin.id ? reference : $0 }
        try savePins(pins, project: project, event: "skill.pin", reference: reference)
        changedPins.removeAll { $0.id == pin.id }
        // An explicit Review confirmation can reattach a skill previously detached by the user.
        _ = try await attach(pin.id, expectedHash: hash)
        available = try await store.rescan()
        try await store.cleanupSnapshots()
    }

    func autoAttachPins() async throws {
        guard let project else { changedPins = []; return }
        let projectID = project.id
        var changed: [SkillAttachment] = []
        for pin in project.pinnedSkills {
            guard conversation.project?.id == projectID else { return }
            let current = available.first { $0.id == pin.id }
            if current?.hash != pin.hash {
                changed.append(pin)
                let key = "\(projectID):\(pin.id):\(pin.hash):\(current?.hash ?? "missing")"
                if !reportedPinMismatches.contains(key) {
                    try log("skill.hashMismatch", reference: pin, reason: current?.hash ?? "missing")
                    try context.save()
                    reportedPinMismatches.insert(key)
                }
                continue
            }
            guard current?.state == .enabled, !detachedPins.contains(pin.id),
                  !attached.contains(where: { $0.id == pin.id }) else { continue }
            do {
                _ = try await attachVerified(pin.id, expectedHash: pin.hash, automaticPin: pin)
            } catch let error as SkillAttachError {
                let notice = pin.id + ": " + error.localizedDescription
                if !notices.contains(notice) {
                    notices.append(notice)
                }
            } catch {
                // A change between the scan and the attachment gate is also surfaced as a review banner.
                available = try await store.rescan()
                if available.first(where: { $0.id == pin.id })?.hash != pin.hash {
                    changed.append(pin)
                    try log("skill.hashMismatch", reference: pin, reason: "changedDuringAttach")
                    try context.save()
                } else {
                    throw error
                }
            }
        }
        changedPins = changed
    }

    /// The first actual prompt freezes catalog order durably; UI previews never freeze it.
    func stableCatalog() -> String {
        do {
            var order: [String]
            if let data = conversation.skillCatalogOrderData {
                order = try JSONDecoder().decode([String].self, from: data)
                let new = available.filter { $0.state == .enabled && !order.contains($0.id) }.map(\.id).sorted()
                order.append(contentsOf: new)
            } else {
                order = SkillCatalogBuilder.orderedIDs(available, pinned: Set(project?.pinnedSkills.map(\.id) ?? []))
            }
            let data = try JSONEncoder().encode(order)
            if conversation.skillCatalogOrderData != data {
                conversation.skillCatalogOrderData = data
                try context.save()
            }
            return SkillCatalogBuilder.build(available, contextWindow: contextWindow(), stableOrder: order)
        } catch {
            context.rollback()
            return ""
        }
    }

    private func savePins(
        _ pins: [SkillAttachment], project: Project, event: String, reference: SkillAttachment
    ) throws {
        do {
            project.pinnedSkillsData = try JSONEncoder().encode(pins)
            try log(event, reference: reference)
            try context.save()
        } catch { context.rollback(); throw error }
    }
}

@MainActor enum SkillProjectActions {
    static func unpin(_ id: String, project: Project, context: ModelContext) throws {
        guard let reference = project.pinnedSkills.first(where: { $0.id == id }) else { return }
        do {
            project.pinnedSkillsData = try JSONEncoder().encode(project.pinnedSkills.filter { $0.id != id })
            let data = try JSONEncoder().encode([
                "skill": id, "hash": reference.hash, "source": reference.source, "projectID": project.id.uuidString,
            ])
            guard let json = String(data: data, encoding: .utf8) else { throw SkillValidationError.unreadable }
            context.insert(AuditEntry(.init(
                toolName: "skill.unpin",
                argumentsJSON: json,
                riskLevel: .safe,
                decision: .userInitiated,
                outcome: .success
            )))
            try context.save()
        } catch { context.rollback(); throw error }
    }
}
