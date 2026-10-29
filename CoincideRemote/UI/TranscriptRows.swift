import CoincideRemoteKit
import SwiftUI

struct TranscriptBlockView: View {
    let block: TranscriptBlock
    let model: ThreadModel

    var body: some View {
        switch block {
        case .item(let item): ItemView(item: item, threadID: model.id)
        case .work(let items): WorkGroup(items: items, model: model)
        case .changes(let turnID, let files): ChangesCard(threadID: model.id, turnID: turnID, files: files)
        }
    }
}

struct ItemView: View {
    let item: RemoteItem
    let threadID: UUID
    @Environment(\.theme) private var theme

    var body: some View {
        switch item.kind {
        case .user:
            UserMessage(item: item)
        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                AgentRail(provider: item.provider)
                MarkdownText(text: item.text)
            }
        case .plan:
            Card(tint: theme.accent) {
                Label("Plan", systemImage: "list.bullet.clipboard").font(.headline)
                MarkdownText(text: item.text)
            }
        case .error:
            Card(tint: .red) {
                Label(item.title ?? String(localized: "Error"), systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.red)
                if !item.text.isEmpty { Text(item.text).font(.callout).textSelection(.enabled) }
            }
        case .notice:
            Text(item.text.isEmpty ? (item.title ?? "") : item.text)
                .font(.footnote)
                .foregroundStyle(theme.secondaryInk)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        case .approval:
            ApprovalCard(item: item, threadID: threadID, isInline: true)
        case .question:
            QuestionSummary(item: item)
        case .reasoning, .tool:
            ToolRow(item: item)
        case .unknown:
            EmptyView()
        }
    }
}

/// The colored line beside an agent's reply, as on the Mac.
struct AgentRail: View {
    let provider: String?
    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(theme.agent(provider).opacity(0.7))
            .frame(width: 3)
            .accessibilityHidden(true)
    }
}

struct UserMessage: View {
    let item: RemoteItem
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 6) {
                if !item.text.isEmpty {
                    Text(item.text)
                        .foregroundStyle(theme.ink)
                        .textSelection(.enabled)
                }
                let extras = (item.attachments ?? []).map { ("photo", $0) } + (item.context ?? []).map { ("text.quote", $0) }
                if !extras.isEmpty {
                    ForEach(Array(extras.enumerated()), id: \.offset) { _, extra in
                        Label(extra.1, systemImage: extra.0)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(theme.secondaryInk)
                    }
                }
                if item.steered {
                    Label("Sent into the running turn", systemImage: "arrow.turn.down.right")
                        .font(.caption2).foregroundStyle(theme.secondaryInk)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("You: \(item.text)"))
    }
}

struct Card<Content: View>: View {
    var tint: Color
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: theme.borderWidth))
    }
}

/// Consecutive tool calls and reasoning, collapsed to one line until opened.
struct WorkGroup: View {
    let items: [RemoteItem]
    @Bindable var model: ThreadModel
    @Environment(\.theme) private var theme

    private var key: UUID { items.first?.id ?? UUID() }
    private var isExpanded: Bool { model.expanded.contains(key) || items.contains { $0.isWaiting } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) {
                    if model.expanded.contains(key) { model.expanded.remove(key) } else { model.expanded.insert(key) }
                }
            } label: {
                HStack(spacing: 8) {
                    if items.contains(where: { $0.status == "running" }) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: failed ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(failed ? Color.red : theme.secondaryInk)
                    }
                    Text(summary).foregroundStyle(theme.secondaryInk)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(theme.secondaryInk)
                }
                .font(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { ToolRow(item: $0) }
                }
                .padding(.leading, 6)
            }
        }
    }

    private var failed: Bool { items.contains { $0.status == "failed" } }

    private var summary: String {
        let tools = items.filter { $0.kind == .tool }
        let last = tools.last?.title ?? (items.last?.kind == .reasoning ? String(localized: "Thinking") : "")
        if tools.count <= 1 { return last.isEmpty ? String(localized: "Worked") : last }
        return String(localized: "\(tools.count) steps · \(last)")
    }
}

