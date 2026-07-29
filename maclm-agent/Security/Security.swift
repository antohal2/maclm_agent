import Foundation

enum ConfirmationDecision: String, Equatable, Sendable {
    case approved
    case rejected
}

struct ConfirmationRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let toolCall: ChatToolCall
    let riskLevel: RiskLevel

    init(
        id: UUID = UUID(),
        toolCall: ChatToolCall,
        riskLevel: RiskLevel
    ) {
        self.id = id
        self.toolCall = toolCall
        self.riskLevel = riskLevel
    }
}

actor ConfirmationCoordinator {
    private var continuations: [
        UUID: CheckedContinuation<ConfirmationDecision, any Error>
    ] = [:]
    private var earlyDecisions: [UUID: ConfirmationDecision] = [:]

    func waitForDecision(
        requestID: UUID
    ) async throws -> ConfirmationDecision {
        if let decision = earlyDecisions.removeValue(forKey: requestID) {
            return decision
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[requestID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancel(requestID: requestID)
            }
        }
    }

    func resolve(
        requestID: UUID,
        decision: ConfirmationDecision
    ) {
        if let continuation = continuations.removeValue(forKey: requestID) {
            continuation.resume(returning: decision)
        } else {
            earlyDecisions[requestID] = decision
        }
    }

    private func cancel(requestID: UUID) {
        earlyDecisions.removeValue(forKey: requestID)
        continuations.removeValue(forKey: requestID)?
            .resume(throwing: CancellationError())
    }
}
