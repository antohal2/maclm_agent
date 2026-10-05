import Foundation

actor AgentLoop {
    private let toolRegistry: ToolRegistry
    private let confirmationCoordinator: ConfirmationCoordinator
    nonisolated let sessionPermissions: SessionPermissions
    private var pendingConfirmations: [UUID: ConfirmationRequest] = [:]
    private var pendingContexts: [UUID: (ToolInvocationContext, Int)] = [:]
    private let riskContext: @MainActor @Sendable () -> ToolRiskContext
    private let securityRules: @MainActor @Sendable () throws -> [SecurityRuleSnapshot]
    private let auditSink: @MainActor @Sendable (AuditRecord) throws -> Void
    private let checkpoints: CheckpointService?
    private let checkpointSink: @MainActor @Sendable (CheckpointSnapshot) throws -> Void
    private let checkpointMaintenance: @MainActor @Sendable () async throws -> Void
    private let maximumIterations: Int
    private var isGenerating = false

    init(
        toolRegistry: ToolRegistry = .all,
        confirmationCoordinator: ConfirmationCoordinator = ConfirmationCoordinator(),
        maximumIterations: Int = 8,
        checkpoints: CheckpointService? = nil,
        checkpointSink: @escaping @MainActor @Sendable (CheckpointSnapshot) throws -> Void = { _ in },
        checkpointMaintenance: @escaping @MainActor @Sendable () async throws -> Void = {},
        sessionPermissions: SessionPermissions = SessionPermissions(),
        riskContext: @escaping @MainActor @Sendable () -> ToolRiskContext = {
            ToolRiskContext(allowedDirectories: AppSettings().allowedDirectories)
        },
        auditSink: @escaping @MainActor @Sendable (AuditRecord) throws -> Void = { _ in },
        securityRules: @escaping @MainActor @Sendable () throws -> [SecurityRuleSnapshot] = {
            DefaultSecurityRules.rules
        }
    ) {
        self.checkpoints = checkpoints
        self.checkpointSink = checkpointSink
        self.checkpointMaintenance = checkpointMaintenance
        self.auditSink = auditSink
        self.sessionPermissions = sessionPermissions
        self.riskContext = riskContext
        self.securityRules = securityRules
        self.toolRegistry = toolRegistry
        self.confirmationCoordinator = confirmationCoordinator
        self.maximumIterations = max(1, maximumIterations)
    }

    nonisolated func independentRun() -> AgentLoop {
        AgentLoop(
            toolRegistry: toolRegistry,
            maximumIterations: maximumIterations,
            checkpoints: checkpoints,
            checkpointSink: checkpointSink,
            checkpointMaintenance: checkpointMaintenance,
            sessionPermissions: sessionPermissions,
            riskContext: riskContext,
            auditSink: auditSink,
            securityRules: securityRules
        )
    }

    func resolveConfirmation(
        requestID: UUID,
        decision: ConfirmationDecision,
        rememberForSession: Bool = false
    ) async {
        if
            decision == .approved, rememberForSession,
            let request = pendingConfirmations[requestID],
            let (invocation, epoch) = pendingContexts[requestID] {
            await sessionPermissions.remember(
                conversationID: invocation.conversationID, toolName: request.toolCall.function.name,
                riskLevel: request.riskLevel, expectedEpoch: epoch
            )
        }
        await confirmationCoordinator.resolve(
            requestID: requestID,
            decision: decision
        )
    }

    func streamResponse(
        to messages: [ChatMessage],
        using provider: any LLMProvider,
        toolsEnabled: Bool = true,
        invocationContext: @escaping @MainActor @Sendable () -> ToolInvocationContext,
        onEvent: @escaping @Sendable (AgentLoopEvent) async -> Void
    ) async throws {
        guard !isGenerating else {
            throw AgentLoopError.alreadyGenerating
        }

        isGenerating = true
        defer { isGenerating = false }

        var history = messages

        for iteration in 0 ..< maximumIterations {
            if iteration > 0 {
                await onEvent(.assistantResponseStarted)
            }

            let turn = try await receiveTurn(
                history: history,
                provider: provider,
                toolsEnabled: toolsEnabled,
                onEvent: onEvent
            )
            guard !turn.toolCalls.isEmpty else {
                await onEvent(.done)
                return
            }

            history.append(
                ChatMessage(
                    role: .assistant,
                    content: turn.content,
                    toolCalls: turn.toolCalls
                )
            )

            var executions: [AgentToolCallExecution] = []
            for (index, toolCall) in turn.toolCalls.enumerated() {
                let execution: AgentToolCallExecution
                do {
                    execution = try await execute(toolCall, invocation: invocationContext(), onEvent: onEvent)
                } catch is CancellationError {
                    // The model may request several calls in one turn. Record the remaining
                    // calls too; cancellation prevents them from reaching any tool.
                    for pending in turn.toolCalls.dropFirst(index + 1) {
                        do {
                            _ = try await execute(pending, invocation: invocationContext(), onEvent: onEvent)
                        } catch is CancellationError {
                            continue
                        }
                    }
                    throw CancellationError()
                }
                executions.append(execution)
                history.append(
                    ChatMessage(
                        role: .tool,
                        content: execution.result.content,
                        toolCallID: toolCall.id
                    )
                )
            }
            await onEvent(.toolCallsCompleted(executions))

            if iteration == maximumIterations - 1 {
                await onEvent(.assistantResponseStarted)
                throw AgentLoopError.maximumIterationsReached(maximumIterations)
            }
        }
    }

    @MainActor
    private static func captureInvocation(
        _ source: @MainActor @Sendable () -> ToolInvocationContext,
        permissions: SessionPermissions
    ) -> ToolInvocationContext {
        let snapshot = source()
        return ToolInvocationContext(
            conversationID: snapshot.conversationID,
            project: snapshot.project,
            permissionEpoch: permissions.epoch(for: snapshot.conversationID)
        )
    }

    private func receiveTurn(
        history: [ChatMessage],
        provider: any LLMProvider,
        toolsEnabled: Bool,
        onEvent: @escaping @Sendable (AgentLoopEvent) async -> Void
    ) async throws -> AssistantTurn {
        var content = ""
        var toolCallAccumulators: [Int: ToolCallAccumulator] = [:]

        await onEvent(.contextRequestStarted)
        for try await event in provider.streamChat(
            messages: history,
            tools: toolsEnabled ? toolRegistry.definitions : []
        ) {
            switch event {
            case let .contentDelta(delta):
                content += delta
                await onEvent(.contentDelta(delta))
            case let .toolCallDelta(delta):
                toolCallAccumulators[delta.index, default: ToolCallAccumulator()]
                    .append(delta)
            case let .usage(prompt, completion):
                await onEvent(.usage(promptTokens: prompt, completionTokens: completion))
            case .done:
                break
            }
        }

        return AssistantTurn(
            content: content,
            toolCalls: (toolsEnabled ? toolCallAccumulators : [:])
                .sorted { $0.key < $1.key }
                .map(\.value.chatToolCall)
        )
    }
}

