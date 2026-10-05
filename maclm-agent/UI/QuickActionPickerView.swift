import AppKit
import SwiftUI

struct QuickActionPickerView: View {
    @Bindable var model: QuickActionPickerModel
    let onSelect: (ClipboardAction) -> Void
    let onCancel: () -> Void
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack {
            HUDWindowMaterial()

            VStack(alignment: .leading, spacing: 10) {
                if model.isClipboardEmpty {
                    emptyClipboardView
                } else {
                    clipboardHeader
                    searchField
                    actionList
                }
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .task(id: model.presentationID) {
            await Task.yield()
            isSearchFocused = true
        }
    }

    private var clipboardHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(.secondary)
            Text(model.clipboardPreview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Текст из буфера: \(model.clipboardPreview)")
    }

    private var searchField: some View {
        TextField(String(localized: "Найти действие"), text: $model.query)
            .textFieldStyle(.roundedBorder)
            .focused($isSearchFocused)
            .accessibilityLabel(String(localized: "Поиск действий"))
    }

    @ViewBuilder
    private var actionList: some View {
        if model.filteredActions.isEmpty {
            ContentUnavailableView(
                String(localized: "Действия не найдены"),
                systemImage: "magnifyingglass",
                description: Text(String(localized: "Измените поисковый запрос"))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(model.filteredActions.enumerated()), id: \.element.id) { index, action in
                            actionRow(action, number: index + 1)
                                .id(action.id)
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: model.selectedAction?.id) { _, selectedID in
                    guard let selectedID else {
                        return
                    }
                    withAnimation(.easeOut(duration: 0.08)) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
            }
        }
    }

    private var emptyClipboardView: some View {
        VStack(spacing: 10) {
            Image(systemName: "clipboard")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(String(localized: "Буфер обмена пуст"))
                .font(.headline)
            Text(String(localized: "Скопируйте текст и снова вызовите быстрый пикер"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(String(localized: "Закрыть"), action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func actionRow(_ action: ClipboardAction, number: Int) -> some View {
        Button {
            onSelect(action)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: action.iconSystemName)
                    .frame(width: 22)
                    .foregroundStyle(.secondary)
                Text(action.interfaceName)
                    .lineLimit(1)
                Spacer()
                if number <= 9 {
                    Text(String(number))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 18)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 42)
            .background(
                model.selectedAction?.id == action.id
                    ? Color.accentColor.opacity(0.2)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering {
                model.select(action: action)
            }
        }
    }
}

private struct HUDWindowMaterial: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_: NSVisualEffectView, context _: Context) {}
}
