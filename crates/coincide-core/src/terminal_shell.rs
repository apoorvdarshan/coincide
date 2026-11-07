//! Coincide's Swift shell marker protocol, observed as bounded, untrusted metadata.
//! This observer never executes output, changes process cwd, opens files from OSC,
//! or replaces Alacritty's screen parser. Only 7-bit OSC (BEL/ST) is recognized;
//! DCS/SOS/PM/APC payloads and malformed/oversized strings cannot inject marks.
use serde::Serialize;

const MAX_OSC: usize = 32 * 1024;
const MAX_COMMAND: usize = 4096;
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ReportedDirectory {
    pub uri: String,
    pub path: String,
    pub host: String,
    pub source: &'static str,
    pub trusted: bool,
}
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Boundary {
    pub sequence: u64,
    pub kind: &'static str,
    pub exit_status: Option<i32>,
}
/// A progress report printed with OSC 9;4 (ConEmu's sequence, which brew,
/// cargo, winget and others use), shown on the terminal's tab.
#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Progress {
    pub state: ProgressState,
    /// 0 to 100, or None while indeterminate.
    pub percent: Option<u8>,
}
#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ProgressState {
    Normal,
    Error,
    Indeterminate,
    Paused,
}
impl Progress {
    /// Swift TerminalProgress.parse for an OSC 9 payload ("4;state;progress"):
    /// Some(None) removes the bar; None when the payload is not a report.
    fn parse(payload: &str) -> Option<Option<Self>> {
        let mut fields = payload.split(';');
        if fields.next()? != "4" {
            return None;
        }
        let code = fields.next()?.parse::<i32>().ok()?;
        let percent = fields
            .next()
            .and_then(|value| value.parse::<i64>().ok())
            .map(|value| value.clamp(0, 100) as u8);
        let progress = |state, percent| Some(Some(Self { state, percent }));
        match code {
            0 => Some(None),
            1 => progress(ProgressState::Normal, Some(percent.unwrap_or(0))),
            2 => progress(ProgressState::Error, percent),
            3 => progress(ProgressState::Indeterminate, None),
            4 => progress(ProgressState::Paused, percent),
            _ => None,
        }
    }
}
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ShellState {
    pub has_marks: bool,
    pub prompt_lines: usize,
    pub command: Option<String>,
    pub is_running: bool,
    pub exit_status: Option<i32>,
    pub cwd: Option<ReportedDirectory>,
    pub sequence: u64,
    pub last_boundary: Option<Boundary>,
    /// The newest progress report; the terminal clears it after a timeout.
    pub progress: Option<Progress>,
}
impl Default for ShellState {
    fn default() -> Self {
        Self {
            has_marks: false,
            prompt_lines: 1,
            command: None,
            is_running: false,
            exit_status: None,
            cwd: None,
            sequence: 0,
            last_boundary: None,
            progress: None,
        }
    }
}
impl ShellState {
    fn boundary(&mut self, kind: &'static str) {
        self.last_boundary = Some(Boundary {
            sequence: self.sequence,
            kind,
            exit_status: self.exit_status,
        });
    }
    fn apply(&mut self, bytes: &[u8]) -> Option<Mark> {
        let raw = std::str::from_utf8(bytes).ok()?;
        if raw.chars().any(char::is_control) {
            return None;
        }
        let (code, payload) = raw.split_once(';')?;
        if code == "9" {
            // Progress is not a shell boundary: it never advances `sequence`.
            self.progress = Progress::parse(payload)?;
            return Some(Mark::Progress);
        }
        let event = match code {
            "133" => {
                let mut fields = payload.split(';');
                let mark = fields.next()?;
                match mark {
                    "A" | "B" | "C" if fields.next().is_none() => match mark {
                        "A" => {
                            self.has_marks = true;
                            self.is_running = false;
                            Mark::Prompt
                        }
                        "B" => Mark::PromptEnd,
                        _ => {
                            self.is_running = true;
                            self.exit_status = None;
                            Mark::Start
                        }
                    },
                    "D" => {
                        let status = match fields.next() {
                            None => None,
                            Some(value) => Some(value.parse::<i32>().ok()?),
                        };
                        if fields.next().is_some() {
                            return None;
                        }
                        self.is_running = false;
                        self.exit_status = status;
                        Mark::End
                    }
                    _ => return None,
                }
            }
            "1337" => {
                if let Some(value) = payload.strip_prefix("CoincidePrompt=") {
                    self.prompt_lines = value.parse::<i64>().ok()?.clamp(1, 50) as usize;
                    Mark::PromptLines(self.prompt_lines)
                } else {
                    let value = payload.strip_prefix("CoincideCommand=")?;
                    let command = value.trim().chars().take(MAX_COMMAND).collect::<String>();
                    self.command = (!command.is_empty()).then_some(command);
                    Mark::Command(self.command.clone())
                }
            }
            "7" => {
                self.cwd = Some(directory(payload)?);
                Mark::Directory
            }
            _ => return None,
        };
        self.sequence = self.sequence.wrapping_add(1);
        match &event {
            Mark::Prompt => self.boundary("prompt"),
            Mark::PromptEnd => self.boundary("promptEnd"),
            Mark::Start => self.boundary("commandStart"),
            Mark::End => self.boundary("commandEnd"),
            _ => {}
        }
        Some(event)
    }
}
fn directory(value: &str) -> Option<ReportedDirectory> {
    if value.len() > 8192 || !value.get(..7)?.eq_ignore_ascii_case("file://") {
        return None;
    }
    let uri = url::Url::parse(value).ok()?;
    if uri.scheme() != "file"
        || !uri.username().is_empty()
        || uri.password().is_some()
        || uri.port().is_some()
        || uri.query().is_some()
        || uri.fragment().is_some()
    {
        return None;
    }
    let encoded = uri.path().as_bytes();
    let mut bytes = Vec::with_capacity(encoded.len());
    let mut index = 0;
    while index < encoded.len() {
        if encoded[index] == b'%' {
            let high = (*encoded.get(index + 1)? as char).to_digit(16)?;
            let low = (*encoded.get(index + 2)? as char).to_digit(16)?;
            bytes.push((high * 16 + low) as u8);
            index += 3;
        } else {
            bytes.push(encoded[index]);
            index += 1;
        }
    }
    let path = String::from_utf8(bytes).ok()?;
    if !path.starts_with('/') || path.chars().any(char::is_control) {
        return None;
    }
    // A remote host is retained and explicitly untrusted; never treat this as an
    // instruction to switch a local project/worktree or as filesystem identity.
    Some(ReportedDirectory {
        uri: uri.to_string(),
        path,
        host: uri.host_str().unwrap_or("localhost").into(),
        source: "osc7",
        trusted: false,
    })
}

