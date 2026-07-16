import SwiftUI

/// Graf połączeń między notatkami (Zadanie 1.3). Nodes are notes, edges are the
/// resolved `[[...]]` wiki links. A simple force-directed layout is computed once
/// when the view appears (static — no animation); nodes can then be dragged apart
/// by hand. Clicking a node opens the note.
struct GraphView: View {
    let model: NotesModel
    let settings: AppSettings
    var accent: Color = .accentColor
    /// Opens the clicked note (the presenter also closes the graph).
    let openNote: (UUID) -> Void
    let onClose: () -> Void

    /// Node centre points in graph coordinates, keyed by note id.
    @State private var positions: [UUID: CGPoint] = [:]
    @State private var hoveredID: UUID?

    private let canvasSize = CGSize(width: 780, height: 540)
    /// Keep nodes at least this far from the canvas edge (leaves room for labels).
    private let edgeMargin: CGFloat = 50

    private var nodes: [Note] { model.notes }

    /// Undirected, deduplicated edges between existing notes.
    private var edges: [(from: UUID, to: UUID)] {
        let ids = Set(nodes.map(\.id))
        var seen = Set<String>()
        var result: [(from: UUID, to: UUID)] = []
        for note in nodes {
            for target in note.links where ids.contains(target) && target != note.id {
                let key = [note.id.uuidString, target.uuidString].sorted().joined(separator: "|")
                if seen.insert(key).inserted { result.append((note.id, target)) }
            }
        }
        return result
    }

