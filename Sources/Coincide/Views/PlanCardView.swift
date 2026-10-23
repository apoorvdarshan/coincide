import AppKit
import CoincideCore
import CoincideMarkdown
import SwiftUI

/// A proposed plan (Claude ExitPlanMode, Grok exit-plan, ACP plan content)
/// rendered as Markdown with T3's collapsed preview, Copy, Save to Workspace
/// and an Implement action that only fills an empty composer draft.
struct PlanCardView: View {
    let plan: String
    var workspacePath: String?
    @Binding var expanded: Bool
    var canImplement = false
    var implement: ((String) -> Void)?
    var save: ((String, String) async throws -> Void)?
    var openFile: (URL, Int?) -> Void = { _, _ in }
    @State private var savePrompt = false
    @State private var savePath = ""
    @State private var saving = false
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
                        .disabled(save == nil || workspacePath == nil || saving)
                    if let implement {
                        Divider()
                        Button("Implement Plan") { implement(plan); status = String(localized: "Added an implementation request to the composer.") }
                            .disabled(!canImplement)
                            .help(canImplement ? String(localized: "Insert a request to implement this plan into the composer without sending it.")
                                  : String(localized: "Clear the composer draft first."))
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Plan actions").accessibilityIdentifier("plan-actions")
            }
            MarkdownView(collapsed ? TranscriptPlanText.collapsedPreview(plan) : TranscriptPlanText.displayed(plan),
                         workspace: workspacePath.map { URL(fileURLWithPath: $0) }, openFile: openFile)
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
        .alert("Save Plan to Workspace", isPresented: $savePrompt) {
            TextField("Path in workspace", text: $savePath)
            Button("Save") { Task { await write() } }.disabled(savePath.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { Text("Enter a path relative to the workspace. An existing file is never replaced.") }
    }

    private func copy() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(TranscriptPlanText.exportContents(plan), forType: .string)
        status = String(localized: "Copied the plan.")
    }

    private func write() async {
        let path = savePath.trimmingCharacters(in: .whitespaces)
        guard let save, !path.isEmpty, !saving else { return }
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { status = String(localized: "Enter a path inside the workspace."); return }
        saving = true; defer { saving = false }
        do { try await save(path, TranscriptPlanText.exportContents(plan)); status = String(localized: "Saved the plan to \(path).") }
        catch { status = String(localized: "Could not save the plan: \(error.localizedDescription)") }
    }
}
