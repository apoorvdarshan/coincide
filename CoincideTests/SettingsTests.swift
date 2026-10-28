import CoincideKit
import Foundation
import Testing

@testable import Coincide

/// How Settings writes versions, context windows, efforts and durations.
struct SettingsFormatTests {
    @Test func versionsGetAVPrefixAndAntigravityBuildsReadAsDates() {
        #expect(SettingsFormat.version(nil) == nil)
        #expect(SettingsFormat.version("  \n") == nil)
        #expect(SettingsFormat.version("2.1.3") == "v2.1.3")
        #expect(SettingsFormat.version(" 1.0 ") == "v1.0")
        #expect(SettingsFormat.version("nightly-2026") == "nightly-2026")
        #expect(SettingsFormat.version("agy_acp_server_20261015_42") == "2026-10-15")
        #expect(SettingsFormat.version("agy_acp_server_20261015_42_beta") == "2026-10-15 beta")
    }

    @Test func contextWindowsAreCompactAndOnlyForKnownSizes() {
        #expect(SettingsFormat.contextWindow(nil) == nil)
        #expect(SettingsFormat.contextWindow(0) == nil)
        #expect(SettingsFormat.contextWindow(-5) == nil)
        #expect(SettingsFormat.contextWindow(200_000) == 200_000.formatted(.number.notation(.compactName)))
        #expect(SettingsFormat.contextWindow(1_000_000) != SettingsFormat.contextWindow(200_000))
    }

    @Test func effortIDsReadAsNames() {
        #expect(SettingsFormat.effort("none") == "None")
        #expect(SettingsFormat.effort("XHIGH") == "Extra High")
        #expect(SettingsFormat.effort("extra-high") == "Extra High")
        #expect(SettingsFormat.effort("max") == "Max")
        #expect(SettingsFormat.effort("ultra") == "Ultra")
    }

    @Test func minutesReadAsHoursAndMinutes() {
        #expect(SettingsFormat.minutes(60).contains("hour"))
        #expect(SettingsFormat.minutes(30).contains("30"))
        #expect(!SettingsFormat.minutes(30).contains("hour"))
        #expect(SettingsFormat.minutes(90).contains("30") && SettingsFormat.minutes(90).contains("hour"))
    }
}

/// The install and sign-in commands Settings offers for a missing or signed-out agent.
struct ProviderSetupGuideTests {
    @Test func knownInstallCommandsComeFirstAndHintsAddTheRest() {
        let guide = ProviderSetupGuide(
            kind: .claude, hint: "Install Claude Code and run `claude auth login`.", executableNames: ["claude"], executableOverride: nil)
        #expect(guide.commands.map(\.text) == ["curl -fsSL https://claude.ai/install.sh | bash", "claude auth login"])
        #expect(guide.commands.map(\.purpose) == [.install, .signIn])
        #expect(guide.commands.map(\.label) == ["Install", "Sign in"])
        #expect(guide.website?.host == "claude.com")
        #expect(guide.note == nil)
    }

    @Test func hintedCommandsAreClassifiedAndInstallsMoveToTheFront() {
        let guide = ProviderSetupGuide(
            kind: .grok, hint: "Run `grok doctor`, then `grok login`, or reinstall with `curl -fsSL https://x.ai/cli/install.sh | bash`.",
            executableNames: ["grok"], executableOverride: nil)
        #expect(guide.commands.map(\.text) == ["curl -fsSL https://x.ai/cli/install.sh | bash", "grok doctor", "grok login"])
        #expect(guide.commands.map(\.purpose) == [.install, .other, .signIn])
        #expect(guide.commands.map(\.label) == ["Install", "Run", "Sign in"])
    }

    @Test func signInCommandsUseTheExecutableTheUserChose() {
        func signIn(_ override: String?) -> String? {
            ProviderSetupGuide(kind: .codex, hint: "", executableNames: ["codex"], executableOverride: override)
                .commands.first { $0.purpose == .signIn }?.text
        }
        #expect(signIn(nil) == "codex login")
        #expect(signIn("") == "codex login")
        #expect(signIn("/opt/homebrew/bin/codex") == "/opt/homebrew/bin/codex login")
        #expect(signIn("/Users/me/My Tools/codex") == "'/Users/me/My Tools/codex' login")
        #expect(signIn("/tmp/it's/codex") == #"'/tmp/it'"'"'s/codex' login"#)
        // The install command never runs the override.
        let install = ProviderSetupGuide(kind: .codex, hint: "", executableNames: ["codex"], executableOverride: "/x/codex").commands.first
        #expect(install?.text.hasPrefix("curl ") == true)
    }

