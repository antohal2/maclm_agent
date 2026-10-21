import Foundation
import Observation
import SwiftData

struct SkillProposal: Identifiable, Sendable {
    let id = UUID()
    let skill: SkillSnapshot
    let reason: String
    var tokenEstimate: Int {
        let reference = SkillAttachment(id: skill.id, hash: skill.enabledHash ?? "", source: skill.source)
        return SkillCatalogBuilder.tokens(AttachedSkill(reference: reference, body: skill.body).rendered)
    }
}

/// Session content only. SecurityPolicyEngine and ToolRiskEvaluator receive no reference to this object.
@MainActor @Observable
final class SessionSkills {
    let store: SkillStore
    let conversation: Conversation
    let context: ModelContext
    var contextWindow: () -> Int? = { nil }
    private(set) var attached: [AttachedSkill] = []
    var available: [SkillSnapshot] = []
    private(set) var pending: SkillProposal?
    var notices: [String] = []
    var onPendingChanged: ((Bool) -> Void)?
    private var declined: Set<String> = []
    private var continuation: CheckedContinuation<String, Never>?
    private var preparation: Task<Void, Error>?
    private var attaching = false
    private(set) var detachedPins: Set<String> = []
    var changedPins: [SkillAttachment] = []
    var reportedPinMismatches: Set<String> = []
    private var resolvingProposal: UUID?

    init(store: SkillStore, conversation: Conversation, context: ModelContext) {
        self.store = store
        self.conversation = conversation
        self.context = context
    }