/// Execution keeps its policy checks in one actor, separate from streaming orchestration.
extension AgentLoop {
    private func execute(
        _ toolCall: ChatToolCall,
        invocation: ToolInvocationContext,
        onEvent: @escaping @Sendable (AgentLoopEvent) async -> Void
    ) async throws -> AgentToolCallExecution {
        let persistentCallID = UUID()
        var audit = AuditRecord(
            toolName: toolCall.function.name,
            argumentsJSON: AuditSanitizer.arguments(toolCall.function.arguments, toolName: toolCall.function.name),
            conversationID: invocation.conversationID,
            toolCallID: persistentCallID
        )
        let execution: Result<AgentToolCallExecution, Error>
        do {
            execution = try await .success(executeAudited(
                toolCall,
                invocation: invocation,
                audit: &audit,
                onEvent: onEvent
            ))
        } catch {
            if error is CancellationError {
                audit.outcome = .cancelled
                audit.errorDescription = "Cancelled by user"
            } else {
                audit.outcome = .failure
                audit.errorDescription = AuditSanitizer.truncate(error.localizedDescription)
            }
            execution = .failure(error)
        }
        try await auditSink(audit)
        var result = try execution.get()
        result.persistentCallID = persistentCallID
        return result
    }

    private func executeAudited(
        _ toolCall: ChatToolCall,
        invocation: ToolInvocationContext,
        audit: inout AuditRecord,
        onEvent: @escaping @Sendable (AgentLoopEvent) async -> Void
    ) async throws -> AgentToolCallExecution {
        audit.outcome = .failure
        guard let tool = toolRegistry.tool(named: toolCall.function.name) else {
            audit.errorDescription = "Unknown tool: \(toolCall.function.name)"
            return AgentToolCallExecution(
                toolCall: toolCall,
                result: .failure("Unknown tool: \(toolCall.function.name)")
            )
        }
        guard
            let data = toolCall.function.arguments.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let arguments = object as? [String: Any]
        else {
            audit.errorDescription = "Invalid JSON arguments"
            return AgentToolCallExecution(
                toolCall: toolCall,
                result: .failure(
                    "Invalid JSON arguments for \(tool.name): \(toolCall.function.arguments)"
                )
            )
        }

        var context = await riskContext()
        var assessment = ToolRiskEvaluator.evaluate(
            tool,
            arguments: arguments,
            context: context,
            invocation: invocation
        )
        audit.riskLevel = assessment.level
        audit.elevationReason = assessment.reason
        let policy: SecurityPolicyEngine
        do {
            policy = try await SecurityPolicyEngine(rules: securityRules(), invocation: invocation)
        } catch {
            audit.errorDescription = "Unable to load security rules: \(error.localizedDescription)"
            // A failed store read must never silently disable policy enforcement.
            return AgentToolCallExecution(
                toolCall: toolCall,
                result: .failure("Unable to load security rules: \(error.localizedDescription)")
            )
        }
        if invocation.workingDirectory != nil {
            context.projectPolicy = policy
        }
        let executionArguments = policy.executionArguments(for: tool, arguments: arguments)
        assessment = ToolRiskEvaluator.evaluate(
            tool,
            arguments: executionArguments,
            context: context,
            invocation: invocation
        )
        if invocation.workingDirectory != nil {
            let original = ToolRiskEvaluator.evaluate(
                tool,
                arguments: arguments,
                context: context,
                invocation: invocation
            )
            if original.level > assessment.level {
                assessment = original
            }
        }
        audit.riskLevel = assessment.level
        audit.elevationReason = assessment.reason
        try Task.checkCancellation()
        let policyDecision = policy.decision(for: tool, arguments: arguments)
        audit.matchedRuleDescription = policyDecision.explanation.map { AuditSanitizer.truncate($0) }
        guard policyDecision.isAllowed else {
            audit.decision = .blocked
            audit.outcome = .notExecuted
            audit.resultSummary = AuditSanitizer.truncate(policyDecision.explanation ?? "Blocked")
            return AgentToolCallExecution(
                toolCall: toolCall,
                result: .failure(policyDecision.explanation ?? "Вызов запрещён правилом безопасности.")
            )
        }
        return try await executeAllowed(
            .init(
                tool: tool,
                toolCall: toolCall,
                arguments: arguments,
                executionArguments: executionArguments,
                invocation: invocation,
                policy: policy,
                assessment: assessment
            ),
            audit: &audit, onEvent: onEvent
        )
    }