    @Test func agentsWithoutCommandsExplainWhatToDo() {
        let antigravity = ProviderSetupGuide(kind: .antigravity, hint: "", executableNames: [], executableOverride: nil)
        #expect(antigravity.commands.isEmpty)
        #expect(antigravity.note != nil)
        #expect(antigravity.website != nil)
        let pi = ProviderSetupGuide(kind: .pi, hint: "", executableNames: ["pi"], executableOverride: nil)
        #expect(pi.commands.map(\.purpose) == [.install])
        #expect(pi.note?.contains("/login") == true)
    }

    @Test func museSignsInWithItsLoginAndExplainsAPIKeys() {
        let muse = ProviderSetupGuide(
            kind: .muse, hint: MuseProvider().setupHint, executableNames: ["muse"], executableOverride: "/opt/muse/bin/muse")
        #expect(muse.commands.map(\.text) == ["/opt/muse/bin/muse login"])
        #expect(muse.commands.map(\.purpose) == [.signIn])
        #expect(muse.website?.host() == "dev.meta.ai")
        #expect(muse.note?.contains("META_API_KEY") == true)
    }
}

/// Settings' model edits, against a store of its own and a registry that never runs an agent.
struct SettingsModelTests {
    private let folder = TemporaryDirectory("settings")
    private let store: AppStore
    private let registry: ProviderRegistry
    private let model: SettingsModel

    init() {
        store = AppStore(directory: folder.url)
        registry = ProviderRegistry(store: store, providers: [ClaudeProvider()])
        model = SettingsModel(store: store, registry: registry)
    }

    @Test func customModelIDsAreCheckedBeforeTheyAreAdded() {
        registry.updateModels([ModelOption(provider: .claude, modelID: "opus", displayName: "Opus")], for: .claude)
        #expect(model.addCustomModel("   ", to: .claude) == "Enter a model ID.")
        #expect(model.addCustomModel("my model", to: .claude) == "Model IDs can’t contain spaces.")
        #expect(model.addCustomModel(String(repeating: "m", count: 257), to: .claude) == "Model IDs must be 256 characters or fewer.")
        #expect(model.addCustomModel("opus", to: .claude) == "Claude Code already offers that model.")
        #expect(model.addCustomModel("  sonnet-next \n", to: .claude) == nil)
        #expect(store.settings.settings(for: .claude).customModels == ["sonnet-next"])
        #expect(model.addCustomModel("sonnet-next", to: .claude) == "That custom model is already added.")
        // Added models appear in the picker after the discovered ones.
        #expect(model.models[.claude]?.map(\.modelID) == ["opus", "sonnet-next"])
        model.removeCustomModel("sonnet-next", from: .claude)
        #expect(store.settings.settings(for: .claude).customModels.isEmpty)
    }

    @Test func aNewDefaultModelKeepsTheEffortWhenItAcceptsIt() {
        store.updateSettings { $0.defaultSelection = ModelSelection(provider: .claude, modelID: "a", effort: "high") }
        model.setDefaultModel(ModelOption(provider: .codex, modelID: "b", displayName: "B", efforts: ["low", "high"]))
        #expect(store.settings.defaultSelection == ModelSelection(provider: .codex, modelID: "b", effort: "high"))
        model.setDefaultModel(ModelOption(provider: .claude, modelID: "c", displayName: "C", efforts: ["low"]))
        #expect(store.settings.defaultSelection == ModelSelection(provider: .claude, modelID: "c", effort: nil))
        #expect(model.settings.defaultSelection.modelID == "c")
    }

    @Test func providerSwitchesWriteThroughWithoutCheckingAgain() {
        #expect(model.isEnabled(.claude))
        model.updateProvider(.claude, recheck: false) { $0.isEnabled = false }
        #expect(!store.settings.settings(for: .claude).isEnabled)
        #expect(!model.isEnabled(.claude))
        #expect(!model.isChecking(.claude))
        #expect(model.kinds == [.claude])
        #expect(model.status(.claude).state == .unknown)
    }
}