    var prompt: String {
        ([stableCatalog()]
            + attached.map(\.rendered)).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    func updateCatalogMetadata() async {
        available = await store.catalogSnapshots()
    }

    func prepare() async throws {
        if let preparation {
            try await preparation.value; return
        }
        let task = Task { try await restore() }
        preparation = task
        do { try await task.value } catch { preparation = nil; throw error }
    }

    func refreshCatalog() async throws {
        try await prepare()
        available = try await store.rescan()
        for skill in attached {
            let current = available.first { $0.id == skill.id }
            guard current?.state != .enabled || current?.enabledHash != skill.reference.hash else { continue }
            let reason = current?.state == .disabled ? "disabled" : "relaunchMismatch"
            try persist(
                attached.filter { $0.id != skill.id }.map(\.reference),
                event: "skill.detached",
                reference: skill.reference,
                reason: reason
            )
            attached.removeAll { $0.id == skill.id }
            notices.append(skill.id + ": " + String(localized: "Навык отключён после проверки сессии."))
        }
        try checkBudget(attached)
        try await autoAttachPins()
    }

    private func restore() async throws {
        detachedPins = try Set(JSONDecoder().decode(
            [String].self, from: conversation.detachedPinnedSkillsData ?? Data("[]".utf8)
        ))
        declined = try Set(JSONDecoder().decode(
            [String].self,
            from: conversation.declinedSkillsData ?? Data("[]".utf8)
        ))
        let references = try JSONDecoder().decode(
            [SkillAttachment].self, from: conversation.attachedSkillsData ?? Data("[]".utf8)
        )
        var retained = references
        var restored: [AttachedSkill] = []
        for reference in references {
            do {
                let skill = try await store.verifiedAttachment(reference.id, expectedHash: reference.hash)
                try checkBudget(restored + [skill])
                restored.append(skill)
            } catch {
                let disabled = try await store.state(of: reference.id) == .disabled
                let reason = disabled ? "disabled" : "relaunchMismatch"
                retained.removeAll { $0.id == reference.id }
                try persist(retained, event: "skill.detached", reference: reference, reason: reason)
                notices.append(reference.id + ": " + String(localized: "Навык отключён после проверки сессии."))
            }
        }
        attached = restored
        available = try await store.rescan()
        try await autoAttachPins()
    }

    @discardableResult
    func attach(_ id: String, expectedHash: String? = nil) async throws -> String {
        try await prepare()
        return try await attachVerified(id, expectedHash: expectedHash)
    }

    func attachVerified(
        _ id: String, expectedHash: String? = nil, automaticPin: SkillAttachment? = nil
    ) async throws -> String {
        guard !attaching else { throw SkillAttachError.busy }
        if attached.contains(where: { $0.id == id }) {
            return "attached"
        }
        attaching = true
        defer { attaching = false }
        let skill = try await store.verifiedAttachment(id, expectedHash: expectedHash)
        try Task.checkCancellation()
        try checkBudget(attached + [skill])
        try await store.noteUsed(id, expectedHash: skill.reference.hash)
        try checkBudget(attached + [skill])
        try Task.checkCancellation()
        if let automaticPin {
            guard conversation.project?.pinnedSkills.contains(automaticPin) == true,
                  !detachedPins.contains(id) else { throw SkillValidationError.changedSincePreview }
        } else {
            let next = detachedPins.subtracting([id])
            conversation.detachedPinnedSkillsData = try JSONEncoder().encode(next.sorted())
        }
        try persist(
            (attached + [skill]).map(\.reference),
            event: automaticPin == nil ? "skill.attached" : "skill.autoAttached",
            reference: skill.reference
        )
        if automaticPin == nil {
            detachedPins.remove(id)
        }
        attached.append(skill)
        if let index = available.firstIndex(where: { $0.id == id }) {
            available[index].lastUsedAt = Date()
        }
        return "attached"
    }

    func detach(_ id: String) {
        guard let skill = attached.first(where: { $0.id == id }) else { return }
        do {
            let next = detachedPins.union([id])
            conversation.detachedPinnedSkillsData = try JSONEncoder().encode(next.sorted())
            try persist(
                attached.filter { $0.id != id }.map(\.reference),
                event: "skill.detached",
                reference: skill.reference,
                reason: "user"
            )
            attached.removeAll { $0.id == id }
            detachedPins.insert(id)
        } catch { notices.append(error.localizedDescription) }
    }

    func fileRequest(_ request: SkillFileRequest) async -> ToolExecutionResult {
        let reference = attached.first { $0.id == request.skill }?.reference
        return await store.fileRequest(request, attachment: reference, conversationID: conversation.id)
    }

    func selectFromPalette(_ id: String) async -> Bool {
        do { _ = try await attach(id); return true } catch { notices.append(error.localizedDescription); return false }
    }

    func suggest(name: String, reason: String) async throws -> String {
        try await prepare()
        if declined.contains(name) {
            return "declined"
        }
        guard pending == nil else { return "unavailable: another proposal is pending" }
        available = try await store.rescan()
        if declined.contains(name) {
            return "declined"
        }
        guard let skill = available.first(where: { $0.id == name && $0.state == .enabled }),
              let hash = skill.enabledHash else { return "unavailable: skill is not enabled" }
        guard pending == nil else { return "unavailable: another proposal is pending" }
        if attached.contains(where: { $0.id == name }) {
            return "attached"
        }
        let proposal = SkillProposal(skill: skill, reason: String(reason.prefix(1000)))
        try log("skill.proposed", reference: .init(id: name, hash: hash, source: skill.source))
        try context.save()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: "unavailable: cancelled"); return }
                self.continuation = continuation
                pending = proposal
                onPendingChanged?(true)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelProposal(id: proposal.id) }
        }
    }

    func resolveProposal(id: UUID, attach: Bool, source: ApprovalSource = .feed) async {
        guard source == .feed, resolvingProposal == nil, let proposal = pending, proposal.id == id else { return }
        resolvingProposal = id
        defer { resolvingProposal = nil }
        if attach {
            do {
                let result = try await self.attach(proposal.skill.id, expectedHash: proposal.skill.enabledHash)
                finishProposal(id: id, result: result)
            } catch {
                notices.append(error.localizedDescription)
                finishProposal(id: id, result: "unavailable: \(modelReason(error))")
            }
        } else {
            do {
                let next = declined.union([proposal.skill.id])
                conversation.declinedSkillsData = try JSONEncoder().encode(next.sorted())
                try log("skill.declined", reference: .init(
                    id: proposal.skill.id, hash: proposal.skill.enabledHash ?? "", source: proposal.skill.source
                ))
                try context.save()
                declined = next
                finishProposal(id: id, result: "declined")
            } catch {
                context.rollback()
                finishProposal(id: id, result: "unavailable: audit persistence failed")
                notices.append(error.localizedDescription)
            }
        }
    }

    func cancelProposal(id: UUID? = nil) {
        guard let pending, id == nil || pending.id == id else { return }
        finishProposal(id: pending.id, result: "unavailable: cancelled")
    }

    private func finishProposal(id: UUID, result: String) {
        guard pending?.id == id else { return }
        let waiting = continuation
        continuation = nil
        pending = nil
        onPendingChanged?(false)
        waiting?.resume(returning: result)
    }

    private func checkBudget(_ skills: [AttachedSkill]) throws {
        guard skills.count <= 3 else { throw SkillAttachError.countLimit }
        guard SkillCatalogBuilder.tokens(skills.map(\.rendered).joined(separator: "\n\n"))
            <= SkillCatalogBuilder.window(contextWindow()) / 4 else { throw SkillAttachError.tokenLimit }
    }

    private func modelReason(_ error: Error) -> String {
        switch error {
        case SkillAttachError.countLimit: "three skill limit"
        case SkillAttachError.tokenLimit: "context budget exceeded"
        case is CancellationError: "cancelled"
        default: "skill verification or persistence failed"
        }
    }

    private func persist(
        _ references: [SkillAttachment], event: String, reference: SkillAttachment, reason: String? = nil
    ) throws {
        do {
            conversation.attachedSkillsData = try JSONEncoder().encode(references)
            try log(event, reference: reference, reason: reason)
            try context.save()
        } catch { context.rollback(); throw error }
    }

    func log(_ event: String, reference: SkillAttachment, reason: String? = nil) throws {
        var arguments = ["skill": reference.id, "source": reference.source, "hash": reference.hash]
        if let reason {
            arguments["reason"] = reason
        }
        if let project = conversation.project {
            arguments["projectID"] = project.id.uuidString
        }
        let data = try JSONEncoder().encode(arguments)
        guard let json = String(data: data, encoding: .utf8) else { throw SkillValidationError.unreadable }
        let automatic = ["skill.proposed", "skill.autoAttached", "skill.hashMismatch"].contains(event)
            || reason == "relaunchMismatch" || reason == "disabled"
        context.insert(AuditEntry(.init(
            toolName: event, argumentsJSON: json, riskLevel: .safe,
            decision: automatic ? .auto : .userInitiated,
            outcome: .success, resultSummary: event, conversationID: conversation.id
        )))
    }
}
