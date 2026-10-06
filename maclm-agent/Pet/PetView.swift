import SwiftUI

struct PetView: View {
    let runtime: PetRuntime
    let sprite: PetSprite?
    @State private var epoch = Date()

    private var row: PetManifest.Row? {
        sprite?.row(for: runtime.state)
    }

    private var fps: Double {
        Double(row?.fps ?? (runtime.state == .idle || runtime.state == .sleep ? 3 : 10))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / fps, paused: runtime.paused || runtime.reduceMotion)) { context in
            let elapsed = runtime.reduceMotion ? 0 : max(0, context.date.timeIntervalSince(epoch))
            Group {
                if let sprite, let row, let frames = sprite.frames[row.state] {
                    let index = runtime.reduceMotion ? sprite.manifest.reduceMotionFrame
                        : row.loop ? Int(elapsed * fps) % frames.count : min(Int(elapsed * fps), frames.count - 1)
                    Image(decorative: frames[index], scale: 1)
                        .resizable().interpolation(.none)
                } else {
                    PetPlaceholder(state: runtime.state, elapsed: elapsed)
                }
            }
            .frame(width: 64, height: 64)
            .scaleEffect(CGFloat(runtime.scale), anchor: .topLeading)
        }
        .frame(width: CGFloat(64 * runtime.scale), height: CGFloat(64 * runtime.scale), alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(runtime.hideContent ? String(localized: "Питомец") : runtime.state.accessibilityTitle)
        .accessibilityValue(runtime.state.accessibilityTitle)
        .onChange(of: runtime.state) { epoch = Date() }
    }
}

struct PetPlaceholder: View {
    let state: PetState
    let elapsed: TimeInterval

    private var symbol: String {
        switch state {
        case .idle: "·"
        case .running: "↑"
        case .toolRunning: "⚙"
        case .needsApproval: "!"
        case .ready: "✓"
        case .failed: "×"
        case .drag: "↔"
        case .sleep: "z"
        }
    }

    private var color: Color {
        switch state {
        case .failed: .red
        case .needsApproval: .orange
        case .ready: .green
        case .running, .toolRunning: .cyan
        case .idle, .drag, .sleep: .gray
        }
    }

    var body: some View {
        Canvas { context, _ in
            let wave = sin(elapsed * (state == .idle ? 1.5 : 5))
            let bounce = state == .running ? abs(wave) * 4 : 0
            context.translateBy(x: 32, y: 34 - bounce)
            if state == .drag {
                context.rotate(by: .degrees(wave * 8))
            }
            if state == .idle {
                context.scaleBy(x: 1 + wave * 0.025, y: 1 + wave * 0.025)
            }
            let body = CGRect(x: -23, y: -19, width: 46, height: 40)
            context.fill(Path(ellipseIn: body), with: .color(.brown))
            context.stroke(Path(ellipseIn: body), with: .color(.black.opacity(0.8)), lineWidth: 2)
            for offset in [-11.0, 0, 11] {
                let plate = CGRect(x: offset - 4, y: -14, width: 8, height: 27)
                context.stroke(
                    Path(roundedRect: plate, cornerRadius: 4),
                    with: .color(.orange.opacity(0.8)), lineWidth: 2
                )
            }
            context.fill(Path(ellipseIn: CGRect(x: 13, y: -5, width: 17, height: 19)), with: .color(.brown))
            context.fill(Path(ellipseIn: CGRect(x: 23, y: -1, width: 3, height: 3)), with: .color(.black))
            context.fill(Path(ellipseIn: CGRect(x: -16, y: 15, width: 10, height: 6)), with: .color(.brown))
            context.fill(Path(ellipseIn: CGRect(x: 8, y: 15, width: 10, height: 6)), with: .color(.brown))
            context.fill(Path(ellipseIn: CGRect(x: -10, y: -29, width: 20, height: 20)), with: .color(color))
            var indicator = context
            indicator.translateBy(x: 0, y: -19)
            if state == .toolRunning {
                indicator.rotate(by: .radians(elapsed * 2))
            }
            indicator.draw(
                Text(verbatim: symbol).font(.system(size: 17, weight: .bold)).foregroundColor(.white),
                at: .zero
            )
        }
    }
}
