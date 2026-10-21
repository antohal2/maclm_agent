import SwiftUI

enum SkillPalette {
    static func query(_ input: String) -> String? {
        guard let word = input.split(whereSeparator: \.isWhitespace).last,
              input.last?.isWhitespace == false, word.first == "@" else { return nil }
        return String(word.dropFirst())
    }
}

struct SkillComposerView: View {
    @Bindable var viewModel: ChatViewModel
    @State private var palette = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let skills = viewModel.currentRunner?.skills {
                SkillAttachmentList(skills: skills)
                ForEach(Array(skills.notices.enumerated()), id: \.offset) { notice in
                    HStack {
                        Text(notice.element).font(.caption).foregroundStyle(.orange)
                        Button(String(localized: "Закрыть")) { skills.notices.remove(at: notice.offset) }
                    }
                }
                Button(String(localized: "@ Навыки")) { palette.toggle() }
                    .buttonStyle(.plain).font(.caption)
                    .popover(isPresented: $palette) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "Подключить навык")).font(.headline)
                            let query = SkillPalette.query(viewModel.input) ?? ""
                            let entries = skills.available.filter {
                                $0.state == .enabled && (query.isEmpty || $0.id.localizedCaseInsensitiveContains(query))
                            }
                            if entries.isEmpty {
                                Text(String(localized: "Нет доступных навыков"))
                            }
                            ScrollView {
                                ForEach(entries) { skill in
                                    Button {
                                        Task {
                                            if await skills.selectFromPalette(skill.id) {
                                                if SkillPalette.query(viewModel.input) == query {
                                                    viewModel.input.removeLast(query.count + 1)
                                                }
                                                palette = false
                                            }
                                        }
                                    } label: {
                                        VStack(alignment: .leading) {
                                            Text(verbatim: skill.id)
                                            Text(verbatim: skill.catalogDescription).font(.caption)
                                                .foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain)
                                }
                            }.frame(maxHeight: 260)
                        }.padding().frame(width: 360)
                            .task { await refresh(skills) }
                    }
            }
        }
        .onChange(of: viewModel.input) { _, value in
            palette = SkillPalette.query(value) != nil
        }
        .task(id: viewModel.selectedConversationID) {
            guard let conversation = viewModel.selectedConversation else { return }
            if let skills = viewModel.registry.runner(for: conversation).skills {
                await refresh(skills)
            }
        }
    }

    private func refresh(_ skills: SessionSkills) async {
        do { try await skills.refreshCatalog() } catch { skills.notices.append(error.localizedDescription) }
    }
}

struct SkillAttachmentList: View {
    @Bindable var skills: SessionSkills
    var body: some View {
        ForEach(skills.attached) { skill in
            HStack(spacing: 6) {
                Text(verbatim: skill.id).font(.caption)
                Button { skills.detach(skill.id) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).help(String(localized: "Отключить навык"))
                    .accessibilityLabel(String(localized: "Отключить навык") + " " + skill.id)
            }.padding(5).background(.quaternary, in: Capsule())
        }
    }
}

struct SkillProposalCard: View {
    let proposal: SkillProposal
    @Bindable var skills: SessionSkills
    @State private var resolving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(String(localized: "Предложение навыка"), systemImage: "book")
            Text(verbatim: proposal.skill.id).font(.headline)
            Text(verbatim: proposal.skill.catalogDescription)
            Text(verbatim: proposal.reason).font(.caption)
            Text(String(localized: "Источник навыка:") + " " + proposal.skill.source).font(.caption)
            HStack {
                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(proposal.skill.size), countStyle: .file))
                Text(String(localized: "Токены:") + " " + String(proposal.tokenEstimate))
                Text(verbatim: String((proposal.skill.enabledHash ?? "").prefix(12))).monospaced()
            }.font(.caption)
            HStack {
                Button(String(localized: "Подключить")) { resolve(true) }
                Button(String(localized: "Не сейчас")) { resolve(false) }
            }.disabled(resolving)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func resolve(_ attach: Bool) {
        resolving = true
        Task { await skills.resolveProposal(id: proposal.id, attach: attach); resolving = false }
    }
}