    private func executeAllowed(
        _ operation: EvaluatedToolOperation,
        audit: inout AuditRecord,
        onEvent: @escaping @Sendable (AgentLoopEvent) async -> Void
    ) async throws -> AgentToolCallExecution {
        let tool = operation.tool, toolCall = operation.toolCall
        let executionArguments = operation.executionArguments
        let invocation = operation.invocation, policy = operation.policy
        let assessment = operation.assessment
        var prepared: PreparedFileOperation?
        if let checkpoints, FilePreviewService.covered.contains(tool.name) {
            let strings = executionArguments.compactMapValues { $0 as? String }
            do {
                prepared = try await FilePreviewService.prepare(
                    tool: tool.name,
                    arguments: strings,
                    policy: policy,
                    checkpoints: checkpoints
                )
            } catch CheckpointError.unavailable {
                // Never promise rollback or execute against an unknown approved state.
                prepared = .init(
                    preview: .init(
                        kind: "unavailable",
                        paths: [],
                        rollbackReason: CheckpointError.unavailable.rawValue
                    ),
                    plan: .init(fingerprints: [], bytes: 0, reason: .unavailable)
                )
            } catch {
                audit.errorDescription = error.localizedDescription
                return AgentToolCallExecution(toolCall: toolCall, result: .failure(error.localizedDescription))
            }
        }
        let confirmation = try await confirmIfNeeded(
            toolCall: toolCall,
            assessment: assessment,
            invocation: invocation,
            callID: audit.toolCallID ?? UUID(),
            prepared: prepared,
            onEvent: onEvent
        )
        audit.decision = confirmation
            .requestID == nil ? .auto : (confirmation.decision == .approved ? .approved : .rejected)
        if let rejection = confirmation.rejection {
            audit.outcome = .notExecuted
            audit.resultSummary = "User rejected execution"
            return rejection
        }

        await onEvent(.toolExecutionStarted(toolName: tool.name))
        try Task.checkCancellation()
        let started = ContinuousClock.now
        defer {
            let elapsed = started.duration(to: .now).components
            audit.durationMilliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        }
        return try await executeCheckpointed(operation, prepared: prepared, confirmation: confirmation, audit: &audit)
    }

