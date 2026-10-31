import Foundation

/// Marks prompts and commands in Coincide's terminals (OSC 133), so the terminal can jump between commands and find
/// the last command's output. zsh loads it through a ZDOTDIR that restores the user's own and reads their .zshenv
/// first; bash starts interactive with an rc file that reads the login files a login shell would. The user's
/// dotfiles are never changed, and a shell starts as before when the files can't be written.
enum ShellIntegration {
    /// What the terminal launches: the executable's arguments, argv[0] and variables to add, for `shell`.
    struct Launch: Equatable {
        var arguments: [String]
        var execName: String
        var environment: [String: String]
    }

    /// The folder holding the integration files, beside Coincide's data.
    nonisolated static func folder(in store: URL) -> URL {
        store.appendingPathComponent("ShellIntegration", isDirectory: true)
    }

    /// How to start `shell` (a path) as a login shell with integration, writing the files it needs under `folder`.
    /// `environment` is the shell's inherited environment, for the user's own ZDOTDIR. Without integration (another
    /// shell, or files that can't be written) it is the plain login shell.
    nonisolated static func launch(shell: String, environment: [String: String], folder: URL) -> Launch {
        let name = (shell as NSString).lastPathComponent
        let plain = Launch(arguments: [], execName: "-" + name, environment: [:])
        switch name {
        case "zsh":
            let zsh = folder.appendingPathComponent("zsh", isDirectory: true)
            guard write([".zshenv": zshEnv, "coincide-integration.zsh": zshIntegration], to: zsh) else { return plain }
            var added = ["ZDOTDIR": zsh.path]
            if let own = environment["ZDOTDIR"], !own.isEmpty { added["COINCIDE_ZSH_ZDOTDIR"] = own }
            return Launch(arguments: [], execName: "-zsh", environment: added)
        case "bash":
            let bash = folder.appendingPathComponent("bash", isDirectory: true)
            guard write(["coincide-integration.bash": bashIntegration], to: bash) else { return plain }
            let rc = bash.appendingPathComponent("coincide-integration.bash").path
            return Launch(arguments: ["--rcfile", rc, "-i"], execName: "bash", environment: [:])
        default:
            return plain
        }
    }

    /// Writes each file whose contents differ, readable by the user only. False when any can't be written.
    private nonisolated static func write(_ files: [String: String], to folder: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (name, contents) in files {
                let url = folder.appendingPathComponent(name)
                if (try? String(contentsOf: url, encoding: .utf8)) == contents { continue }
                try Data(contents.utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: Scripts

    /// The OSC sequences, as the terminal reads them: 133;A starts a prompt, 133;C starts a command's output,
    /// 133;D;status ends it, and 1337;CoincidePrompt and 1337;CoincideCommand carry the prompt's height in lines and the
    /// command line (control characters removed) for finding a command's output.
    nonisolated static let zshEnv = #"""
        # Coincide's zsh integration, loaded through ZDOTDIR. It puts back the user's own ZDOTDIR, reads their .zshenv,
        # and in interactive shells adds the prompt marks from coincide-integration.zsh.
        if [[ -n "${COINCIDE_ZSH_ZDOTDIR+X}" ]]; then
          builtin export ZDOTDIR="$COINCIDE_ZSH_ZDOTDIR"
          builtin unset COINCIDE_ZSH_ZDOTDIR
        else
          builtin unset ZDOTDIR
        fi
        {
          builtin typeset _coincide_file="${ZDOTDIR-$HOME}/.zshenv"
          [[ -r "$_coincide_file" ]] && builtin source -- "$_coincide_file"
        } always {
          if [[ -o interactive && -z "${_coincide_integration-}" ]]; then
            builtin source -- "${${(%):-%x}:A:h}/coincide-integration.zsh"
          fi
          builtin unset _coincide_file
        }
        """#

    nonisolated static let zshIntegration = #"""
        # Prompt and command marks (OSC 133) for Coincide's terminal.
        builtin typeset -g _coincide_integration=1
        builtin typeset -gi _coincide_running=0
        builtin autoload -Uz add-zsh-hook

        _coincide_precmd() {
          builtin local code=$?
          if (( _coincide_running )); then
            builtin printf '\e]133;D;%s\a' "$code"
            _coincide_running=0
          fi
          builtin local -a lines
          lines=("${(@f)${(%%)PS1}}")
          builtin printf '\e]133;A\a\e]1337;CoincidePrompt=%s\a' "${#lines}"
        }

        _coincide_preexec() {
          builtin printf '\e]1337;CoincideCommand=%s\a\e]133;C\a' "${1//[[:cntrl:]]/ }"
          _coincide_running=1
        }

        add-zsh-hook precmd _coincide_precmd
        add-zsh-hook preexec _coincide_preexec
        """#

    nonisolated static let bashIntegration = #"""
        # Coincide's bash integration. Coincide starts bash as `bash --rcfile <this file> -i`, so it reads the login
        # files a login shell reads first, then adds prompt marks (OSC 133) for Coincide's terminal.
        [ -r /etc/profile ] && . /etc/profile
        for _coincide_file in ~/.bash_profile ~/.bash_login ~/.profile; do
          if [ -r "$_coincide_file" ]; then . "$_coincide_file"; break; fi
        done
        unset _coincide_file

        # The first prompt only notes the newest history entry, which may be the last session's.
        _coincide_last_history=
        _coincide_started=
        _coincide_prompt() {
          local code=$? entry lines
          entry=$(HISTTIMEFORMAT= builtin history 1)
          if [ -n "$_coincide_started" ] && [ -n "$entry" ] && [ "$entry" != "$_coincide_last_history" ]; then
            local command="${entry#*[0-9]  }"
            builtin printf '\e]1337;CoincideCommand=%s\a\e]133;D;%s\a' "${command//[[:cntrl:]]/ }" "$code"
          fi
          _coincide_last_history=$entry
          _coincide_started=1
          # The prompt's height: one line, plus one for each newline in PS1 (written \n or literally).
          lines=${PS1//\\n/$'\n'}
          lines=${lines//[!$'\n']/}
          builtin printf '\e]133;A\a\e]1337;CoincidePrompt=%s\a' "$(( ${#lines} + 1 ))"
          return $code
        }
        PROMPT_COMMAND="_coincide_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
        """#
}
