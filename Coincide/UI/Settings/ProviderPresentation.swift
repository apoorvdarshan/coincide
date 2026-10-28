import AppKit
import CoincideKit
import SwiftUI

/// How a provider's status reads in the sidebar and on its page.
struct SettingsProviderStatus {
    let headline: String
    let color: Color

    init(model: SettingsModel, kind: ProviderKind) {
        let status = model.status(kind)
        if !model.isEnabled(kind) {
            headline = String(localized: "Off")
            color = Color(nsColor: .tertiaryLabelColor)
        } else if model.isChecking(kind) && status.state == .unknown {
            headline = String(localized: "Checking…")
            color = Color(nsColor: .tertiaryLabelColor)
        } else {
            switch status.state {
            case .ready:
                headline = String(localized: "Ready")
                color = .green
            case .notAuthenticated:
                headline = String(localized: "Not signed in")
                color = .orange
            case .notInstalled:
                headline = String(localized: "Not installed")
                color = Color(nsColor: .tertiaryLabelColor)
            case .error:
                headline = String(localized: "Unavailable")
                color = .red
            case .unknown:
                headline = String(localized: "Not checked")
                color = Color(nsColor: .tertiaryLabelColor)
            }
        }
    }
}

nonisolated enum SettingsFormat {
    /// "v1.2.3" for semantic versions, dates for Antigravity's build ids, the raw string otherwise.
    static func version(_ version: String?) -> String? {
        guard let version = version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else { return nil }
        if let match = version.wholeMatch(of: /agy_acp_server_(\d{4})(\d{2})(\d{2})_\d+(?:_(\w+))?/) {
            let date = "\(match.1)-\(match.2)-\(match.3)"
            return match.4.map { "\(date) \($0)" } ?? date
        }
        return version.first?.isNumber == true ? "v\(version)" : version
    }

    /// "200K" / "1M" tokens.
    static func contextWindow(_ tokens: Int?) -> String? {
        guard let tokens, tokens > 0 else { return nil }
        return tokens.formatted(.number.notation(.compactName))
    }

    /// Display name for a reasoning effort id such as "xhigh".
    static func effort(_ effort: String) -> String {
        switch effort.lowercased() {
        case "none": String(localized: "None")
        case "auto": String(localized: "Auto")
        case "minimal": String(localized: "Minimal")
        case "low": String(localized: "Low")
        case "medium": String(localized: "Medium")
        case "high": String(localized: "High")
        case "xhigh", "extra-high", "extra_high": String(localized: "Extra High")
        case "max", "maximum": String(localized: "Max")
        default: effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }

    /// "1 hour", "30 minutes".
    static func minutes(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }
}

/// Install and sign-in commands for a provider CLI, shown when it needs setting up.
struct ProviderSetupGuide {
    struct Command: Identifiable, Hashable {
        enum Purpose {
            case install
            case signIn
            case other
        }

        let purpose: Purpose
        let text: String

        var id: String { text }

        var label: String {
            switch purpose {
            case .install: String(localized: "Install")
            case .signIn: String(localized: "Sign in")
            case .other: String(localized: "Run")
            }
        }
    }

    let commands: [Command]
    let website: URL?
    /// What to do after running the commands, when the CLI needs more than a command.
    let note: String?

    /// Combines the provider's own hint (its `backticked` commands) with known install commands.
    /// With an executable override, sign-in commands call that executable instead of the PATH name.
    init(kind: ProviderKind, hint: String, executableNames: [String], executableOverride: String?) {
        let known = Self.known(kind)
        var commands = known.install.map { [Command(purpose: .install, text: $0)] } ?? []
        let hinted = hint.matches(of: /`([^`]+)`/).map { String($0.1) }
        for raw in hinted + (known.signIn.map { [$0] } ?? []) {
            let text = Self.substituting(executableOverride, in: raw, names: executableNames)
            guard !commands.contains(where: { $0.text == text }) else { continue }
            let words = raw.split(separator: " ")
            let purpose: Command.Purpose =
                words.contains("install") || raw.hasPrefix("curl ") ? .install
                : words.contains("login") || words.contains("auth") ? .signIn : .other
            commands.append(Command(purpose: purpose, text: text))
        }
        self.commands = commands.filter { $0.purpose == .install } + commands.filter { $0.purpose != .install }
        website = known.website
        note = known.note
    }

    private static func substituting(_ executable: String?, in command: String, names: [String]) -> String {
        guard let executable, !executable.isEmpty, let first = command.split(separator: " ").first,
            names.contains(String(first))
        else { return command }
        let quoted = executable.range(of: #"^[A-Za-z0-9_./~-]+$"#, options: .regularExpression) != nil
            ? executable : "'" + executable.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
        return quoted + command.dropFirst(first.count)
    }

    private static func known(_ kind: ProviderKind) -> (install: String?, signIn: String?, website: URL?, note: String?) {
        switch kind {
        case .claude:
            ("curl -fsSL https://claude.ai/install.sh | bash", "claude auth login",
             URL(string: "https://claude.com/product/claude-code"), nil)
        case .codex:
            ("curl -fsSL https://chatgpt.com/codex/install.sh | sh", "codex login",
             URL(string: "https://developers.openai.com/codex/cli"), nil)
        case .cursor:
            ("curl https://cursor.com/install -fsS | bash", "cursor-agent login", URL(string: "https://cursor.com/cli"), nil)
        case .grok:
            (nil, "grok login", URL(string: "https://x.ai/cli"), nil)
        case .opencode:
            ("curl -fsSL https://opencode.ai/install | bash", "opencode auth login", URL(string: "https://opencode.ai"), nil)
        case .pi:
            ("npm install -g --ignore-scripts @earendil-works/pi-coding-agent", nil,
             URL(string: "https://www.npmjs.com/package/@earendil-works/pi-coding-agent"),
             String(localized: "To sign in, run `pi` in Terminal and type `/login`."))
        case .antigravity:
            (nil, nil, URL(string: "https://antigravity.google"),
             String(localized: "Install Antigravity, open it once and sign in with your Google account."))
        case .fx:
            ("curl -fsSL https://fx.sh/setup.sh | bash", "fx login", URL(string: "https://fx.sh"), nil)
        }
    }

    /// Opens Terminal and runs the command there, so the user can follow any prompts. Terminal starts the
    /// script from the user's interactive shell, so it inherits their full PATH.
    static func runInTerminal(_ command: String) {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("coincide-setup-\(UUID().uuidString.prefix(8)).command")
        let echoed = "'" + command.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        let body = "#!/bin/sh\nrm -f \"$0\"\nclear\nprintf '$ %s\\n\\n' \(echoed)\n\(command)\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            NSSound.beep()
            return
        }
        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        if let terminal {
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(script)
        }
    }
}