/// One tool call or reasoning step: its title, and its input and output when opened.
struct ToolRow: View {
    let item: RemoteItem
    @State private var isOpen = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { isOpen.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol)
                        .frame(width: 18)
                        .foregroundStyle(statusColor)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(theme.ink)
                        .lineLimit(isOpen ? nil : 1)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if item.status == "running" { ProgressView().controlSize(.mini) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(isOpen ? "Hides the details" : "Shows the details"))
            if isOpen {
                if item.kind == .reasoning {
                    MarkdownText(text: item.text, font: .callout).foregroundStyle(theme.secondaryInk)
                } else {
                    if let detail = item.detail, !detail.isEmpty { Monospaced(text: detail) }
                    if !item.text.isEmpty { Monospaced(text: item.text) }
                    if item.isClipped {
                        Text("Shortened. The full output is on the Mac.").font(.caption2).foregroundStyle(theme.secondaryInk)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        if item.kind == .reasoning { return String(localized: "Thinking") }
        return item.title ?? item.text.components(separatedBy: "\n").first ?? ""
    }

    private var symbol: String {
        if item.kind == .reasoning { return "brain" }
        switch item.category {
        case "command": return "terminal"
        case "fileChange": return "pencil.line"
        case "read": return "doc.text"
        case "search": return "magnifyingglass"
        case "web": return "globe"
        case "mcp": return "puzzlepiece.extension"
        case "task": return "person.2"
        case "todo": return "checklist"
        default: return "wrench.and.screwdriver"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case "failed": .red
        case "declined": .orange
        default: theme.secondaryInk
        }
    }
}

struct Monospaced: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxHeight: 320)
        .background(theme.codeBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// What a turn changed, opening the turn's diff.
struct ChangesCard: View {
    let threadID: UUID
    let turnID: UUID
    let files: [RemoteChangedFile]
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            navigator.diff = .init(threadID: threadID, turnID: turnID)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("\(files.count) files changed", systemImage: "doc.on.doc")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(theme.ink)
                    Spacer()
                    DiffCounts(additions: files.reduce(0) { $0 + $1.additions }, deletions: files.reduce(0) { $0 + $1.deletions })
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.secondaryInk)
                }
                ForEach(files.prefix(4)) { file in
                    HStack {
                        Text(file.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                            .foregroundStyle(theme.secondaryInk)
                        Spacer()
                        DiffCounts(additions: file.additions, deletions: file.deletions).font(.caption2)
                    }
                }
                if files.count > 4 {
                    Text("and \(files.count - 4) more").font(.caption2).foregroundStyle(theme.secondaryInk)
                }
            }
            .padding(12)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Shows the turn’s diff"))
    }
}

struct DiffCounts: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(.green)
            Text("−\(deletions)").foregroundStyle(.red)
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(additions) added, \(deletions) removed"))
    }
}

/// An approval in the transcript: what was asked and, once answered, the answer. While it waits, its choices.
struct ApprovalCard: View {
    let item: RemoteItem
    let threadID: UUID
    var isInline = false
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme
    @State private var text = ""

    var body: some View {
        Card(tint: item.isWaiting ? .orange : theme.secondaryInk) {
            Label(item.title ?? String(localized: "Approval"), systemImage: "hand.raised")
                .font(.headline)
            if let detail = item.detail, !detail.isEmpty { Monospaced(text: detail) }
            if let approval = item.approval {
                if item.isWaiting, isInline {
                    // Its choices are in the banner above the composer, as on the Mac.
                    Label("Waiting for your answer below", systemImage: "arrow.down")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else if item.isWaiting {
                    if approval.acceptsText {
                        TextField(approval.textPlaceholder ?? String(localized: "Add a note"), text: $text, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                    }
                    ApprovalButtons(approval: approval) { option in
                        Task {
                            await client.perform(
                                .respond(threadID: threadID, itemID: item.id, optionID: option.id, text: text.isEmpty ? nil : text))
                        }
                    }
                } else if let resolution = approval.resolution {
                    Label(resolution, systemImage: "checkmark.circle").font(.callout).foregroundStyle(theme.secondaryInk)
                }
            }
        }
    }
}

struct ApprovalButtons: View {
    let approval: RemoteApproval
    let choose: (RemoteApproval.Option) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { buttons }
            VStack(alignment: .leading) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(approval.options) { option in
            if option.kind == "allowOnce" {
                Button(option.label) { choose(option) }.buttonStyle(.glassProminent)
            } else if option.kind == "deny" || option.kind == "cancel" {
                Button(option.label, role: .destructive) { choose(option) }.buttonStyle(.glass)
            } else {
                Button(option.label) { choose(option) }.buttonStyle(.glass)
            }
        }
    }
}

/// A question in the transcript: what was asked and the answers given.
struct QuestionSummary: View {
    let item: RemoteItem
    @Environment(\.theme) private var theme

