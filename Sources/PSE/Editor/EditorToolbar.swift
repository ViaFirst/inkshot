import SwiftUI

struct EditorToolbar: View {
    @ObservedObject var model: EditorModel
    var onCopy: () -> Void
    var onSave: () -> Void
    var onInteract: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Tool.allCases) { tool in
                    Button {
                        model.tool = tool
                        onInteract()
                    } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ChipStyle(selected: model.tool == tool))
                    .help("\(tool.title)  (\(tool.key))")
                }
            }

            Divider().frame(height: 22)

            HStack(spacing: 5) {
                ForEach(Palette.colors.indices, id: \.self) { i in
                    let c = Palette.colors[i]
                    Button {
                        model.color = c
                        onInteract()
                    } label: {
                        Circle()
                            .fill(Color(nsColor: c))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                            .frame(width: 16, height: 16)
                            .padding(3)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: model.color == c ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().frame(height: 22)

            HStack(spacing: 2) {
                ForEach(StrokeSize.allCases, id: \.self) { s in
                    Button {
                        model.size = s
                        onInteract()
                    } label: {
                        Circle()
                            .frame(width: 4 + s.rawValue * 3, height: 4 + s.rawValue * 3)
                            .frame(width: 26, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ChipStyle(selected: model.size == s))
                    .help(L("Stroke Size"))
                }
            }

            Spacer(minLength: 8)

            Button { model.undo(); onInteract() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless).disabled(!model.canUndo).help(L("Undo (⌘Z)"))
            Button { model.redo(); onInteract() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.borderless).disabled(!model.canRedo).help(L("Redo (⇧⌘Z)"))

            Button(L("Save"), action: onSave)
                .help(L("Save as PNG (⌘S)"))
            Button(L("Copy"), action: onCopy)
                .buttonStyle(.borderedProminent)
                .help(L("Copy and Close (↩ or ⌘C)"))
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(.bar)
    }
}

private struct ChipStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.15 : 0))
            )
    }
}
