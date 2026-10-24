import AppKit
import CoincideCore
import CoincideMarkdown
import SwiftUI

/// A proposed plan (Claude ExitPlanMode)
/// rendered as Markdown with T3's collapsed preview, Copy, Save to Workspace
/// and an explicit Implement action admitted by the owning conversation.
struct PlanCardView: View {
    @AppStorage("renderMathInMarkdown") private var renderMathInMarkdown = false
    let plan: String
    var workspacePath: String?
    @Binding var expanded: Bool
    var canImplement = false
    var canImplementInNewConversation = false
    var implement: ((String) async -> Bool)?
    var implementInNewConversation: ((String) async -> Bool)?
    var save: ((String, String) async throws -> Void)?
    var saveAvailable: Bool? = nil
    var openFile: (URL, Int?) -> Void = { _, _ in }
    @State private var savePrompt = false
    @State private var savePath = ""
    @State private var saving = false
    @State private var implementing = false
    @State private var actionGeneration = UUID()
    @State private var status: String?

    var body: some View {
        let title = TranscriptPlanText.title(plan) ?? String(localized: "Proposed plan")
        let collapsible = TranscriptPlanText.canCollapse(plan)
        let collapsed = collapsible && !expanded
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Plan").font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                Text(title).font(.headline).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                Spacer(minLength: 8)
                Menu {
                    Button("Copy Plan") { copy() }
                    Button("Save to Workspace…") { savePath = TranscriptPlanText.filename(plan); status = nil; savePrompt = true }
                        .disabled(save == nil || !(saveAvailable ?? (workspacePath != nil)) || saving || implementing)
                    if implement != nil {
                        Divider()
                        Button(implementing ? "Starting Implementation…" : "Implement Plan") {
                            guard canImplement, !implementing, !saving else { return }
                            implementing = true; status = nil
                            let owner = actionGeneration
                            Task {
                                let started = await requestImplementation()
                                guard owner == actionGeneration else { return }
                                implementing = false
                                status = started ? String(localized: "Implementation started.")
                                    : String(localized: "Implementation could not be confirmed. Inspect the conversation before taking another action.")
                            }
                        }
                            .disabled(!canImplement || implementing || saving)
                            .help(canImplement ? String(localized: "Start an implementation turn in this conversation using its current settings.")
                                  : String(localized: "Implementation is unavailable while the conversation or draft needs attention."))
                    }
                    if implementInNewConversation != nil {
                        Button(implementing ? "Starting Implementation…" : "Implement in New Conversation") {
                            guard canImplementInNewConversation, !implementing, !saving else { return }
                            implementing = true; status = nil
                            let owner = actionGeneration
                            Task {
                                let started = await requestImplementationInNewConversation()
                                guard owner == actionGeneration else { return }
                                implementing = false
                                status = started ? String(localized: "Implementation accepted in a new conversation.")
                                    : String(localized: "The new implementation could not be confirmed. Inspect the conversation before taking another action.")
                            }
                        }
                        .disabled(!canImplementInNewConversation || implementing || saving)
                        .help("Start with fresh provider context and the current settings. This conversation's draft and attachments stay here.")
                        .accessibilityIdentifier("plan-implement-new-conversation")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Plan actions").accessibilityIdentifier("plan-actions")
            }
            MarkdownView(collapsed ? TranscriptPlanText.collapsedPreview(plan) : TranscriptPlanText.displayed(plan),
                         workspace: workspacePath.map { URL(fileURLWithPath: $0) }, mathEnabled: renderMathInMarkdown, openFile: openFile)
                .mask {
                    if collapsed {
                        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    } else { Rectangle() }
                }
            if collapsible {
                Button(expanded ? String(localized: "Collapse Plan") : String(localized: "Expand Plan")) { expanded.toggle() }
                    .controlSize(.small).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("plan-expand")
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.09)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Proposed plan: \(title)"))
        .accessibilityIdentifier("plan-card")
        .onChange(of: Data(plan.utf8)) { _, _ in actionGeneration = UUID(); saving = false; implementing = false; status = nil }
        .onDisappear { actionGeneration = UUID(); saving = false; implementing = false; status = nil }
        .alert("Save Plan to Workspace", isPresented: $savePrompt) {
            TextField("Path in workspace", text: $savePath)
            Button("Save") { Task { await write() } }.disabled(savePath.trimmingCharacters(in: .whitespaces).isEmpty || saving || implementing)
            Button("Cancel", role: .cancel) {}
        } message: { Text("Enter a path relative to the workspace. An existing file is never replaced.") }
    }

    private func copy() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(TranscriptPlanText.exportContents(plan), forType: .string)
        status = String(localized: "Copied the plan.")
    }

    /// The owning scope performs the final atomic admission; rendering never
    /// invokes this callback, and a missing or disabled action is inert.
    func requestImplementation() async -> Bool {
        guard canImplement, let implement else { return false }
        return await implement(plan)
    }

    func requestImplementationInNewConversation() async -> Bool {
        guard canImplementInNewConversation, let implementInNewConversation else { return false }
        return await implementInNewConversation(plan)
    }

    private func write() async {
        let path = savePath.trimmingCharacters(in: .whitespaces)
        guard let save, saveAvailable ?? (workspacePath != nil), !path.isEmpty, !saving, !implementing else { return }
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { status = String(localized: "Enter a path inside the workspace."); return }
        let owner = actionGeneration
        saving = true; defer { if owner == actionGeneration { saving = false } }
        do {
            try await save(path, TranscriptPlanText.exportContents(plan))
            if owner == actionGeneration { status = String(localized: "Saved the plan to \(path).") }
        } catch { if owner == actionGeneration { status = String(localized: "Could not save the plan: \(error.localizedDescription)") } }
    }
}