    private func executeCheckpointed(
        _ operation: EvaluatedToolOperation,
        prepared: PreparedFileOperation?,
        confirmation: ToolConfirmation,
        audit: inout AuditRecord
    ) async throws -> AgentToolCallExecution {
        let tool = operation.tool, toolCall = operation.toolCall
        let arguments = operation.arguments, executionArguments = operation.executionArguments
        let invocation = operation.invocation, policy = operation.policy
        var checkpoint: CheckpointSnapshot?
        var executionBegan = false
        do {
            if let checkpoints, let prepared {
                guard !prepared.plan.fingerprints.isEmpty else { throw CheckpointError.unavailable }
                let freshPolicy = try await SecurityPolicyEngine(rules: securityRules(), invocation: invocation)
                guard freshPolicy.decision(for: tool, arguments: arguments).isAllowed
                else { throw CheckpointError.blocked }
                try await checkpoints.verify(prepared.plan, policy: freshPolicy)
                if prepared.plan.canRestore {
                    let value = try await checkpoints.create(
                        tool: tool.name,
                        conversationID: invocation.conversationID,
                        expected: prepared.plan,
                        policy: freshPolicy
                    )
                    do { try await checkpointSink(value) }
                    catch { try? await checkpoints.discard(value.id); throw error }
                    checkpoint = value
                    audit.checkpointID = value.id
                }
                try Task.checkCancellation()
                // Detect changed symlink parents/targets, not only changed bytes.
                let currentPaths = try CheckpointFileState.paths(
                    tool: tool.name,
                    arguments: executionArguments.compactMapValues { $0 as? String }
                )
                guard currentPaths == prepared.plan.fingerprints.map(\.path) else { throw CheckpointError.changed }
                try await checkpoints.verify(prepared.plan, policy: freshPolicy)
            }
            // A fresh JSON object has no non-Sendable aliases to the actor's operation snapshot.
            let encodedArguments = try JSONSerialization.data(withJSONObject: executionArguments)
            let toolArguments = try JSONSerialization.jsonObject(with: encodedArguments) as? [String: Any] ?? [:]
            executionBegan = true
            let result = try await tool.execute(arguments: toolArguments, invocation: invocation, policy: policy)
            if let checkpoints, let checkpoint {
                do {
                    let completed = try await checkpoints.complete(checkpoint)
                    try await checkpointSink(completed)
                    try await checkpointMaintenance()
                } catch {
                    // The pre-operation snapshot is durable. Maintenance failure must not
                    // report that an already executed tool failed or change its model result.
                    NSLog("Checkpoint finalization failed: %@", error.localizedDescription)
                }
            }
            audit.outcome = result.isError ? .failure : .success
            let summary = AuditSanitizer.summary(result, toolName: tool.name, arguments: executionArguments)
            audit.resultSummary = summary.0
            audit.errorDescription = summary.1
            return AgentToolCallExecution(
                toolCall: toolCall,
                result: result,
                confirmationDecision: confirmation.decision,
                confirmationRequestID: confirmation.requestID
            )
        } catch is CancellationError {
            await cleanUpCheckpoint(checkpoint, executionBegan: executionBegan)
            if !executionBegan {
                audit.checkpointID = nil
            }
            throw CancellationError()
        } catch {
            await cleanUpCheckpoint(checkpoint, executionBegan: executionBegan)
            if !executionBegan {
                audit.checkpointID = nil
            }
            audit.outcome = .failure
            audit.errorDescription = AuditSanitizer.truncate(error.localizedDescription)
            return AgentToolCallExecution(
                toolCall: toolCall,
                result: .failure("Tool \(tool.name) failed: \(error.localizedDescription)"),
                confirmationDecision: confirmation.decision,
                confirmationRequestID: confirmation.requestID
            )
        }
    }

