import AppKit
import SwiftUI

/// Geometry for a parsed diagram: a layered flowchart or a sequence diagram.
struct MermaidLayout {
    struct Box { var rect: CGRect; var lines: [String]; var shape: MermaidDiagram.Shape; var note = false }
    struct Connector {
        var points: [CGPoint]
        var curved = false
        var stroke: MermaidDiagram.Stroke = .solid
        var dashed = false
        var head: MermaidDiagram.Arrow?
        var tail: MermaidDiagram.Arrow?
        var label: [String] = []
        var labelCenter: CGPoint = .zero
    }
    struct Frame { var rect: CGRect; var title: String; var dividers: [(CGFloat, String)] }
    var size: CGSize = .zero
    var boxes: [Box] = []
    var connectors: [Connector] = []
    var frames: [Frame] = []
    var lifelines: [(CGFloat, CGFloat, CGFloat)] = []
    var summary = ""

    static let lineHeight: CGFloat = 17

    @MainActor static func measure(_ text: String, width: CGFloat) -> (lines: [String], size: CGSize) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        func measured(_ value: String) -> CGFloat { ceil((value as NSString).size(withAttributes: attributes).width) }
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var current = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
                let candidate = current.isEmpty ? word : current + " " + word
                if !current.isEmpty, measured(candidate) > width { lines.append(current); current = word } else { current = candidate }
            }
            lines.append(current)
        }
        let widest = lines.map(measured).max() ?? 0
        return (lines, CGSize(width: widest, height: CGFloat(max(1, lines.count)) * lineHeight))
    }

    @MainActor static func make(_ diagram: MermaidDiagram) -> MermaidLayout {
        switch diagram.kind {
        case .flowchart(let direction): flowchart(diagram, direction: direction)
        case .sequence: sequence(diagram)
        }
    }

    // MARK: Flowchart

    @MainActor private static func flowchart(_ diagram: MermaidDiagram, direction: MermaidDiagram.Direction) -> MermaidLayout {
        let nodes = diagram.nodes, count = nodes.count
        var indices: [String: Int] = [:]
        for (index, node) in nodes.enumerated() { indices[node.id] = index }
        var sizes: [CGSize] = [], texts: [[String]] = []
        for node in nodes {
            let measured = measure(node.label, width: 180)
            var width = measured.size.width + 28, height = measured.size.height + 18
            switch node.shape {
            case .circle: width = max(width, height) + 6; height = width
            case .diamond: width = width * 1.4 + 12; height = height * 1.5 + 8
            case .hexagon: width += 24
            case .stadium: width += 14
            case .cylinder: height += 12
            default: break
            }
            sizes.append(CGSize(width: max(width, 56), height: max(height, 36))); texts.append(measured.lines)
        }
        let edges = diagram.edges.compactMap { edge -> (Int, Int, MermaidDiagram.Edge)? in
            guard let from = indices[edge.from], let to = indices[edge.to] else { return nil }
            return (from, to, edge)
        }
        // Break cycles with a depth-first search, then layer by longest path.
        var outgoing = Array(repeating: [Int](), count: count)
        for (index, edge) in edges.enumerated() where edge.0 != edge.1 { outgoing[edge.0].append(index) }
        var state = Array(repeating: 0, count: count), back = Set<Int>()
        for root in 0..<count where state[root] == 0 {
            var stack: [(Int, Int)] = [(root, 0)]; state[root] = 1
            while let (node, next) = stack.last {
                if next < outgoing[node].count {
                    stack[stack.count - 1].1 += 1
                    let edgeIndex = outgoing[node][next], target = edges[edgeIndex].1
                    if state[target] == 1 { back.insert(edgeIndex) } else if state[target] == 0 { state[target] = 1; stack.append((target, 0)) }
                } else { state[node] = 2; stack.removeLast() }
            }
        }
        var layer = Array(repeating: 0, count: count), indegree = Array(repeating: 0, count: count)
        for (index, edge) in edges.enumerated() where edge.0 != edge.1 && !back.contains(index) { indegree[edge.1] += 1 }
        var queue = (0..<count).filter { indegree[$0] == 0 }, head = 0
        while head < queue.count {
            let node = queue[head]; head += 1
            for edgeIndex in outgoing[node] where !back.contains(edgeIndex) {
                let target = edges[edgeIndex].1
                layer[target] = max(layer[target], layer[node] + 1)
                indegree[target] -= 1
                if indegree[target] == 0 { queue.append(target) }
            }
        }
        let layerCount = (layer.max() ?? 0) + 1
        var layers = Array(repeating: [Int](), count: layerCount)
        for node in 0..<count { layers[layer[node]].append(node) }
        var order = Array(repeating: 0, count: count)
        func renumber() { for nodesInLayer in layers { for (position, node) in nodesInLayer.enumerated() { order[node] = position } } }
        renumber()
        for sweep in 0..<4 {
            let down = sweep.isMultiple(of: 2)
            for index in (down ? Array(1..<max(1, layerCount)) : Array((0..<max(0, layerCount - 1)).reversed())) {
                let neighbor = down ? index - 1 : index + 1
                func key(_ node: Int) -> Double {
                    let linked = edges.compactMap { edge -> Int? in
                        if down, edge.1 == node, layer[edge.0] == neighbor { return edge.0 }
                        if !down, edge.0 == node, layer[edge.1] == neighbor { return edge.1 }
                        return nil
                    }
                    return linked.isEmpty ? Double(order[node]) : Double(linked.map { order[$0] }.reduce(0, +)) / Double(linked.count)
                }
                let keys = Dictionary(uniqueKeysWithValues: layers[index].map { ($0, key($0)) })
                layers[index].sort { keys[$0]! == keys[$1]! ? order[$0] < order[$1] : keys[$0]! < keys[$1]! }
                renumber()
            }
        }
        // Coordinates along the rank (main) axis and across it.
        let horizontal = direction == .leftRight || direction == .rightLeft
        func main(_ size: CGSize) -> CGFloat { horizontal ? size.width : size.height }
        func cross(_ size: CGSize) -> CGFloat { horizontal ? size.height : size.width }
        var labelSizes: [Int: (lines: [String], size: CGSize)] = [:]
        for (index, edge) in edges.enumerated() { if let label = edge.2.label { labelSizes[index] = measure(label, width: 140) } }
        let padding: CGFloat = 14, nodeGap: CGFloat = 28
        var rankStart: [CGFloat] = [], cursor = padding
        for index in 0..<layerCount {
            rankStart.append(cursor)
            let thickness = layers[index].map { main(sizes[$0]) }.max() ?? 0
            var gap: CGFloat = horizontal ? 64 : 52
            for (edgeIndex, edge) in edges.enumerated() where min(layer[edge.0], layer[edge.1]) == index {
                if let size = labelSizes[edgeIndex]?.size { gap = max(gap, (horizontal ? size.width : size.height) + 30) }
            }
            cursor += thickness + gap
        }
        let totalMain = cursor - (horizontal ? 64 : 52) + padding
        let crossTotals = layers.map { nodesInLayer in nodesInLayer.map { cross(sizes[$0]) }.reduce(0, +) + nodeGap * CGFloat(max(0, nodesInLayer.count - 1)) }
        let widest = crossTotals.max() ?? 0
        var centers = Array(repeating: CGPoint.zero, count: count)
        for (index, nodesInLayer) in layers.enumerated() {
            let thickness = nodesInLayer.map { main(sizes[$0]) }.max() ?? 0
            var position = padding + (widest - crossTotals[index]) / 2
            for node in nodesInLayer {
                var mainCenter = rankStart[index] + thickness / 2
                if direction == .bottomUp || direction == .rightLeft { mainCenter = totalMain - mainCenter }
                let crossCenter = position + cross(sizes[node]) / 2
                centers[node] = horizontal ? CGPoint(x: mainCenter, y: crossCenter) : CGPoint(x: crossCenter, y: mainCenter)
                position += cross(sizes[node]) + nodeGap
            }
        }
        var layout = MermaidLayout()
        layout.size = horizontal ? CGSize(width: totalMain, height: widest + padding * 2) : CGSize(width: widest + padding * 2, height: totalMain)
        let rects = (0..<count).map { CGRect(x: centers[$0].x - sizes[$0].width / 2, y: centers[$0].y - sizes[$0].height / 2, width: sizes[$0].width, height: sizes[$0].height) }
        for node in 0..<count { layout.boxes.append(Box(rect: rects[node], lines: texts[node], shape: nodes[node].shape)) }
        for (index, edge) in edges.enumerated() where edge.2.stroke != .invisible {
            var connector = Connector(points: [], stroke: edge.2.stroke, dashed: edge.2.stroke == .dotted,
                                      head: edge.2.arrowEnd ? .filled : nil, tail: edge.2.arrowStart ? .filled : nil)
            let from = rects[edge.0], to = rects[edge.1]
            if edge.0 == edge.1 {
                let x = from.maxX, y = from.midY
                connector.points = [CGPoint(x: x, y: y - 8), CGPoint(x: x + 26, y: y - 8), CGPoint(x: x + 26, y: y + 8), CGPoint(x: x, y: y + 8)]
                connector.labelCenter = CGPoint(x: x + 30, y: y)
                layout.size.width = max(layout.size.width, x + 40)
            } else if back.contains(index) || abs(layer[edge.0] - layer[edge.1]) > 1 {
                // Long and reversed edges bow sideways so they do not run through nodes.
                let start = CGPoint(x: from.midX, y: from.midY), end = CGPoint(x: to.midX, y: to.midY)
                let dx = end.x - start.x, dy = end.y - start.y, length = max(1, hypot(dx, dy))
                let bend: CGFloat = back.contains(index) ? 46 : 30
                let control = CGPoint(x: (start.x + end.x) / 2 - dy / length * bend, y: (start.y + end.y) / 2 + dx / length * bend)
                connector.points = [boundary(from, shape: nodes[edge.0].shape, toward: control), control, boundary(to, shape: nodes[edge.1].shape, toward: control)]
                connector.curved = true
                connector.labelCenter = CGPoint(x: (connector.points[0].x + 2 * control.x + connector.points[2].x) / 4, y: (connector.points[0].y + 2 * control.y + connector.points[2].y) / 4)
            } else {
                let start = boundary(from, shape: nodes[edge.0].shape, toward: CGPoint(x: to.midX, y: to.midY))
                let end = boundary(to, shape: nodes[edge.1].shape, toward: CGPoint(x: from.midX, y: from.midY))
                connector.points = [start, end]
                connector.labelCenter = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            }
            if let label = labelSizes[index] { connector.label = label.lines }
            layout.connectors.append(connector)
        }
        let described = edges.prefix(24).map { "\(nodes[$0.0].label) to \(nodes[$0.1].label)\($0.2.label.map { ", \($0)" } ?? "")" }
        layout.summary = "Flowchart with \(count) \(count == 1 ? "node" : "nodes"). " + described.joined(separator: "; ")
        return layout
    }

    private static func boundary(_ rect: CGRect, shape: MermaidDiagram.Shape, toward point: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = point.x - center.x, dy = point.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let halfWidth = rect.width / 2, halfHeight = rect.height / 2
        let scale: CGFloat
        switch shape {
        case .circle: scale = halfWidth / hypot(dx, dy)
        case .diamond: scale = 1 / (abs(dx) / halfWidth + abs(dy) / halfHeight)
        default: scale = min(dx == 0 ? .infinity : halfWidth / abs(dx), dy == 0 ? .infinity : halfHeight / abs(dy))
        }
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }

    // MARK: Sequence

    @MainActor private static func sequence(_ diagram: MermaidDiagram) -> MermaidLayout {
        let participants = diagram.participants, count = participants.count
        var columns: [String: Int] = [:]
        for (index, participant) in participants.enumerated() { columns[participant.id] = index }
        let headers = participants.map { measure($0.label, width: 150) }
        let widths: [CGFloat] = headers.map { max($0.size.width + 26, 76) }
        let headerHeight: CGFloat = (headers.map(\.size.height).max() ?? lineHeight) + 18
        var gaps: [CGFloat] = []
        for index in 0..<max(0, count - 1) {
            let leftHalf: CGFloat = widths[index] / 2
            let rightHalf: CGFloat = widths[index + 1] / 2
            gaps.append(leftHalf + rightHalf + 30)
        }
        var leftExtra: CGFloat = 0, rightExtra: CGFloat = 0
        var measured: [Int: (lines: [String], size: CGSize)] = [:]
        func span(_ a: Int, _ b: Int) -> CGFloat { gaps[min(a, b)..<max(a, b)].reduce(0, +) }
        for (index, event) in diagram.events.enumerated() {
            switch event {
            case .message(let from, let to, let text, _, _, let number):
                guard let a = columns[from], let b = columns[to] else { continue }
                let label = number.map { "\($0). \(text)" } ?? text
                let size = measure(label, width: 260); measured[index] = size
                if a == b {
                    if a < count - 1 { gaps[a] = max(gaps[a], size.size.width + 56) } else { rightExtra = max(rightExtra, size.size.width + 56) }
                } else {
                    let required = size.size.width + 36, current = span(a, b)
                    if current < required { gaps[max(a, b) - 1] += required - current }
                }
            case .note(let placement, let ids, let text):
                let size = measure(text, width: 180); measured[index] = size
                guard let a = ids.first.flatMap({ columns[$0] }) else { continue }
                let width = size.size.width + 20
                switch placement {
                case .left: if a == 0 { leftExtra = max(leftExtra, width + 12 - widths[0] / 2) } else { gaps[a - 1] = max(gaps[a - 1], width + 24) }
                case .right: if a == count - 1 { rightExtra = max(rightExtra, width + 12 - widths[a] / 2) } else { gaps[a] = max(gaps[a], width + 24) }
                case .over: if ids.count == 1 { if a == 0 { leftExtra = max(leftExtra, width / 2 - widths[0] / 2) }; if a == count - 1 { rightExtra = max(rightExtra, width / 2 - widths[a] / 2) } }
                }
            default: break
            }
        }
        let padding: CGFloat = 14
        var xs: [CGFloat] = [], x = padding + max(0, leftExtra) + (widths.first ?? 0) / 2
        for index in 0..<count { xs.append(x); if index < gaps.count { x += gaps[index] } }
        var layout = MermaidLayout()
        for (index, participant) in participants.enumerated() {
            layout.boxes.append(Box(rect: CGRect(x: xs[index] - widths[index] / 2, y: padding, width: widths[index], height: headerHeight),
                                    lines: headers[index].lines, shape: participant.actor ? .stadium : .rectangle))
        }
        var y = padding + headerHeight + 18
        var open: [(start: CGFloat, title: String, dividers: [(CGFloat, String)], drawn: Bool)] = []
        let left = padding, right = (xs.last ?? 0) + (widths.last ?? 0) / 2 + max(0, rightExtra)
        for (index, event) in diagram.events.enumerated() {
            switch event {
            case .message(let from, let to, _, let dashed, let arrow, _):
                guard let a = columns[from], let b = columns[to], let size = measured[index] else { continue }
                let lineY = y + size.size.height + 6
                var connector = Connector(points: [], dashed: dashed, head: arrow == .none ? nil : arrow)
                if a == b {
                    connector.points = [CGPoint(x: xs[a], y: lineY), CGPoint(x: xs[a] + 34, y: lineY), CGPoint(x: xs[a] + 34, y: lineY + 18), CGPoint(x: xs[a] + 2, y: lineY + 18)]
                    connector.labelCenter = CGPoint(x: xs[a] + 40 + size.size.width / 2, y: y + size.size.height / 2 + 2)
                    y += 18
                } else {
                    connector.points = [CGPoint(x: xs[a], y: lineY), CGPoint(x: xs[b] + (b > a ? -2 : 2), y: lineY)]
                    connector.labelCenter = CGPoint(x: (xs[a] + xs[b]) / 2, y: y + size.size.height / 2 + 2)
                }
                connector.label = size.lines
                layout.connectors.append(connector)
                y = lineY + 18
            case .note(let placement, let ids, _):
                guard let size = measured[index], let a = ids.first.flatMap({ columns[$0] }) else { continue }
                let width = size.size.width + 20, height = size.size.height + 14
                var rect: CGRect
                switch placement {
                case .left: rect = CGRect(x: xs[a] - 12 - width, y: y, width: width, height: height)
                case .right: rect = CGRect(x: xs[a] + 12, y: y, width: width, height: height)
                case .over:
                    let b = ids.count > 1 ? (columns[ids[1]] ?? a) : a
                    let low = min(xs[a], xs[b]), high = max(xs[a], xs[b])
                    let spanWidth = max(width, high - low + 48)
                    rect = CGRect(x: (low + high) / 2 - spanWidth / 2, y: y, width: spanWidth, height: height)
                }
                layout.boxes.append(Box(rect: rect, lines: size.lines, shape: .rectangle, note: true))
                y += height + 14
            case .frameStart(let kind, let label):
                open.append((y, kind == "rect" || kind == "box" ? "" : (label.isEmpty ? kind : "\(kind) [\(label)]"), [], kind != "rect" && kind != "box"))
                y += 26
            case .frameDivider(let label):
                if !open.isEmpty { open[open.count - 1].dividers.append((y, label.isEmpty ? "" : "[\(label)]")) }
                y += 24
            case .frameEnd:
                guard let frame = open.popLast() else { continue }
                if frame.drawn {
                    let inset = CGFloat(open.count) * 8
                    layout.frames.append(Frame(rect: CGRect(x: left + inset, y: frame.start, width: right - left - inset * 2, height: y - frame.start + 4),
                                               title: frame.title, dividers: frame.dividers))
                }
                y += 14
            }
        }
        for index in 0..<count { layout.lifelines.append((xs[index], padding + headerHeight, y + 6)) }
        layout.size = CGSize(width: right + padding, height: y + 14)
        let messages = diagram.events.compactMap { event -> String? in
            if case .message(let from, let to, let text, _, _, _) = event { return "\(from) to \(to)\(text.isEmpty ? "" : ": \(text)")" }
            return nil
        }
        layout.summary = "Sequence diagram with \(count) participants. " + messages.prefix(24).joined(separator: "; ")
        return layout
    }
}