    var body: some View {
        Card(tint: item.isWaiting ? .orange : theme.secondaryInk) {
            Label(item.questions?.title ?? String(localized: "Question"), systemImage: "questionmark.bubble").font(.headline)
            ForEach(item.questions?.questions ?? []) { question in
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.prompt).font(.callout)
                    if let answer = item.answers?[question.id], !answer.isEmpty {
                        Text(answer.joined(separator: ", ")).font(.callout.weight(.medium)).foregroundStyle(theme.accent)
                    }
                }
            }
            if item.isWaiting {
                Text("Answer below.").font(.caption).foregroundStyle(theme.secondaryInk)
            } else if item.status == "declined" {
                Text("Dismissed").font(.caption).foregroundStyle(theme.secondaryInk)
            }
        }
    }
}

/// Approvals and questions waiting for the user, above the composer as on the Mac.
struct WaitingBanner: View {
    let model: ThreadModel
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme
    @State private var answering: RemoteItem?
    @State private var note = ""

    var body: some View {
        if let item = model.waitingItems.first {
            VStack(alignment: .leading, spacing: 8) {
                if item.kind == .approval, let approval = item.approval {
                    Label(item.title ?? String(localized: "Waiting for approval"), systemImage: "hand.raised.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail).font(.caption.monospaced()).lineLimit(3).foregroundStyle(theme.secondaryInk)
                    }
                    if approval.acceptsText {
                        TextField(approval.textPlaceholder ?? String(localized: "Add a note"), text: $note, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                    }
                    ApprovalButtons(approval: approval) { option in
                        let text = note.isEmpty ? nil : note
                        note = ""
                        Task { await client.perform(.respond(threadID: model.id, itemID: item.id, optionID: option.id, text: text)) }
                    }
                } else {
                    Label(item.questions?.questions.first?.prompt ?? String(localized: "The agent has a question"), systemImage: "questionmark.bubble.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                    HStack {
                        Button("Answer…") { answering = item }.buttonStyle(.glassProminent)
                        Button("Dismiss") {
                            Task { await client.perform(.dismissQuestion(threadID: model.id, itemID: item.id)) }
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 18))
            .sheet(item: $answering) { item in QuestionForm(item: item, threadID: model.id) }
        }
    }
}

/// Answers an agent's questions.
struct QuestionForm: View {
    let item: RemoteItem
    let threadID: UUID
    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [String: Set<String>] = [:]
    @State private var typed: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                ForEach(item.questions?.questions ?? []) { question in
                    Section {
                        ForEach(question.options, id: \.label) { option in
                            Button {
                                toggle(option.label, in: question)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(option.label)
                                        if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    if picked[question.id]?.contains(option.label) == true {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(picked[question.id]?.contains(option.label) == true ? .isSelected : [])
                        }
                        if question.allowsFreeText {
                            if question.isSecret {
                                SecureField("Answer", text: binding(question.id))
                            } else {
                                TextField("Answer", text: binding(question.id), axis: .vertical)
                            }
                        }
                    } header: {
                        Text(question.header ?? "")
                    } footer: {
                        Text(question.prompt)
                    }
                }
            }
            .navigationTitle(item.questions?.title ?? String(localized: "Question"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task {
                            await client.perform(.answer(threadID: threadID, itemID: item.id, answers: answers))
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
    }

    private var answers: [String: [String]] {
        var result: [String: [String]] = [:]
        for question in item.questions?.questions ?? [] {
            var values = Array(picked[question.id] ?? [])
            if let text = typed[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { values.append(text) }
            result[question.id] = values
        }
        return result
    }

    private func toggle(_ label: String, in question: RemoteQuestionSet.Question) {
        var set = picked[question.id] ?? []
        if set.contains(label) {
            set.remove(label)
        } else {
            if !question.allowsMultipleSelection { set = [] }
            set.insert(label)
        }
        picked[question.id] = set
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { typed[id] ?? "" }, set: { typed[id] = $0 })
    }
}
