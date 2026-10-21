import CoincideCore
import SwiftUI

struct NewProjectSheet: View {
    var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var creating = false
    @State private var created: ManagedProjectCreationResult?
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var destination: URL {
        store.managedProjectsRoot.appendingPathComponent(ManagedProjectService.folderName(for: name.trimmingCharacters(in: .whitespacesAndNewlines)), isDirectory: true)
    }
    private var validationError: String? {
        do { _ = try ManagedProjectService.validatedName(name); return nil }
        catch { return GitService.redactURLs(error.localizedDescription) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let created {
                CreatedProjectWarning(result: created)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New Project").font(.title2.weight(.semibold))
                    Text("Start a local project with Git already set up.").foregroundStyle(.secondary)
                }
                Form {
                    TextField("Project name", text: $name).focused($nameFocused).autocorrectionDisabled()
                        .accessibilityIdentifier("new-project-name")
                        .accessibilityHint("The name shown in your projects sidebar")
                    LabeledContent("Location") {
                        Text(destination.path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(destination.path)
                    }
                }
                .textFieldStyle(.roundedBorder).disabled(creating)
                Text("Coincide creates the project folder and opens its first conversation.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("The folder name is adjusted if it’s already in use.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let validationError {
                    Text(validationError).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                if creating { ProgressView().controlSize(.small).accessibilityLabel("Creating project") }
                Spacer()
                if created != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("project-created-done")
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating)
                    Button(creating ? "Creating…" : "Create Project", action: create)
                        .accessibilityIdentifier("create-project")
                        .keyboardShortcut(.defaultAction).disabled(creating || validationError != nil)
                }
            }
        }
        .padding(24).frame(width: 500)
        .interactiveDismissDisabled(creating)
        .onAppear { nameFocused = true }
        .onChange(of: name) { error = nil }
    }

    private func create() {
        guard !creating, created == nil else { return }
        if let problem = validationError { error = problem; return }
        let requestedName = name
        creating = true; error = nil; nameFocused = false
        Task {
            defer { creating = false }
            do {
                let result = try await store.createManagedProject(name: requestedName)
                if result.commitWarning != nil { created = result }
                else { dismiss() }
            } catch {
                self.error = GitService.redactURLs(error.localizedDescription)
            }
        }
    }
}

struct CreatedProjectWarning: View {
    let result: ManagedProjectCreationResult
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Project Created", systemImage: "checkmark.circle").font(.title2.weight(.semibold))
            Text("Your project is ready. Its initial Git commit needs attention.").foregroundStyle(.secondary)
            Text(result.project.path).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let warning = result.commitWarning {
                ScrollView(.vertical) {
                    Label(GitService.redactURLs(warning), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 140)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