@MainActor enum MermaidLayoutCache {
    private final class Entry { let layout: MermaidLayout?; init(_ layout: MermaidLayout?) { self.layout = layout } }
    private static let cache: NSCache<NSString, Entry> = { let value = NSCache<NSString, Entry>(); value.countLimit = 64; return value }()
    static func layout(_ source: String) -> MermaidLayout? {
        if let entry = cache.object(forKey: source as NSString) { return entry.layout }
        let layout = MermaidDiagram.parse(source).map(MermaidLayout.make)
        cache.setObject(Entry(layout), forKey: source as NSString)
        return layout
    }
}

struct MermaidCanvas: View {
    let layout: MermaidLayout
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Canvas { context, _ in
            let ink = Color.primary, fill = scheme == .dark ? Color(white: 0.17) : Color(white: 0.985)
            let noteFill = scheme == .dark ? Color(red: 0.32, green: 0.29, blue: 0.14) : Color(red: 1, green: 0.97, blue: 0.8)
            for frame in layout.frames {
                context.stroke(Path(roundedRect: frame.rect, cornerRadius: 6), with: .color(ink.opacity(0.35)), lineWidth: 1)
                if !frame.title.isEmpty {
                    context.draw(Text(frame.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(ink.opacity(0.75)), at: CGPoint(x: frame.rect.minX + 8, y: frame.rect.minY + 10), anchor: .leading)
                }
                for (y, label) in frame.dividers {
                    var path = Path(); path.move(to: CGPoint(x: frame.rect.minX, y: y)); path.addLine(to: CGPoint(x: frame.rect.maxX, y: y))
                    context.stroke(path, with: .color(ink.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    if !label.isEmpty { context.draw(Text(label).font(.system(size: 11)).foregroundStyle(ink.opacity(0.7)), at: CGPoint(x: frame.rect.midX, y: y + 10), anchor: .center) }
                }
            }
            for (x, top, bottom) in layout.lifelines {
                var path = Path(); path.move(to: CGPoint(x: x, y: top)); path.addLine(to: CGPoint(x: x, y: bottom))
                context.stroke(path, with: .color(ink.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            for connector in layout.connectors { draw(connector, in: &context, ink: ink) }
            for box in layout.boxes {
                let path = shape(box.shape, box.rect)
                context.fill(path, with: .color(box.note ? noteFill : fill))
                if !box.note { context.fill(path, with: .color(Color.accentColor.opacity(0.1))) }
                context.stroke(path, with: .color(ink.opacity(box.note ? 0.3 : 0.5)), lineWidth: 1.2)
                let top = box.rect.midY - CGFloat(box.lines.count) * MermaidLayout.lineHeight / 2
                for (index, line) in box.lines.enumerated() {
                    context.draw(Text(line).font(.system(size: 13)).foregroundStyle(ink), at: CGPoint(x: box.rect.midX, y: top + (CGFloat(index) + 0.5) * MermaidLayout.lineHeight), anchor: .center)
                }
            }
            for connector in layout.connectors where !connector.label.isEmpty {
                let height = CGFloat(connector.label.count) * MermaidLayout.lineHeight
                let resolved = connector.label.map { context.resolve(Text($0).font(.system(size: 12)).foregroundStyle(ink.opacity(0.85))) }
                let width = resolved.map { $0.measure(in: CGSize(width: 400, height: 40)).width }.max() ?? 0
                let rect = CGRect(x: connector.labelCenter.x - width / 2 - 4, y: connector.labelCenter.y - height / 2 - 1, width: width + 8, height: height + 2)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(fill.opacity(0.92)))
                for (index, text) in resolved.enumerated() {
                    context.draw(text, at: CGPoint(x: connector.labelCenter.x, y: rect.minY + 1 + (CGFloat(index) + 0.5) * MermaidLayout.lineHeight), anchor: .center)
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(layout.summary)
        .accessibilityAddTraits(.isImage)
    }

    private func shape(_ shape: MermaidDiagram.Shape, _ rect: CGRect) -> Path {
        switch shape {
        case .rectangle: Path(rect)
        case .rounded: Path(roundedRect: rect, cornerRadius: 8)
        case .stadium: Path(roundedRect: rect, cornerRadius: rect.height / 2)
        case .circle: Path(ellipseIn: rect)
        case .diamond:
            Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)); path.addLine(to: CGPoint(x: rect.minX, y: rect.midY)); path.closeSubpath()
            }
        case .hexagon:
            Path { path in
                let inset = min(14, rect.width / 4)
                path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY)); path.addLine(to: CGPoint(x: rect.minX, y: rect.midY)); path.closeSubpath()
            }
        case .subroutine:
            Path { path in
                path.addRect(rect)
                path.move(to: CGPoint(x: rect.minX + 7, y: rect.minY)); path.addLine(to: CGPoint(x: rect.minX + 7, y: rect.maxY))
                path.move(to: CGPoint(x: rect.maxX - 7, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX - 7, y: rect.maxY))
            }
        case .cylinder:
            Path { path in
                let cap = min(10, rect.height / 4)
                path.addEllipse(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cap * 2))
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + cap)); path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cap))
                path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - cap), control: CGPoint(x: rect.midX, y: rect.maxY + cap))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cap))
            }
        }
    }

    private func draw(_ connector: MermaidLayout.Connector, in context: inout GraphicsContext, ink: Color) {
        guard connector.points.count >= 2 else { return }
        var path = Path()
        path.move(to: connector.points[0])
        if connector.curved, connector.points.count == 3 { path.addQuadCurve(to: connector.points[2], control: connector.points[1]) }
        else { for point in connector.points.dropFirst() { path.addLine(to: point) } }
        let width: CGFloat = connector.stroke == .thick ? 2.6 : 1.4
        context.stroke(path, with: .color(ink.opacity(0.7)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: connector.dashed ? [5, 4] : []))
        let points = connector.points
        if let head = connector.head { arrow(head, at: points[points.count - 1], from: points[points.count - 2], in: &context, ink: ink) }
        if let tail = connector.tail { arrow(tail, at: points[0], from: points[1], in: &context, ink: ink) }
    }

    private func arrow(_ kind: MermaidDiagram.Arrow, at tip: CGPoint, from origin: CGPoint, in context: inout GraphicsContext, ink: Color) {
        let angle = atan2(tip.y - origin.y, tip.x - origin.x), size: CGFloat = 9
        func point(_ offset: CGFloat) -> CGPoint { CGPoint(x: tip.x - size * cos(angle + offset), y: tip.y - size * sin(angle + offset)) }
        switch kind {
        case .filled:
            var path = Path(); path.move(to: tip); path.addLine(to: point(0.42)); path.addLine(to: point(-0.42)); path.closeSubpath()
            context.fill(path, with: .color(ink.opacity(0.8)))
        case .open:
            var path = Path(); path.move(to: point(0.5)); path.addLine(to: tip); path.addLine(to: point(-0.5))
            context.stroke(path, with: .color(ink.opacity(0.8)), lineWidth: 1.4)
        case .cross:
            var path = Path()
            let center = CGPoint(x: tip.x - 5 * cos(angle), y: tip.y - 5 * sin(angle))
            path.move(to: CGPoint(x: center.x - 4, y: center.y - 4)); path.addLine(to: CGPoint(x: center.x + 4, y: center.y + 4))
            path.move(to: CGPoint(x: center.x + 4, y: center.y - 4)); path.addLine(to: CGPoint(x: center.x - 4, y: center.y + 4))
            context.stroke(path, with: .color(ink.opacity(0.8)), lineWidth: 1.6)
        case .none: break
        }
    }
}
