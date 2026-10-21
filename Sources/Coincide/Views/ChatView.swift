import CoincideCore
import SwiftUI

struct ChatView: View {
    @Bindable var store: WorkspaceStore
    let threadID: UUID
    @State private var draft = ""
    @State private var sending = false
    @State private var worktreeSheet = false
    @State private var branch = ""
    private var thread: CodingThread? { store.snapshot.threads.first { $0.id == threadID } }
    var body: some View {
        if let thread {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(thread.title).font(.headline).lineLimit(1)
                        Text(thread.workspacePath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer()
                    if thread.messages.isEmpty { Button("New Worktree…") { worktreeSheet = true } }
                }.padding()
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            if thread.messages.isEmpty {
                                ContentUnavailableView("What are we working on?", systemImage: "sparkle", description: Text("Codex uses its existing sign-in on this Mac. Choose a model and permission mode below."))
                                    .frame(maxWidth: .infinity).padding(.top, 70)
                            }
                            ForEach(thread.messages) { MessageView(message: $0) }
                            Color.clear.frame(height: 1).id("latest")
                        }.padding(24)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: thread.messages.count) { proxy.scrollTo("latest", anchor: .bottom) }
                }
                ForEach(store.approvals[threadID, default: []]) { request in
                    ApprovalView(request: request, onDecision: { allow in Task { await store.respond(request, threadID: threadID, allow: allow) } },
                                 onAnswer: { answers in Task { await store.answer(request, threadID: threadID, answers: answers) } })
                        .padding(.horizontal).padding(.bottom, 8)
                }
                Divider()
                ComposerView(text: $draft, models: store.models, model: thread.model, permission: thread.permission,
                             busy: store.isBusy(threadID) || sending,
                             setModel: { store.setModel($0, id: threadID) }, setPermission: { store.setPermission($0, id: threadID) },
                             refreshModels: { Task { await store.refreshModels() } },
                             send: {
                                 guard !sending else { return }; sending = true
                                 let prompt = draft
                                 Task { if await store.send(prompt, threadID: threadID), draft == prompt { draft = "" }; sending = false }
                             }, stop: { Task { await store.interrupt(threadID) } })
            }
            .navigationTitle(thread.title)
            .sheet(isPresented: $worktreeSheet) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Create a Worktree").font(.title2)
                    Text("Give this thread its own branch and working directory.").foregroundStyle(.secondary)
                    TextField("Branch name", text: $branch)
                    HStack { Spacer(); Button("Cancel") { worktreeSheet = false }; Button("Create") { worktreeSheet = false; Task { await store.createWorktree(for: threadID, branch: branch) } }.disabled(branch.isEmpty) }
                }.padding(24).frame(width: 430)
            }
        }
    }
}

private struct MessageView: View {
    let message: ChatMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(message.role == .assistant ? "Codex" : message.role.rawValue.capitalized, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy message")
            }
            if message.role == .tool || message.role == .reasoning {
                DisclosureGroup(message.role == .tool ? "Tool activity" : "Reasoning") {
                    Text(message.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
            } else {
                Text((try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(14).background(message.role == .user ? Color.accentColor.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }
    private var icon: String {
        switch message.role { case .user: "person"; case .assistant: "sparkles"; case .tool: "terminal"; case .system: "info.circle"; case .reasoning: "brain" }
    }
}
