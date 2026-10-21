import SwiftUI

struct SkillDraftContentView: View {
    let draft: SkillDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(draft.files) { file in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(verbatim: file.path).font(.headline)
                        Spacer()
                        Text(verbatim: ByteCountFormatter.string(
                            fromByteCount: Int64(file.data.count),
                            countStyle: .file
                        ))
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(file.warnings, id: \.self) { warning in
                        Label(warning.title, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if file.path == "SKILL.md" {
                        content(file.content)
                    } else {
                        DisclosureGroup(String(localized: "Полное содержимое файла")) {
                            content(file.content)
                        }
                    }
                }
            }
        }
    }

    private func content(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption.monospaced()).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}
