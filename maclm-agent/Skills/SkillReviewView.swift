import SwiftUI

struct SkillReviewView: View {
    let store: SkillStore
    let skillID: String
    let referenceHash: String?
    let confirm: (SkillReview) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var review: SkillReview?
    @State private var error: String?
    @State private var busy = false
    @State private var stale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Проверить изменения навыка")).font(.title2)
            Text(verbatim: skillID).font(.headline)
            ScrollView {
                if let review {
                    VStack(alignment: .leading, spacing: 12) {
                        if !review.hasSnapshot {
                            Text(String(localized:
                                "Снимок прежней версии отсутствует. Показаны текущие файлы и полный SKILL.md."
                            ))
                            .foregroundStyle(.orange)
                        }
                        ForEach(review.changes) { change in
                            HStack {
                                Text(change.kind.title).frame(width: 100, alignment: .leading)
                                Text(verbatim: change.path)
                                Spacer()
                                Text(verbatim: "\(size(change.oldSize)) → \(size(change.newSize))")
                            }.font(.caption)
                        }
                        Text(String(localized: "Предпросмотр SKILL.md")).font(.headline)
                        if let diff = review.diff {
                            DiffPreviewLines(lines: diff.lines)
                        } else {
                            Text(verbatim: review.current.text).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if let problem = review.current.problem {
                            Text(problem.localizedDescription).foregroundStyle(.red)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView()
                }
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Button(String(localized: "Пересканировать")) { Task { await load() } }
                Spacer()
                Button(String(localized: "Отмена"), role: .cancel) { dismiss() }
                Button(String(localized: "Подтвердить и включить")) { Task { await approve() } }
                    .disabled(busy || stale || review?.current.hash == nil || review?.current.problem != nil)
            }.disabled(busy)
        }.padding(24).frame(width: 760, height: 540)
            .task { await load() }
    }

    private func size(_ value: Int?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"
    }

    private func load() async {
        busy = true
        defer { busy = false }
        do {
            review = try await store.review(skillID, referenceHash: referenceHash)
            error = nil
            stale = false
        } catch { self.error = error.localizedDescription }
    }

    private func approve() async {
        guard let review else { return }
        busy = true
        defer { busy = false }
        do {
            try await confirm(review)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            stale = true
        }
    }
}

struct SkillChangedBanners: View {
    @Bindable var skills: SessionSkills
    @State private var reviewing: SkillAttachment?
    var body: some View {
        ForEach(skills.changedPins) { pin in
            HStack {
                Text(verbatim: pin.id).font(.caption.bold())
                Text(String(localized: "Навык изменён, нужно проверить")).font(.caption).foregroundStyle(.orange)
                Button(String(localized: "Проверить")) { reviewing = pin }
            }
        }
        .sheet(item: $reviewing) { pin in
            SkillReviewView(store: skills.store, skillID: pin.id, referenceHash: pin.hash) { review in
                try await skills.confirmReview(review, pin: pin)
            }
        }
    }
}
