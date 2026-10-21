import AppKit
import CoincideCore
import SwiftUI

struct CloneRepositorySheet: View {
    var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var parent = FileManager.default.homeDirectoryForCurrentUser
    @State private var folderName = ""
    @State private var suggestedName = ""
    @State private var starting = false
    @State private var error: String?
    @FocusState private var sourceFocused: Bool

    private var destination: URL { parent.appendingPathComponent(folderName, isDirectory: true) }
    private var trimmedSource: String { source.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var formError: String? {
        if trimmedSource.isEmpty { return String(localized: "Enter a repository URL or local path.") }
        if folderName.isEmpty || folderName == "." || folderName == ".." || folderName.contains("/") || folderName.contains("\0") {
            return String(localized: "Enter a folder name without slashes.")
        }
        var directory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory) || !directory.boolValue {
            return String(localized: "Choose an existing parent folder.")
        }
        if (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil {
            return String(localized: "That folder already exists. Choose a new folder name.")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clone Repository").font(.title2.weight(.semibold))
                Text("Open a repository as a new project while it downloads.")
                    .foregroundStyle(.secondary)
            }
            Form {
                TextField("Repository", text: $source, prompt: Text("URL or local path"))
                    .focused($sourceFocused)
                    .autocorrectionDisabled()
                    .accessibilityHint("HTTPS, SSH, or a local Git repository")
                LabeledContent("Save in") {
                    HStack {
                        Text(parent.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            .help(parent.path)
                        Spacer(minLength: 8)
                        Button("Choose…", action: chooseParent)
                    }
                }
                TextField("Folder name", text: $folderName).autocorrectionDisabled()
            }
            .textFieldStyle(.roundedBorder)
            Text("Uses your existing Git credentials and SSH setup. Messages wait until the repository is ready.")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if !folderName.isEmpty, let problem = formError, !trimmedSource.isEmpty {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if starting { ProgressView().controlSize(.small).accessibilityLabel("Starting clone") }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(starting)
                Button(starting ? "Starting…" : "Clone Repository", action: start)
                    .keyboardShortcut(.defaultAction).disabled(starting || formError != nil)
            }
        }
        .padding(24).frame(width: 530)
        .interactiveDismissDisabled(starting)
        .onAppear { sourceFocused = true }
        .onChange(of: source) {
            let next = Self.folderName(for: trimmedSource)
            if folderName.isEmpty || folderName == suggestedName { folderName = next }
            suggestedName = next; error = nil
        }
        .onChange(of: folderName) { error = nil }
        .onChange(of: parent) { error = nil }
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.directoryURL = parent; panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a parent folder for the new repository.")
        panel.begin { response in
            if response == .OK, let url = panel.url { parent = url }
        }
    }

    private func start() {
        if let problem = formError { error = problem; return }
        let source = trimmedSource, destination = destination
        starting = true; error = nil
        Task {
            defer { starting = false }
            do {
                try await store.cloneRepository(source: source, destination: destination)
                dismiss()
            } catch {
                // The clone service returns a public error without credential-bearing Git output.
                self.error = error.localizedDescription
            }
        }
    }

    private static func folderName(for source: String) -> String {
        guard !source.isEmpty else { return "" }
        // Use only the final path component; URL usernames, queries, and fragments never become folder names.
        let path: String
        if let components = URLComponents(string: source), components.scheme != nil {
            path = components.path
        } else {
            path = source.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        }
        var result = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        if !result.contains("/"), let colon = result.lastIndex(of: ":") { result = String(result[result.index(after: colon)...]) }
        if result.hasSuffix(".git") { result.removeLast(4) }
        return result == "." || result == ".." ? "" : result
    }
}