    /// Connections per note — used to size the node circles.
    private var degrees: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for edge in edges {
            counts[edge.from, default: 0] += 1
            counts[edge.to, default: 0] += 1
        }
        return counts
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if nodes.isEmpty {
                ContentUnavailableView(settings.t("Brak notatek", "No notes"),
                                       systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(width: canvasSize.width, height: canvasSize.height)
            } else {
                graphArea
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { layoutIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label(settings.t("Graf połączeń", "Link graph"),
                  systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
                .foregroundStyle(accent)
            Text(settings.t("\(nodes.count) notatek · \(edges.count) połączeń",
                            "\(nodes.count) notes · \(edges.count) links"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(settings.t("Zamknij", "Close")) { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var graphArea: some View {
        ZStack {
            // Edges underneath the nodes.
            Canvas { context, _ in
                for edge in edges {
                    guard let a = positions[edge.from], let b = positions[edge.to] else { continue }
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    context.stroke(path, with: .color(.secondary.opacity(0.45)), lineWidth: 1)
                }
            }
            ForEach(nodes) { note in
                nodeView(note)
            }
            if edges.isEmpty {
                Text(settings.t("Brak połączeń — dodaj linki [[Tytuł notatki]] w treści notatek.",
                                "No links yet — add [[Note title]] links inside your notes."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
                    .position(x: canvasSize.width / 2, y: 24)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .coordinateSpace(name: "graph")
    }

    private func nodeView(_ note: Note) -> some View {
        let degree = degrees[note.id] ?? 0
        let radius: CGFloat = 7 + min(CGFloat(degree) * 2.5, 11)
        let position = positions[note.id] ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let hovered = hoveredID == note.id

        return Circle()
            // Linked notes get the accent colour; isolated ones stay grey.
            .fill(degree > 0 ? accent : Color.gray.opacity(0.5))
            .frame(width: radius * 2, height: radius * 2)
            .overlay(Circle().stroke(.white.opacity(hovered ? 0.9 : 0.25), lineWidth: 1.5))
            .overlay {
                Text(note.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 110)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: radius + 12)
            }
            .scaleEffect(hovered ? 1.15 : 1.0)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .position(position)
            .onHover { hoveredID = $0 ? note.id : (hoveredID == note.id ? nil : hoveredID) }
            .onTapGesture { openNote(note.id) }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named("graph"))
                    .onChanged { value in
                        positions[note.id] = clamp(value.location)
                    }
            )
            .help(settings.t("Kliknij, aby otworzyć „\(note.title)”; przeciągnij, aby rozsunąć węzły",
                             "Click to open “\(note.title)”; drag to spread nodes apart"))
    }

    /// Keeps a point inside the canvas, `edgeMargin` from the borders.
    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, edgeMargin), canvasSize.width - edgeMargin),
                y: min(max(point.y, edgeMargin), canvasSize.height - edgeMargin))
    }

    // MARK: - Force-directed layout (Fruchterman–Reingold, computed once)

    private func layoutIfNeeded() {
        guard positions.isEmpty, !nodes.isEmpty else { return }
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let count = nodes.count

        // Start on a circle — deterministic and already overlap-free.
        var pos: [UUID: CGPoint] = [:]
        let startRadius = min(canvasSize.width, canvasSize.height) * 0.35
        for (index, note) in nodes.enumerated() {
            let angle = 2 * CGFloat.pi * CGFloat(index) / CGFloat(count)
            pos[note.id] = CGPoint(x: center.x + startRadius * cos(angle),
                                   y: center.y + startRadius * sin(angle))
        }
        guard count > 1 else {
            positions = pos.mapValues { _ in center }
            return
        }

        // Ideal spring length between nodes for the available area.
        let k = sqrt(canvasSize.width * canvasSize.height / CGFloat(count)) * 0.7
        let edgeList = edges
        let ids = nodes.map(\.id)
        // Displacement cap ("temperature") shrinks linearly, so the layout
        // settles instead of oscillating.
        var temperature = min(canvasSize.width, canvasSize.height) / 8
        let iterations = 250
        let cooling = temperature / CGFloat(iterations)

        for _ in 0..<iterations {
            var dispX: [UUID: CGFloat] = [:]
            var dispY: [UUID: CGFloat] = [:]

            // Repulsion between every pair.
            for i in 0..<count {
                for j in (i + 1)..<count {
                    let a = ids[i], b = ids[j]
                    var dx = pos[a]!.x - pos[b]!.x
                    var dy = pos[a]!.y - pos[b]!.y
                    var dist = sqrt(dx * dx + dy * dy)
                    if dist < 0.01 {
                        dx = CGFloat.random(in: -1...1); dy = CGFloat.random(in: -1...1)
                        dist = max(sqrt(dx * dx + dy * dy), 0.01)
                    }
                    let force = (k * k) / dist
                    dispX[a, default: 0] += dx / dist * force
                    dispY[a, default: 0] += dy / dist * force
                    dispX[b, default: 0] -= dx / dist * force
                    dispY[b, default: 0] -= dy / dist * force
                }
            }

            // Attraction along edges.
            for edge in edgeList {
                let dx = pos[edge.from]!.x - pos[edge.to]!.x
                let dy = pos[edge.from]!.y - pos[edge.to]!.y
                let dist = max(sqrt(dx * dx + dy * dy), 0.01)
                let force = (dist * dist) / k
                dispX[edge.from, default: 0] -= dx / dist * force
                dispY[edge.from, default: 0] -= dy / dist * force
                dispX[edge.to, default: 0] += dx / dist * force
                dispY[edge.to, default: 0] += dy / dist * force
            }

            // Gentle pull to the centre so disconnected clusters don't drift apart.
            for id in ids {
                dispX[id, default: 0] += (center.x - pos[id]!.x) * 0.02
                dispY[id, default: 0] += (center.y - pos[id]!.y) * 0.02
            }

            // Apply, capped by the current temperature.
            for id in ids {
                let dx = dispX[id] ?? 0, dy = dispY[id] ?? 0
                let length = max(sqrt(dx * dx + dy * dy), 0.01)
                let step = min(length, temperature)
                let moved = CGPoint(x: pos[id]!.x + dx / length * step,
                                    y: pos[id]!.y + dy / length * step)
                pos[id] = clamp(moved)
            }
            temperature = max(temperature - cooling, 0.5)
        }

        positions = pos
    }
}