    private func cleanUpCheckpoint(_ checkpoint: CheckpointSnapshot?, executionBegan: Bool) async {
        guard let checkpoints, let checkpoint else { return }
        if executionBegan {
            _ = try? await checkpoints.complete(checkpoint)
        } else {
            try? await checkpoints.discard(checkpoint.id); try? await checkpointMaintenance()
        }
    }

    private func confirmIfNeeded(
        toolCall: ChatToolCall,
        assessment: RiskAssessment,
        invocation: ToolInvocationContext,
        callID: UUID,
        prepared: PreparedFileOperation?,
        onEvent: @escaping @Sendable (AgentLoopEvent) async -> Void
    ) async throws -> ToolConfirmation {
        guard assessment.level.requiresConfirmation else {
            return ToolConfirmation()
        }

        if
            prepared?.plan.canRestore != false, await sessionPermissions.allows(
                conversationID: invocation.conversationID,
                toolName: toolCall.function.name,
                riskLevel: assessment.level,
                expectedEpoch: invocation.permissionEpoch
            ) {
            return ToolConfirmation(decision: .approved)
        }

        let request = ConfirmationRequest(
            id: callID,
            toolCall: toolCall,
            riskLevel: assessment.level,
            riskReason: assessment.reason,
            filePreview: prepared?.preview
        )
        pendingConfirmations[request.id] = request
        pendingContexts[request.id] = (invocation, invocation.permissionEpoch)
        defer {
            pendingConfirmations.removeValue(forKey: request.id)
            pendingContexts.removeValue(forKey: request.id)
        }
        await onEvent(.confirmationRequested(request))
        let decision = try await confirmationCoordinator.waitForDecision(
            requestID: request.id
        )
        try Task.checkCancellation()
        guard decision == .approved else {
            return ToolConfirmation(
                decision: decision,
                requestID: request.id,
                rejection: AgentToolCallExecution(
                    toolCall: toolCall,
                    result: .failure(
                        "User rejected execution of tool '\(toolCall.function.name)'. "
                            + "Do not retry it without a new explicit request."
                    ),
                    confirmationDecision: decision,
                    confirmationRequestID: request.id
                )
            )
        }
        return ToolConfirmation(decision: decision, requestID: request.id)
    }
}

private struct EvaluatedToolOperation {
    let tool: any Tool
    let toolCall: ChatToolCall
    let arguments: [String: Any]
    let executionArguments: [String: Any]
    let invocation: ToolInvocationContext
    let policy: SecurityPolicyEngine
    let assessment: RiskAssessment
}
