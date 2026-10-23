import AppKit
import SwiftUI
import Testing
@testable import CoincideMarkdown

@Test func mermaidFlowchartsParseShapesChainsLabelsAndIgnoreInteraction() throws {
    let diagram = try #require(MermaidDiagram.parse("""
    %% comment
    flowchart LR
        A[Start] --> B{Ready?}
        B -- yes --> C((Done)) & D([Retry])
        B -->|no| A
        D -.-> E[(Store)] ==> F[["Sub <br> routine"]]
        click A "https://example.com" "never followed"
        classDef hot fill:#f00
        subgraph group [Group]
          G
        end
    """))
    #expect(diagram.kind == .flowchart(.leftRight))
    #expect(diagram.nodes.map(\.id) == ["A", "B", "C", "D", "E", "F", "G"])
    #expect(diagram.nodes.map(\.shape) == [.rectangle, .diamond, .circle, .stadium, .cylinder, .subroutine, .rectangle])
    #expect(diagram.nodes[5].label == "Sub\nroutine")
    #expect(diagram.edges.map { "\($0.from)>\($0.to)" } == ["A>B", "B>C", "B>D", "B>A", "D>E", "E>F"])
    #expect(diagram.edges[1].label == "yes" && diagram.edges[3].label == "no")
    #expect(diagram.edges[4].stroke == .dotted && diagram.edges[5].stroke == .thick && diagram.edges.allSatisfy(\.arrowEnd))
    #expect(MermaidDiagram.parse("graph TD; A-->B; B---C")?.edges.map(\.arrowEnd) == [true, false])
}

@Test func mermaidSequenceDiagramsParseParticipantsMessagesNotesAndFrames() throws {
    let diagram = try #require(MermaidDiagram.parse("""
    sequenceDiagram
        autonumber
        participant A as Alice
        actor B as Bob
        A->>B: Hello
        B-->>A: Hi back
        loop Every minute
            A-)B: ping
        alt ok
            B->>B: think
        else failed
            B-xA: error
        end
        end
        Note over A,B: shared
    """))
    #expect(diagram.participants.map(\.label) == ["Alice", "Bob"] && diagram.participants[1].actor)
    let messages = diagram.events.compactMap { event -> String? in
        if case .message(let from, let to, let text, let dashed, _, let number) = event { return "\(number ?? 0) \(from)\(dashed ? "-->" : "->")\(to) \(text)" }
        return nil
    }
    #expect(messages == ["1 A->B Hello", "2 B-->A Hi back", "3 A->B ping", "4 B->B think", "5 B->A error"])
    #expect(diagram.events.filter { $0 == .frameEnd }.count == 2)
    #expect(diagram.events.last == .note(.over, ["A", "B"], "shared"))
}

@Test func unsupportedMermaidStaysSource() {
    for source in ["pie title Pets\n\"Dogs\" : 386", "classDiagram\nA <|-- B", "graph TD\nA -- B", "sequenceDiagram\nA ? B: what", "flowchart TD\n", "",
                   "sequenceDiagram\nend", String(repeating: "graph TD\nA-->B\n", count: 2_000)] {
        #expect(MermaidDiagram.parse(source) == nil, "\(source.prefix(40))")
    }
    let unclosed = MarkdownDocument(parsing: "```mermaid\ngraph TD\nA-->B")
    #expect(unclosed.blocks == [.code(language: "mermaid", text: "graph TD\nA-->B\n", meta: "", closed: false)])
}

@MainActor @Test func mermaidLayoutsSeparateLayersAndRenderInBothAppearances() throws {
    let flow = try #require(MermaidLayoutCache.layout("graph TD\nA[Plan] --> B[Build]\nB --> C[Test]\nC -->|fail| B\nA --> C"))
    let boxes = flow.boxes.map(\.rect)
    #expect(boxes.count == 3 && boxes[0].maxY < boxes[1].minY && boxes[1].maxY < boxes[2].minY)
    for (index, box) in boxes.enumerated() { for other in boxes.dropFirst(index + 1) { #expect(!box.intersects(other)) } }
    #expect(flow.connectors.count == 4 && flow.connectors.contains { $0.curved } && flow.summary.contains("Plan to Build"))
    let sequence = try #require(MermaidLayoutCache.layout("sequenceDiagram\nA->>B: a much longer message label than the boxes\nB-->>A: ok"))
    #expect(sequence.lifelines.count == 2 && sequence.lifelines[1].0 - sequence.lifelines[0].0 > 200)
    for layout in [flow, sequence] {
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: MermaidCanvas(layout: layout).environment(\.colorScheme, scheme)); renderer.scale = 1
            let image = try #require(renderer.cgImage)
            #expect(image.width == Int(layout.size.width.rounded(.up)) || abs(CGFloat(image.width) - layout.size.width) <= 1)
            #expect(image.height > 60)
        }
    }
}
