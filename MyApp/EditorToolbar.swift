import SwiftUI

/// Formatting toolbar shown above the note editor.
struct EditorToolbar: View {
    let controller: RichTextController

    var body: some View {
        HStack(spacing: 6) {
            Button(action: controller.toggleBold) {
                Image(systemName: "bold")
            }
            .help("Pogrubienie (⌘B)")

            Button(action: controller.toggleItalic) {
                Image(systemName: "italic")
            }
            .help("Kursywa (⌘I)")

            Divider().frame(height: 16)

            Button("H1") { controller.toggleHeader(1) }.help("Nagłówek 1 (⌘1)")
            Button("H2") { controller.toggleHeader(2) }.help("Nagłówek 2 (⌘2)")
            Button("H3") { controller.toggleHeader(3) }.help("Nagłówek 3 (⌘3)")

            Divider().frame(height: 16)

            Button(action: { controller.toggleList("bullet") }) {
                Image(systemName: "list.bullet")
            }
            .help("Lista punktowana")

            Button(action: { controller.toggleList("ordered") }) {
                Image(systemName: "list.number")
            }
            .help("Lista numerowana")

            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