#[derive(Clone, Debug)]
pub enum Mark {
    Prompt,
    PromptEnd,
    Start,
    End,
    PromptLines(usize),
    Command(Option<String>),
    Directory,
    /// An OSC 9;4 progress report (or its removal).
    Progress,
    Invalidate,
}
#[derive(Clone, Copy, Default)]
enum State {
    #[default]
    Ground,
    Escape,
    Osc,
    OscEscape,
    String,
    StringEscape,
    Csi,
}
#[derive(Default)]
pub struct ShellObserver {
    pub state: ShellState,
    scanner: State,
    buffer: Vec<u8>,
    discard: bool,
}
impl ShellObserver {
    pub fn advance(&mut self, bytes: &[u8]) {
        self.events(bytes);
    }
    /// Events carry the byte AFTER their terminator, so the main screen parser
    /// advances to exactly the same point before recording a grid anchor.
    pub fn events(&mut self, bytes: &[u8]) -> Vec<(usize, Mark)> {
        let mut events = vec![];
        for (index, &byte) in bytes.iter().enumerate() {
            if matches!(byte, 0x18 | 0x1a) {
                self.reset();
                continue;
            }
            let mut event = None;
            match self.scanner {
                State::Ground => {
                    if byte == 0x1b {
                        self.scanner = State::Escape;
                    }
                }
                State::Escape => match byte {
                    b']' => {
                        self.buffer.clear();
                        self.discard = false;
                        self.scanner = State::Osc;
                    }
                    b'[' => {
                        self.buffer.clear();
                        self.scanner = State::Csi;
                    }
                    b'P' | b'X' | b'^' | b'_' => self.scanner = State::String,
                    b'c' => {
                        event = Some(Mark::Invalidate);
                        self.reset();
                    }
                    0x1b => {}
                    _ => self.scanner = State::Ground,
                },
                State::Osc => match byte {
                    7 => event = self.finish(),
                    0x1b => self.scanner = State::OscEscape,
                    _ => {
                        if !self.discard {
                            if self.buffer.len() == MAX_OSC {
                                self.buffer.clear();
                                self.discard = true;
                            } else {
                                self.buffer.push(byte);
                            }
                        }
                    }
                },
                State::OscEscape => match byte {
                    b'\\' => event = self.finish(),
                    7 => self.reset(),
                    _ => {
                        self.discard = true;
                        self.buffer.clear();
                        self.scanner = State::Osc;
                    }
                },
                State::Csi => {
                    if (0x40..=0x7e).contains(&byte) {
                        let param = self.buffer.as_slice();
                        let alt = matches!(byte, b'h' | b'l')
                            && param.strip_prefix(b"?").is_some_and(|p| {
                                p.split(|b| *b == b';')
                                    .any(|n| matches!(n, b"47" | b"1047" | b"1049"))
                            });
                        if alt || (byte == b'J' && matches!(param, b"2" | b"3")) {
                            event = Some(Mark::Invalidate);
                        }
                        self.reset();
                    } else if byte == 0x1b {
                        self.buffer.clear();
                        self.scanner = State::Escape;
                    } else if self.buffer.len() < 128 {
                        self.buffer.push(byte);
                    } else {
                        self.discard = true;
                    }
                }
                State::String => {
                    if byte == 0x1b {
                        self.scanner = State::StringEscape;
                    }
                }
                State::StringEscape => {
                    self.scanner = match byte {
                        b'\\' => State::Ground,
                        0x1b => State::StringEscape,
                        _ => State::String,
                    }
                }
            }
            if let Some(event) = event {
                events.push((index + 1, event));
            }
        }
        events
    }
    fn finish(&mut self) -> Option<Mark> {
        let event = if self.discard {
            None
        } else {
            self.state.apply(&self.buffer)
        };
        self.reset();
        event
    }
    fn reset(&mut self) {
        self.scanner = State::Ground;
        self.buffer.clear();
        self.discard = false;
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Position {
    pub row: usize,
    pub col: usize,
}
#[derive(Clone, Debug)]
pub struct OutputAnchor {
    pub command: String,
    pub start: Option<Position>,
    pub prompt: Option<(Position, usize)>,
    pub end: Option<Position>,
}
#[derive(Default)]
pub struct Anchors {
    pub output: Option<OutputAnchor>,
    pub prompts: std::collections::VecDeque<Position>,
    prompt: Option<(Position, usize)>,
    pending: Option<String>,
    prompt_lines: usize,
}
impl Anchors {
    pub fn invalidate(&mut self) {
        *self = Self::default();
    }
    pub fn observe(&mut self, mark: Mark, position: Position) {
        match mark {
            Mark::Invalidate => self.invalidate(),
            Mark::Prompt => {
                // A redraw/backward prompt cannot leave marks referring to rows
                // it is about to overwrite. Keep only strictly earlier positions.
                if self.prompts.back().is_some_and(|last| *last >= position) {
                    self.output = None;
                    self.prompts.retain(|mark| *mark < position);
                }
                self.prompts.push_back(position);
                if self.prompts.len() > 256 {
                    self.prompts.pop_front();
                }
                if self.output.as_ref().is_some_and(|o| o.end.is_none()) {
                    self.output = None;
                }
                self.prompt = Some((position, self.prompt_lines.max(1)));
                self.pending = None;
            }
            Mark::PromptLines(lines) => {
                self.prompt_lines = lines;
                if let Some((_, count)) = &mut self.prompt {
                    *count = lines;
                }
            }
            Mark::Command(command) => self.pending = command,
            Mark::Start => {
                self.output = self.pending.clone().map(|command| OutputAnchor {
                    command,
                    start: Some(position),
                    prompt: None,
                    end: None,
                })
            }
            Mark::End => {
                if let Some(output) = self.output.as_mut().filter(|o| o.end.is_none()) {
                    output.end = Some(position);
                } else {
                    self.output = self.pending.clone().map(|command| OutputAnchor {
                        command,
                        start: None,
                        prompt: self.prompt,
                        end: Some(position),
                    });
                }
            }
            _ => {}
        }
    }
}

/// Integration files belong to one PTY, never HOME or a project's rc files.
/// A failure simply keeps the previous plain-shell launch behavior.
#[derive(Default)]
pub struct ShellLaunch {
    pub arguments: Vec<std::ffi::OsString>,
    pub environment: Vec<(std::ffi::OsString, std::ffi::OsString)>,
    #[cfg(unix)]
    directory: Option<std::path::PathBuf>,
    #[cfg(unix)]
    identity: Option<(u64, u64)>,
}
impl ShellLaunch {
    pub fn prepare(shell: &str, own_zdotdir: Option<std::ffi::OsString>) -> Self {
        #[cfg(unix)]
        {
            Self::private(shell, own_zdotdir).unwrap_or_default()
        }
        #[cfg(not(unix))]
        {
            let _ = (shell, own_zdotdir);
            Self::default()
        }
    }
    #[cfg(unix)]
    fn private(shell: &str, own_zdotdir: Option<std::ffi::OsString>) -> std::io::Result<Self> {
        use std::{
            fs,
            io::Write,
            os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
        };
        let name = std::path::Path::new(shell)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("");
        if !matches!(name, "zsh" | "bash") {
            return Ok(Self::default());
        }
        let path = std::env::temp_dir().join(format!("coincide-shell-{}", uuid::Uuid::new_v4()));
        fs::DirBuilder::new().mode(0o700).create(&path)?;
        let metadata = fs::symlink_metadata(&path)?;
        let mut launch = Self {
            directory: Some(path.clone()),
            identity: Some((metadata.dev(), metadata.ino())),
            arguments: vec![],
            environment: vec![],
        };
        let files = if name == "zsh" {
            vec![(".zshenv", ZSH_ENV), ("coincide.zsh", ZSH)]
        } else {
            vec![("coincide.bash", BASH)]
        };
        for (name, source) in files {
            let mut file = fs::OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(path.join(name))?;
            file.write_all(source.as_bytes())?;
        }
        if name == "zsh" {
            launch.arguments = vec!["-l".into(), "-i".into()];
            launch
                .environment
                .push(("ZDOTDIR".into(), path.into_os_string()));
            if let Some(original) = own_zdotdir {
                launch
                    .environment
                    .push(("COINCIDE_SHELL_USER_ZDOTDIR".into(), original));
                launch
                    .environment
                    .push(("COINCIDE_SHELL_HAS_ZDOTDIR".into(), "1".into()));
            }
        } else {
            launch.arguments = vec![
                "--rcfile".into(),
                path.join("coincide.bash").into_os_string(),
                "-i".into(),
            ];
        }
        Ok(launch)
    }
}
impl Drop for ShellLaunch {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let (Some(path), Some(identity)) = (&self.directory, self.identity) {
            use std::os::unix::fs::MetadataExt;
            if std::fs::symlink_metadata(path)
                .is_ok_and(|m| m.is_dir() && (m.dev(), m.ino()) == identity)
            {
                let _ = std::fs::remove_dir_all(path);
            }
        }
    }
}
// Ported from Swift ShellIntegration: zsh restores the original ZDOTDIR before
// sourcing the user's .zshenv. zsh then loads normal login/interactive files.
const ZSH_ENV: &str = r#"if [[ -n ${COINCIDE_SHELL_HAS_ZDOTDIR-} ]]; then
  builtin export ZDOTDIR="$COINCIDE_SHELL_USER_ZDOTDIR"
else
  builtin unset ZDOTDIR
fi
builtin unset COINCIDE_SHELL_HAS_ZDOTDIR COINCIDE_SHELL_USER_ZDOTDIR
{
  builtin typeset _coincide_file="${ZDOTDIR-$HOME}/.zshenv"
  [[ -r $_coincide_file ]] && builtin source -- "$_coincide_file"
} always {
  if [[ -o interactive && -z ${_coincide_integration-} ]]; then
    builtin source -- "${${(%):-%x}:A:h}/coincide.zsh"
  fi
  builtin unset _coincide_file
}
"#;
const ZSH: &str = r#"builtin typeset -g _coincide_integration=1
builtin typeset -gi _coincide_running=0
builtin autoload -Uz add-zsh-hook
_coincide_cwd() {
  builtin setopt localoptions nomultibyte
  builtin local LC_ALL=C value=$PWD char index
  builtin printf '\e]7;file://localhost'
  for ((index=1;index<=${#value};index++)); do
    char=${value[index]}
    case $char in
      [a-zA-Z0-9/_.~-]) builtin printf '%s' "$char" ;;
      *) builtin printf '%%%02X' "'$char" ;;
    esac
  done
  builtin printf '\a'
}
_coincide_precmd() {
  builtin local code=$?
  if (( _coincide_running )); then
    builtin printf '\e]133;D;%s\a' "$code"
    _coincide_running=0
  fi
  _coincide_cwd
  builtin local -a lines
  lines=("${(@f)${(%%)PS1}}")
  builtin printf '\e]133;A\a\e]1337;CoincidePrompt=%s\a' "${#lines}"
  return $code
}
_coincide_preexec() {
  builtin printf '\e]1337;CoincideCommand=%s\a\e]133;C\a' "${1//[[:cntrl:]]/ }"
  _coincide_running=1
}
add-zsh-hook precmd _coincide_precmd
add-zsh-hook preexec _coincide_preexec
"#;
// As in Swift, bash reads /etc/profile and the first readable login profile;
// the profile may load .bashrc itself. Preserve string AND array PROMPT_COMMAND.
const BASH: &str = r#"[ -r /etc/profile ] && . /etc/profile
for _coincide_file in ~/.bash_profile ~/.bash_login ~/.profile; do
  if [ -r "$_coincide_file" ]; then . "$_coincide_file"; break; fi
done
unset _coincide_file
_coincide_last_history=
_coincide_started=
_coincide_cwd() {
  local LC_ALL=C value=$PWD char index byte
  builtin printf '\e]7;file://localhost'
  for ((index=0;index<${#value};index++)); do
    char=${value:index:1}
    case $char in
      [a-zA-Z0-9/_.~-]) builtin printf '%s' "$char" ;;
      *)
        # bash 3.2 sign-extends high-bit character arguments; URI octets must
        # be exactly two hex digits rather than FFFFFFFFFFFFFFE7.
        builtin printf -v byte '%d' "'$char"
        builtin printf '%%%02X' "$(( byte & 255 ))"
        ;;
    esac
  done
  builtin printf '\a'
}
_coincide_prompt() {
  local code=$? entry lines command
  entry=$(HISTTIMEFORMAT= builtin history 1)
  if [ -n "$_coincide_started" ] && [ -n "$entry" ] && [ "$entry" != "$_coincide_last_history" ]; then
    command="${entry#*[0-9]  }"
    builtin printf '\e]1337;CoincideCommand=%s\a\e]133;D;%s\a' "${command//[[:cntrl:]]/ }" "$code"
  fi
  _coincide_last_history=$entry
  _coincide_started=1
  _coincide_cwd
  lines=${PS1//\\n/$'\n'}
  lines=${lines//[!$'\n']/}
  builtin printf '\e]133;A\a\e]1337;CoincidePrompt=%s\a' "$(( ${#lines} + 1 ))"
  return $code
}
if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]]; then
  PROMPT_COMMAND=(_coincide_prompt "${PROMPT_COMMAND[@]}")
else
  PROMPT_COMMAND="_coincide_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi
"#;

#[cfg(test)]
mod tests {
    use super::*;
    fn osc(value: &str) -> Vec<u8> {
        format!("\x1b]{value}\x07").into_bytes()
    }
    #[test]
    fn swift_zsh_and_delayed_bash_markers_keep_commands_status_and_prompt_height() {
        let mut shell = ShellObserver::default();
        shell.advance(&osc("133;A"));
        shell.advance(&osc("1337;CoincidePrompt=2"));
        shell.advance(&osc("1337;CoincideCommand= printf 'a;b' "));
        shell.advance(&osc("133;C"));
        assert!(shell.state.has_marks && shell.state.is_running);
        assert_eq!(shell.state.prompt_lines, 2);
        assert_eq!(shell.state.command.as_deref(), Some("printf 'a;b'"));
        shell.advance(&osc("133;D;1"));
        assert_eq!(shell.state.exit_status, Some(1));
        assert!(!shell.state.is_running);
        shell.advance(&osc("133;A"));
        shell.advance(&osc("1337;CoincideCommand=cd /tmp"));
        shell.advance(&osc("133;D;0"));
        assert_eq!(shell.state.command.as_deref(), Some("cd /tmp"));
        assert_eq!(shell.state.exit_status, Some(0));
        shell.advance(&osc("1337;CoincidePrompt=9999"));
        assert_eq!(shell.state.prompt_lines, 50);
        shell.advance(&osc("1337;CoincidePrompt=-3"));
        assert_eq!(shell.state.prompt_lines, 1);
    }
    #[test]
    fn osc_9_4_progress_reports_set_and_remove_the_bar_without_shell_boundaries() {
        let mut shell = ShellObserver::default();
        let report = |shell: &mut ShellObserver, value: &str| {
            let marks = shell.events(&osc(value));
            (marks.len(), shell.state.progress)
        };
        let progress = |state, percent| Some(Progress { state, percent });
        assert_eq!(
            report(&mut shell, "9;4;1;42"),
            (1, progress(ProgressState::Normal, Some(42)))
        );
        assert_eq!(
            report(&mut shell, "9;4;1"),
            (1, progress(ProgressState::Normal, Some(0)))
        );
        assert_eq!(
            report(&mut shell, "9;4;1;250"),
            (1, progress(ProgressState::Normal, Some(100)))
        );
        assert_eq!(
            report(&mut shell, "9;4;2;-5"),
            (1, progress(ProgressState::Error, Some(0)))
        );
        assert_eq!(
            report(&mut shell, "9;4;2"),
            (1, progress(ProgressState::Error, None))
        );
        assert_eq!(
            report(&mut shell, "9;4;3;70"),
            (1, progress(ProgressState::Indeterminate, None))
        );
        assert_eq!(
            report(&mut shell, "9;4;4;30"),
            (1, progress(ProgressState::Paused, Some(30)))
        );
        // Other OSC 9 payloads (notifications) and unknown states change nothing.
        for value in ["9;Build finished", "9;4;9;10", "9;4;x", "9;4"] {
            assert_eq!(
                report(&mut shell, value),
                (0, progress(ProgressState::Paused, Some(30))),
                "{value}"
            );
        }
        assert_eq!(report(&mut shell, "9;4;0"), (1, None));
        assert_eq!(shell.state.sequence, 0);
    }
    #[test]
    fn split_utf8_bel_and_st_markers_preserve_order_and_bounded_commands() {
        let bytes = format!(
            "\x1b]133;A\x1b\\\x1b]1337;CoincideCommand={}\x07",
            "界".repeat(5000)
        );
        let mut shell = ShellObserver::default();
        for byte in bytes.as_bytes() {
            shell.advance(&[*byte]);
        }
        assert_eq!(shell.state.command.as_ref().unwrap().chars().count(), 4096);
        assert_eq!(shell.state.sequence, 2);
    }
    #[test]
    fn untrusted_osc_cannot_execute_change_cwd_or_inject_inside_other_strings() {
        let mut shell = ShellObserver::default();
        for value in [
            "7;https://host/private",
            "7;file://user:password@host/tmp",
            "7;file:///tmp?query",
            "7;file:///tmp#fragment",
            "7;file:///tmp/%00",
            "7;file:///tmp/%1b",
            "7;file:///bad%xx",
            "133;D;bad",
            "133;C;extra",
            "1337;CoincidePrompt=bad",
            "1337;CoincideCommand=bad\nline",
            "1337;File=inline=1",
            "52;c;AAAA",
        ] {
            shell.advance(&osc(value));
        }
        assert_eq!(shell.state, ShellState::default());
        shell.advance(b"\x1bPtmux;\x1b\x1b]133;C\x07\x1b\\");
        shell.advance(b"\x1b]1337;CoincideCommand=bad\x18");
        shell.advance(b"\x1b]1337;CoincideCommand=\xff\x07");
        assert_eq!(shell.state, ShellState::default());
        let mut oversized = b"\x1b]1337;CoincideCommand=".to_vec();
        oversized.extend(std::iter::repeat_n(b'x', MAX_OSC + 1));
        oversized.extend_from_slice(b"\x1b]133;C\x07");
        shell.advance(&oversized);
        assert_eq!(shell.state, ShellState::default());
        assert!(shell.buffer.len() <= MAX_OSC);
        shell.advance(&osc("133;A"));
        assert!(shell.state.has_marks);
    }
    #[test]
    fn cwd_uri_is_decoded_for_display_only_with_remote_host_retained() {
        let mut shell = ShellObserver::default();
        shell.advance(&osc(
            "7;file://remote.example/tmp/sub%20dir%20%23%3F%25/%E7%95%8C",
        ));
        let cwd = shell.state.cwd.unwrap();
        assert_eq!(cwd.path, "/tmp/sub dir #?%/界");
        assert_eq!(cwd.host, "remote.example");
        assert!(!cwd.trusted);
        assert_eq!(cwd.source, "osc7");
    }
    #[test]
    fn anchors_are_invalidated_by_clear_reset_and_even_transient_alternate_screen() {
        let mut shell = ShellObserver::default();
        let mut anchors = Anchors::default();
        let position = Position { row: 2, col: 0 };
        for bytes in [osc("133;A"), osc("1337;CoincideCommand=ls"), osc("133;C")] {
            for (_, mark) in shell.events(&bytes) {
                anchors.observe(mark, position);
            }
        }
        assert!(anchors.output.is_some());
        for (_, mark) in shell.events(b"\x1b[?1049h\x1b[?1049l") {
            anchors.observe(mark, position);
        }
        assert!(anchors.output.is_none());
        assert!(matches!(
            shell.events(b"\x1b[3J").as_slice(),
            [(_, Mark::Invalidate)]
        ));
        assert!(matches!(
            shell.events(b"\x1bc").as_slice(),
            [(_, Mark::Invalidate)]
        ));
    }
    #[test]
    fn prompt_anchor_not_arbitrary_command_suffix_is_retained_for_delayed_bash_end() {
        let mut anchors = Anchors::default();
        anchors.observe(Mark::Prompt, Position { row: 2, col: 0 });
        anchors.observe(Mark::PromptLines(2), Position { row: 2, col: 0 });
        anchors.observe(
            Mark::Command(Some("ls".into())),
            Position { row: 8, col: 0 },
        );
        anchors.observe(Mark::End, Position { row: 8, col: 0 });
        anchors.observe(Mark::Prompt, Position { row: 8, col: 0 });
        let output = anchors.output.unwrap();
        assert_eq!(output.prompt, Some((Position { row: 2, col: 0 }, 2)));
        assert_eq!(output.end, Some(Position { row: 8, col: 0 }));
    }
    #[test]
    fn prompt_positions_are_bounded_deduplicated_and_revoked_with_other_anchors() {
        let mut anchors = Anchors::default();
        for row in 0..300 {
            anchors.observe(Mark::Prompt, Position { row, col: 0 });
        }
        assert_eq!(anchors.prompts.len(), 256);
        assert_eq!(anchors.prompts.front().unwrap().row, 44);
        anchors.observe(Mark::Prompt, Position { row: 299, col: 0 });
        assert_eq!(anchors.prompts.len(), 256);
        anchors.observe(Mark::Prompt, Position { row: 290, col: 0 });
        assert!(anchors.prompts.iter().all(|p| p.row <= 290));
        anchors.invalidate();
        assert!(anchors.prompts.is_empty());
    }
    #[cfg(unix)]
    #[test]
    fn launch_files_are_private_restore_original_zdotdir_and_drop_only_their_directory() {
        use std::os::unix::fs::PermissionsExt;
        let zsh = ShellLaunch::prepare("/bin/zsh", Some("/synthetic/original zsh".into()));
        let path = zsh.directory.as_ref().unwrap().clone();
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            std::fs::metadata(path.join(".zshenv"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert!(zsh.environment.contains(&(
            "COINCIDE_SHELL_USER_ZDOTDIR".into(),
            "/synthetic/original zsh".into()
        )));
        assert!(
            ZSH_ENV.find("source -- \"$_coincide_file\"").unwrap()
                < ZSH_ENV.find("coincide.zsh").unwrap()
        );
        drop(zsh);
        assert!(!path.exists());
        let bash = ShellLaunch::prepare("/bin/bash", None);
        let path = bash.directory.as_ref().unwrap().clone();
        assert_eq!(bash.arguments[0], "--rcfile");
        assert_eq!(bash.arguments[2], "-i");
        drop(bash);
        assert!(!path.exists());
        assert!(ShellLaunch::prepare("/bin/fish", None).directory.is_none());
    }
    #[cfg(unix)]
    #[test]
    fn cleanup_refuses_a_replaced_directory_identity() {
        let launch = ShellLaunch::prepare("/bin/bash", None);
        let path = launch.directory.as_ref().unwrap().clone();
        let moved = path.with_extension("original");
        std::fs::rename(&path, &moved).unwrap();
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("preserve"), "not our original directory").unwrap();
        drop(launch);
        assert!(path.join("preserve").exists());
        std::fs::remove_dir_all(path).unwrap();
        std::fs::remove_dir_all(moved).unwrap();
    }
}
