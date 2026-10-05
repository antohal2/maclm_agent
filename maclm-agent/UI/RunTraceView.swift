import SwiftData
import SwiftUI

struct RunTraceView: View {
    let turn: TraceTurn
    @Bindable var viewModel: ChatViewModel
    @State private var incidents = TraceIncidents()
    @Query private var audits: [AuditEntry]

    init(turn: TraceTurn, viewModel: ChatViewModel) {
        self.turn = turn
        self.viewModel = viewModel
        let id = viewModel.selectedConversationID
        let start = turn.user.timestamp
        let end = viewModel.messages.first { $0.role == .user && $0.timestamp > start }?.timestamp ?? .distantFuture
        _audits = Query(filter: #Predicate<AuditEntry> {
            $0.conversationID == id && $0.timestamp >= start && $0.timestamp < end
        }, sort: \.timestamp)
    }

    private var active: Bool {
        viewModel.isGenerating && viewModel.messages.last(where: { $0.role == .user })?.id == turn.id
    }

    private var expanded: Bool {
        viewModel.expandedTraceIDs.contains(turn.id)
    }

    var body: some View {
        if !turn.steps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if active {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        header(now: context.date)
                    }
                } else {
                    header(now: Date())
                }
                // Deliberately a sibling of the expandable content, never inside it.
                ForEach(turn.pendingCalls) { call in
                    ConfirmationCard(toolCall: call) { decision, remember in
                        viewModel.resolveConfirmation(
                            toolCallID: call.id,
                            decision: decision,
                            rememberForSession: remember
                        )
                    }
                }
                if expanded {
                    ForEach(turn.expandedSteps(isExpanded: expanded)) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            if !message.content.isEmpty {
                                Text(message.content).textSelection(.enabled)
                            }
                            ForEach(message.toolCalls.sorted { $0.timestamp < $1.timestamp }) { call in
                                if call.status != .pending {
                                    ToolCallCard(toolCall: call, rawResult: rawResult(for: call))
                                }
                            }
                        }
                    }
                }
            }
            .onChange(of: turn.calls.map(TraceCallRevision.init), initial: true) {
                incidents = TraceIncidents.count(calls: turn.calls, audits: audits)
            }
            .onChange(of: auditSignature) {
                incidents = TraceIncidents.count(calls: turn.calls, audits: audits)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var auditSignature: [String] {
        audits.map { $0.id.uuidString + $0.decisionRaw + $0.outcome.rawValue }
    }

    private func rawResult(for call: ToolCall) -> String? {
        guard call.toolName == "run_shell" else { return nil }
        return viewModel.messages.first {
            $0.role == .tool && $0.toolCallID == call.providerCallID && $0.timestamp > call.timestamp
        }?.content
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 8) {
            Button {
                if expanded {
                    viewModel.expandedTraceIDs.remove(turn.id)
                } else {
                    viewModel.expandedTraceIDs.insert(turn.id)
                }
            } label: {
                HStack {
                    Text(title(now: now))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                }
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? String(localized: "Развёрнуто") : String(localized: "Свёрнуто"))
            Spacer(minLength: 0)
            counter(incidents.rejected, icon: "xmark.shield", title: String(localized: "Отклонено"))
            counter(incidents.blocked, icon: "hand.raised.fill", title: String(localized: "Заблокировано правилом"))
            counter(
                incidents.dangerous,
                icon: "exclamationmark.shield.fill",
                title: String(localized: "Одобрено dangerous")
            )
            counter(incidents.errors, icon: "exclamationmark.triangle", title: String(localized: "Ошибка инструмента"))
        }.font(.caption)
    }

    @ViewBuilder private func counter(_ count: Int, icon: String, title: String) -> some View {
        if count > 0 {
            Label("\(count)", systemImage: icon)
                .help(title).accessibilityLabel("\(title): \(count)")
        }
    }

    private func title(now: Date) -> String {
        let end = active ? now : (turn.final?.timestamp
            ?? turn.end?.timestamp
            ?? audits.last?.timestamp ?? turn.steps.last?.timestamp ?? turn.user.timestamp)
        let elapsed = max(0, end.timeIntervalSince(turn.user.timestamp))
        let duration = Duration.seconds(elapsed).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
        if active {
            let step: String = switch viewModel.currentRunner?.status {
            case .needsApproval: String(localized: "Ждёт подтверждения")
            case let .toolRunning(name): name
            default: String(localized: "Генерация")
            }
            return String(localized: "Работает: \(duration) · \(step)")
        }
        if turn.final != nil {
            return String(localized: "Работа: \(duration) · \(turn.stepCount) шагов")
        }
        if turn.end?.failed == true || turn.steps.contains(where: { $0.content.hasPrefix("Ошибка:") }) {
            return String(localized: "Ошибка: \(duration) · \(turn.stepCount) шагов")
        }
        return String(localized: "Остановлено: \(duration) · \(turn.stepCount) шагов")
    }
}
