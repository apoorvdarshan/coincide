//! PTY fixtures only: no shell profile, desktop window, or original app data.
#![cfg(unix)]

use coincide_core::terminal::{Terminal, TerminalPoint, selected_text};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    thread,
    time::{Duration, Instant},
};
use tempfile::TempDir;

struct Fixture {
    terminal: Terminal,
    // Keep the script alive until after the PTY has been dropped.
    _dir: TempDir,
}

impl Fixture {
    fn new(rows: u16, cols: u16, phases: &[&str]) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("terminal-fixture");
        let mut source = String::from("#!/bin/sh\nstty -echo\n");
        for (index, phase) in phases.iter().enumerate() {
            if index != 0 {
                source.push_str("IFS= read -r step || exit\n");
            }
            // Octal encoding avoids shell interpolation and printf format expansion.
            let bytes = format!("{phase}\x1b]2;fixture-{index}\x07");
            let escaped: String = bytes.bytes().map(|b| format!("\\{b:03o}")).collect();
            source.push_str(&format!("printf '{escaped}'\n"));
        }
        source.push_str("IFS= read -r finish\n");
        fs::write(&script, source).unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
        let terminal = Terminal::spawn(dir.path(), script.to_str().unwrap(), rows, cols).unwrap();
        Self {
            terminal,
            _dir: dir,
        }
    }

    fn snapshot(&mut self, phase: usize) -> Value {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let snapshot = self.terminal.styled_snapshot(0, 10).unwrap();
            // OSC follows the complete fixture output, so an echoed command cannot
            // accidentally satisfy readiness and we need no fixed startup sleep.
            if snapshot["title"] == format!("fixture-{phase}") {
                return snapshot;
            }
            assert!(
                Instant::now() < deadline,
                "PTY fixture {phase} timed out: {snapshot}"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn next(&mut self, phase: usize) -> Value {
        self.terminal.write("next\n").unwrap();
        self.snapshot(phase)
    }
}

#[test]
fn ansi_styles_resolve_colors_and_reset_without_losing_blank_backgrounds() {
    let mut fixture = Fixture::new(
        4,
        20,
        &["\x1b[2J\x1b[H\x1b[31;44;1;3;4mA\x1b[7mB\x1b[0mC\x1b[48;2;4;5;6m \x1b[0m"],
    );
    let snapshot = fixture.snapshot(0);
    assert_eq!(snapshot["rows"], 4);
    assert_eq!(snapshot["cols"], 20);
    assert_eq!(snapshot["lines"][0], "ABC");
    let row = &snapshot["grid"][0];
    assert_eq!(row[0]["text"], "A");
    assert_eq!(row[0]["foreground"], json!([205, 49, 49]));
    assert_eq!(row[0]["background"], json!([36, 114, 200]));
    for style in ["bold", "italic", "underline"] {
        assert_eq!(row[0][style], true);
        assert_eq!(row[2][style], false);
    }
    assert_eq!(row[1]["inverse"], true);
    assert_eq!(row[1]["foreground"], row[0]["background"]);
    assert_eq!(row[1]["background"], row[0]["foreground"]);
    assert_eq!(row[2]["inverse"], false);
    assert_eq!(row[2]["foreground"], json!([212, 212, 212]));
    assert_eq!(row[2]["background"], json!([12, 12, 12]));
    assert_eq!(row[3]["text"], " ");
    assert_eq!(row[3]["background"], json!([4, 5, 6]));
    assert_eq!(row.as_array().unwrap().len(), 20);
    assert_eq!(snapshot["cursor"]["col"], 4);
}

#[test]
fn indexed_truecolor_palette_overrides_and_extended_styles() {
    let mut fixture = Fixture::new(
        3,
        20,
        &[
            "\x1b[2J\x1b[H\x1b[38;5;196;48;5;232mA\x1b[38;2;12;34;56;48;2;78;90;123mB\x1b[0;91;104mC\x1b[0;2;9mD\x1b[8mE\x1b[0;4:3mF\x1b[0m\x1b]4;1;rgb:01/02/03\x07\x1b[31mG",
        ],
    );
    let snapshot = fixture.snapshot(0);
    let row = &snapshot["grid"][0];
    assert_eq!(row[0]["foreground"], json!([255, 0, 0]));
    assert_eq!(row[0]["background"], json!([8, 8, 8]));
    assert_eq!(row[1]["foreground"], json!([12, 34, 56]));
    assert_eq!(row[1]["background"], json!([78, 90, 123]));
    assert_eq!(row[2]["foreground"], json!([241, 76, 76]));
    assert_eq!(row[2]["background"], json!([59, 142, 234]));
    assert_eq!(row[3]["dim"], true);
    assert_eq!(row[3]["strikethrough"], true);
    assert_eq!(row[3]["foreground"], json!([141, 141, 141]));
    assert_eq!(row[4]["hidden"], true);
    assert_eq!(row[4]["foreground"], row[4]["background"]);
    assert_eq!(row[5]["underline"], true);
    assert_eq!(row[6]["foreground"], json!([1, 2, 3]));
}

#[test]
fn cursor_visibility_position_shape_and_alternate_screen_restore() {
    let mut fixture = Fixture::new(
        6,
        20,
        &[
            "\x1b[2J\x1b[HMAIN\x1b[3;7H\x1b[?25l",
            "\x1b[?1049h\x1b[2J\x1b[HALT\x1b[4;9H\x1b[?25h\x1b[6 q",
            "\x1b[?1049l",
        ],
    );
    let first = fixture.snapshot(0);
    assert_eq!(first["cursor"]["row"], 2);
    assert_eq!(first["cursor"]["col"], 6);
    assert_eq!(first["cursor"]["visible"], false);
    let alternate = fixture.next(1);
    assert_eq!(alternate["lines"][0], "ALT");
    assert_eq!(alternate["cursor"]["row"], 3);
    assert_eq!(alternate["cursor"]["col"], 8);
    assert_eq!(alternate["cursor"]["visible"], true);
    assert_eq!(alternate["cursor"]["shape"], "beam");
    assert_eq!(alternate["cursor"]["blinking"], false);
    let restored = fixture.next(2);
    assert_eq!(restored["lines"][0], "MAIN");
    assert_eq!(restored["cursor"]["row"], 2);
    assert_eq!(restored["cursor"]["col"], 6);
    assert!(restored["revision"].as_u64().unwrap() > first["revision"].as_u64().unwrap());
}

#[test]
fn wide_and_combining_cells_preserve_columns_and_clip_excess_marks() {
    let phase = format!("\x1b[2J\x1b[H界e\u{301}X{}", "\u{301}".repeat(100));
    let mut fixture = Fixture::new(3, 20, &[&phase]);
    let snapshot = fixture.snapshot(0);
    let row = &snapshot["grid"][0];
    assert_eq!(row[0]["text"], "界");
    assert_eq!(row[0]["width"], 2);
    assert_eq!(row[1]["text"], "");
    assert_eq!(row[1]["width"], 0);
    assert_eq!(row[1]["continuation"], true);
    assert_eq!(row[2]["text"], "e\u{301}");
    assert_eq!(row[3]["text"].as_str().unwrap().chars().count(), 17);
    assert_eq!(snapshot["truncated"], true);
    assert_eq!(snapshot["cursor"]["col"], 4);
}

#[test]
fn maximum_viewport_pages_fit_control_frames_and_plain_reads_have_no_grid() {
    let mut fixture = Fixture::new(300, 500, &["\x1b[2J\x1b[H\x1b[48;2;255;128;64m\x1b[2J"]);
    let first = fixture.snapshot(0);
    assert_eq!(first["rows"], 300);
    assert_eq!(first["cols"], 500);
    assert_eq!(first["rowOffset"], 0);
    assert_eq!(first["rowCount"], 10);
    assert_eq!(first["nextRowOffset"], 10);
    let plain = fixture.terminal.snapshot().unwrap();
    assert!(plain.get("grid").is_none());
    assert!(plain.get("cursor").is_none());
    assert_eq!(plain["lines"].as_array().unwrap().len(), 300);
    assert!(serde_json::to_vec(&plain).unwrap().len() < 4 * 1024 * 1024);
    for offset in [0, 10, 290, 299, 300] {
        let page = fixture.terminal.styled_snapshot(offset, 10).unwrap();
        let count = 10.min(300 - offset);
        let grid = page["grid"].as_array().unwrap();
        assert_eq!(page["rowOffset"], offset);
        assert_eq!(grid.len(), count);
        assert_eq!(page["lines"].as_array().unwrap().len(), count);
        assert_eq!(page["truncated"], false);
        if offset + count == 300 {
            assert!(page["nextRowOffset"].is_null());
        }
        for row in grid {
            assert_eq!(row.as_array().unwrap().len(), 500);
            assert_eq!(row[499]["background"], json!([255, 128, 64]));
        }
        assert!(
            serde_json::to_vec(&json!({"id":"test","result":page}))
                .unwrap()
                .len()
                < 4 * 1024 * 1024
        );
    }
    for (offset, limit) in [(0, 0), (0, 11), (301, 1), (usize::MAX, 10), (0, usize::MAX)] {
        assert!(fixture.terminal.styled_snapshot(offset, limit).is_err());
    }
    fixture.terminal.resize(4, 12).unwrap();
    let resized = fixture.terminal.styled_snapshot(0, 10).unwrap();
    assert_eq!(resized["grid"].as_array().unwrap().len(), 4);
    assert!(
        resized["grid"]
            .as_array()
            .unwrap()
            .iter()
            .all(|row| row.as_array().unwrap().len() == 12)
    );
}

#[test]
fn maximum_styled_page_with_combining_text_fits_four_mib() {
    let cell = format!("\\{}", "\u{1d185}".repeat(16));
    let phase = format!("\x1b[2J\x1b[H{}", cell.repeat(10 * 500));
    let mut fixture = Fixture::new(300, 500, &[&phase]);
    let page = fixture.snapshot(0);
    assert_eq!(page["grid"].as_array().unwrap().len(), 10);
    assert_eq!(
        page["grid"][0][0]["text"].as_str().unwrap().chars().count(),
        17
    );
    assert_eq!(
        page["grid"][9][499]["text"]
            .as_str()
            .unwrap()
            .chars()
            .count(),
        17
    );
    assert_eq!(page["cursor"]["row"], 9);
    assert!(
        serde_json::to_vec(&json!({"id":"test","result":page}))
            .unwrap()
            .len()
            < 4 * 1024 * 1024
    );
}

#[test]
fn pty_selection_matches_visible_styled_cells_and_rejects_stale_revision() {
    let mut fixture = Fixture::new(
        4,
        8,
        &[
            "\x1b[2J\x1b[H\x1b[31m界e\u{301}\x1b[0mX\r\n\x1b[8mHIDDEN\x1b[0mY",
            "\x1b[2J\x1b[Hchanged",
        ],
    );
    let first = fixture.snapshot(0);
    let start = TerminalPoint { row: 0, col: 1 };
    let end = TerminalPoint { row: 1, col: 6 };
    let copied = fixture
        .terminal
        .copy_selection(first["revision"].as_u64().unwrap(), start, end)
        .unwrap();
    assert_eq!(copied, "界e\u{301}X\n      Y");
    assert_eq!(copied, selected_text(&first, start, end).unwrap());
    fixture.next(1);
    assert!(
        fixture
            .terminal
            .copy_selection(first["revision"].as_u64().unwrap(), start, end)
            .unwrap_err()
            .to_string()
            .contains("changed")
    );
}

#[test]
fn pty_soft_wrapping_metadata_prevents_spurious_copied_newlines() {
    let mut fixture = Fixture::new(4, 8, &["\x1b[2J\x1b[Habcdefghij"]);
    let page = fixture.snapshot(0);
    assert_eq!(page["grid"][0][7]["wrapline"], true);
    let start = TerminalPoint { row: 0, col: 0 };
    let end = TerminalPoint { row: 1, col: 1 };
    assert_eq!(selected_text(&page, start, end).unwrap(), "abcdefghij");
    assert_eq!(
        fixture
            .terminal
            .copy_selection(page["revision"].as_u64().unwrap(), start, end)
            .unwrap(),
        "abcdefghij"
    );
}

#[test]
fn full_width_terminal_cursor_reports_insertion_boundary_after_last_cell() {
    let mut fixture = Fixture::new(4, 8, &["\x1b[2J\x1b[Habcdefgh"]);
    let page = fixture.snapshot(0);
    assert_eq!(page["cursor"]["col"], 7);
    assert_eq!(page["cursor"]["insertionCol"], 8);
}

#[test]
fn scrollback_navigation_copies_history_and_invalidates_old_coordinates() {
    use coincide_core::terminal::TerminalScroll;
    // A fresh grid needs no erase: ED 2 pushes even its blank cursor row
    // into history, which would add a row unrelated to this scroll fixture.
    let mut fixture = Fixture::new(3, 8, &["a\r\nb\r\nc\r\nd\r\ne\r\nf"]);
    let live = fixture.snapshot(0);
    assert_eq!(live["lines"], json!(["d", "e", "f"]));
    assert_eq!(live["viewport"]["historySize"], 3);
    assert_eq!(live["viewport"]["atBottom"], true);
    assert!(fixture.terminal.scroll(TerminalScroll::Top).unwrap());
    let history = fixture.snapshot(0);
    assert_eq!(history["lines"], json!(["a", "b", "c"]));
    assert_eq!(history["viewport"]["displayOffset"], 3);
    assert_eq!(history["cursor"]["visible"], false);
    let start = TerminalPoint { row: 0, col: 0 };
    let end = TerminalPoint { row: 2, col: 7 };
    assert!(
        fixture
            .terminal
            .copy_selection(live["revision"].as_u64().unwrap(), start, end)
            .is_err()
    );
    let copied = fixture
        .terminal
        .copy_selection(history["revision"].as_u64().unwrap(), start, end)
        .unwrap();
    assert_eq!(copied, "a\nb\nc");
    assert_eq!(copied, selected_text(&history, start, end).unwrap());
    let plain = fixture.terminal.snapshot().unwrap();
    assert_eq!(plain["viewport"], history["viewport"]);
    assert_eq!(plain["lines"], history["lines"]);
    assert!(fixture.terminal.scroll(TerminalScroll::Bottom).unwrap());
    assert_eq!(fixture.snapshot(0)["lines"], live["lines"]);
}

#[test]
fn scrollback_clamps_extreme_deltas_and_noops_preserve_revision() {
    use coincide_core::terminal::TerminalScroll;
    let mut fixture = Fixture::new(3, 8, &["0\r\n1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7"]);
    fixture.snapshot(0);
    fixture.terminal.scroll(TerminalScroll::Lines(1)).unwrap();
    assert_eq!(fixture.snapshot(0)["viewport"]["displayOffset"], 1);
    fixture.terminal.scroll(TerminalScroll::PageUp).unwrap();
    assert_eq!(fixture.snapshot(0)["viewport"]["displayOffset"], 4);
    fixture
        .terminal
        .scroll(TerminalScroll::Lines(i32::MAX))
        .unwrap();
    let top = fixture.snapshot(0);
    assert_eq!(top["viewport"]["displayOffset"], 5);
    assert!(
        !fixture
            .terminal
            .scroll(TerminalScroll::Lines(i32::MAX))
            .unwrap()
    );
    assert!(!fixture.terminal.scroll(TerminalScroll::Top).unwrap());
    assert_eq!(fixture.snapshot(0)["revision"], top["revision"]);
    fixture.terminal.scroll(TerminalScroll::PageDown).unwrap();
    assert_eq!(fixture.snapshot(0)["viewport"]["displayOffset"], 2);
    fixture
        .terminal
        .scroll(TerminalScroll::Lines(i32::MIN))
        .unwrap();
    let bottom = fixture.snapshot(0);
    assert_eq!(bottom["viewport"]["displayOffset"], 0);
    assert!(!fixture.terminal.scroll(TerminalScroll::Bottom).unwrap());
    assert!(!fixture.terminal.scroll(TerminalScroll::Lines(0)).unwrap());
    assert_eq!(fixture.snapshot(0)["revision"], bottom["revision"]);
}

#[test]
fn scrollback_stays_anchored_during_output_and_alt_screen_has_no_history() {
    use coincide_core::terminal::TerminalScroll;
    let mut fixture = Fixture::new(
        3,
        8,
        &[
            "a\r\nb\r\nc\r\nd\r\ne\r\nf",
            "\r\ng",
            "\x1b[?1049h\x1b[2J\x1b[HALT",
            "\x1b[?1049l",
        ],
    );
    fixture.snapshot(0);
    fixture.terminal.scroll(TerminalScroll::Top).unwrap();
    let before = fixture.snapshot(0);
    let after = fixture.next(1);
    assert_eq!(after["lines"], before["lines"]);
    assert_eq!(after["viewport"]["displayOffset"], 4);
    assert!(after["revision"].as_u64().unwrap() > before["revision"].as_u64().unwrap());
    let alternate = fixture.next(2);
    assert_eq!(alternate["viewport"]["alternateScreen"], true);
    assert_eq!(alternate["viewport"]["historySize"], 0);
    assert!(!fixture.terminal.scroll(TerminalScroll::Top).unwrap());
    assert!(
        !fixture
            .terminal
            .scroll(TerminalScroll::Lines(i32::MAX))
            .unwrap()
    );
    assert_eq!(fixture.snapshot(2)["lines"][0], "ALT");
    let restored = fixture.next(3);
    assert_eq!(restored["viewport"]["alternateScreen"], false);
    assert_eq!(restored["viewport"]["historySize"], 4);
    fixture.terminal.scroll(TerminalScroll::Top).unwrap();
    assert_eq!(fixture.snapshot(3)["lines"], before["lines"]);
}

#[test]
fn scrollback_copy_preserves_wide_combining_wraps_and_concealment() {
    use coincide_core::terminal::TerminalScroll;
    let mut fixture = Fixture::new(
        3,
        8,
        &["界e\u{301}123456\r\n\x1b[8msecret\x1b[0m!\r\nx\r\ny\r\nz"],
    );
    fixture.snapshot(0);
    fixture.terminal.scroll(TerminalScroll::Top).unwrap();
    let history = fixture.snapshot(0);
    let start = TerminalPoint { row: 0, col: 1 };
    let end = TerminalPoint { row: 2, col: 6 };
    let copied = fixture
        .terminal
        .copy_selection(history["revision"].as_u64().unwrap(), start, end)
        .unwrap();
    assert_eq!(copied, "界e\u{301}123456\n      !");
    assert_eq!(selected_text(&history, start, end).unwrap(), copied);
    let page = fixture.terminal.styled_snapshot(1, 1).unwrap();
    assert_eq!(page["grid"][0], history["grid"][1]);
    assert_eq!(page["viewport"], history["viewport"]);
}

#[test]
fn checked_scroll_rejects_stale_output_resize_and_even_noop_requests() {
    use coincide_core::terminal::TerminalScroll;
    let mut fixture = Fixture::new(3, 8, &["a\r\nb\r\nc\r\nd", "\r\ne"]);
    let original = fixture.snapshot(0);
    let revision = original["revision"].as_u64().unwrap();
    assert!(
        !fixture
            .terminal
            .scroll_checked(revision, TerminalScroll::Bottom)
            .unwrap()
    );
    assert_eq!(fixture.snapshot(0)["revision"], revision);
    let output = fixture.next(1);
    assert!(
        fixture
            .terminal
            .scroll_checked(revision, TerminalScroll::Bottom)
            .is_err()
    );
    assert_eq!(fixture.snapshot(1)["viewport"], output["viewport"]);
    let current = output["revision"].as_u64().unwrap();
    fixture.terminal.resize(4, 8).unwrap();
    let resized = fixture.snapshot(1);
    assert!(
        fixture
            .terminal
            .scroll_checked(current, TerminalScroll::Top)
            .is_err()
    );
    assert_eq!(fixture.snapshot(1)["revision"], resized["revision"]);
    let current = resized["revision"].as_u64().unwrap();
    assert!(
        fixture
            .terminal
            .scroll_checked(current, TerminalScroll::Top)
            .unwrap()
    );
    let history = fixture.snapshot(1);
    assert!(
        fixture
            .terminal
            .scroll_checked(current, TerminalScroll::Bottom)
            .is_err()
    );
    assert_eq!(fixture.snapshot(1)["lines"], history["lines"]);
}

#[test]
fn structured_input_reaches_synthetic_pty_with_current_modes_and_exact_framing() {
    use coincide_core::terminal::{KeyModifiers, TerminalInput};
    let dir = tempfile::tempdir().unwrap();
    let script = dir.path().join("mode-input-fixture");
    let payload = "界e\u{301}\n";
    let expected = format!("\x1bOA\x1b[200~{payload}\x1b[201~ok\x1b[1;6D");
    let source = format!(
        r#"#!/bin/sh
stty raw -echo
printf '\033[?1l\033[?2004l\033]2;fixture-0\007'
od -An -v -tx1 -N 3 | tr -d ' \n'
printf '\r\n\033[?1h\033[?2004h\033]2;fixture-1\007'
od -An -v -tx1 -N {} | tr -d ' \n'
printf '\r\n\033[?1l\033[?2004l\033]2;fixture-2\007'
od -An -v -tx1 -N 3 | tr -d ' \n'
printf '\033]2;fixture-3\007'
IFS= read -r finish
"#,
        expected.len()
    );
    fs::write(&script, source).unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
    let terminal = Terminal::spawn(dir.path(), script.to_str().unwrap(), 6, 160).unwrap();
    let mut fixture = Fixture {
        terminal,
        _dir: dir,
    };
    let normal = fixture.snapshot(0);
    assert_eq!(
        normal["modes"],
        json!({"applicationCursor":false,"bracketedPaste":false})
    );
    let up = || TerminalInput::Key {
        key: "up".into(),
        modifiers: Default::default(),
    };
    assert_eq!(fixture.terminal.input(up()).unwrap()["encodedBytes"], 3);
    let app = fixture.snapshot(1);
    assert!(app["revision"].as_u64() > normal["revision"].as_u64());
    assert_eq!(
        app["modes"],
        json!({"applicationCursor":true,"bracketedPaste":true})
    );
    assert_eq!(fixture.terminal.snapshot().unwrap()["modes"], app["modes"]);
    assert_eq!(app["lines"][0], "1b5b41");
    for input in [
        TerminalInput::Paste {
            text: "\x1b[201~bad".into(),
        },
        TerminalInput::Text {
            text: "\x03".into(),
        },
        TerminalInput::Paste {
            text: "a".repeat(32757),
        },
    ] {
        assert!(fixture.terminal.input(input).is_err());
    }
    fixture.terminal.input(up()).unwrap();
    assert_eq!(
        fixture
            .terminal
            .input(TerminalInput::Paste {
                text: payload.into()
            })
            .unwrap()["encodedBytes"],
        payload.len() + 12
    );
    fixture
        .terminal
        .input(TerminalInput::Text { text: "ok".into() })
        .unwrap();
    fixture
        .terminal
        .input(TerminalInput::Key {
            key: "left".into(),
            modifiers: KeyModifiers {
                shift: true,
                control: true,
                alt: false,
            },
        })
        .unwrap();
    let disabled = fixture.snapshot(2);
    let hex: String = expected.bytes().map(|b| format!("{b:02x}")).collect();
    assert_eq!(disabled["lines"][1], hex);
    assert_eq!(disabled["modes"], normal["modes"]);
    assert_eq!(
        fixture
            .terminal
            .input(TerminalInput::Paste { text: "end".into() })
            .unwrap()["encodedBytes"],
        3
    );
    assert_eq!(fixture.snapshot(3)["lines"][2], "656e64");
}

#[test]
fn input_modes_are_independent_of_alternate_screen_and_reset_by_ris() {
    let mut fixture = Fixture::new(3, 20, &["\x1b[?1h\x1b[?2004h", "\x1b[?1049h", "\x1bc"]);
    let enabled = fixture.snapshot(0);
    assert_eq!(enabled["viewport"]["alternateScreen"], false);
    assert_eq!(
        enabled["modes"],
        json!({"applicationCursor":true,"bracketedPaste":true})
    );
    assert_eq!(fixture.next(1)["modes"], enabled["modes"]);
    let reset = fixture.next(2);
    assert_eq!(
        reset["modes"],
        json!({"applicationCursor":false,"bracketedPaste":false})
    );
    assert!(reset["revision"].as_u64() > enabled["revision"].as_u64());
}

#[test]
fn swift_zsh_markers_anchor_wrapped_unicode_concealed_output_and_report_cwd() {
    let command = "printf a-very-long-argument";
    let bytes = format!(
        "\x1b]7;file://localhost/tmp/sub%20dir/%E7%95%8C\x07\x1b]133;A\x07\x1b]1337;CoincidePrompt=2\x07location\r\n$ {command}\r\n\x1b]1337;CoincideCommand={command}\x07\x1b]133;C\x07界e\u{301}\r\n\x1b[8msecret\x1b[0m!\r\n\x1b]133;D;1\x07\x1b]133;A\x07location\r\n$ "
    );
    let mut fixture = Fixture::new(6, 12, &[&bytes]);
    let frame = fixture.snapshot(0);
    assert_eq!(frame["shell"]["command"], command);
    assert_eq!(frame["shell"]["exitStatus"], 1);
    assert_eq!(frame["shell"]["cwd"]["path"], "/tmp/sub dir/界");
    assert_eq!(frame["shell"]["cwd"]["trusted"], false);
    assert_eq!(
        fixture.terminal.snapshot().unwrap()["shell"],
        frame["shell"]
    );
    assert_eq!(
        fixture
            .terminal
            .last_command_output(frame["revision"].as_u64().unwrap())
            .unwrap()
            .unwrap(),
        format!("$ {command}\n界e\u{301}\n      !")
    );
}

#[test]
fn bash_delayed_command_marks_use_prompt_anchor_instead_of_matching_output_suffix() {
    let command = "echo a-long-argument";
    let bytes = format!(
        "\x1b]133;A\x07\x1b]1337;CoincidePrompt=1\x07$ {command}\r\nfirst\r\nshadow {command}\r\nlast\r\n\x1b]1337;CoincideCommand={command}\x07\x1b]133;D;0\x07\x1b]133;A\x07$ "
    );
    let mut fixture = Fixture::new(6, 12, &[&bytes]);
    let frame = fixture.snapshot(0);
    assert_eq!(
        fixture
            .terminal
            .last_command_output(frame["revision"].as_u64().unwrap())
            .unwrap()
            .unwrap(),
        format!("$ {command}\nfirst\nshadow {command}\nlast")
    );
}

#[test]
fn command_anchors_fail_closed_after_resize_clear_or_transient_alternate_screen() {
    let marked = "\x1b]133;A\x07$ echo x\r\n\x1b]1337;CoincideCommand=echo x\x07\x1b]133;C\x07x\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ ";
    for destructive in ["\x1b[3J", "\x1b[?1049h\x1b[?1049l", "\x1bc"] {
        let mut fixture = Fixture::new(4, 30, &[marked, destructive]);
        let before = fixture.snapshot(0);
        assert!(
            fixture
                .terminal
                .last_command_output(before["revision"].as_u64().unwrap())
                .unwrap()
                .is_some()
        );
        let after = fixture.next(1);
        assert!(
            fixture
                .terminal
                .last_command_output(before["revision"].as_u64().unwrap())
                .is_err()
        );
        assert!(
            fixture
                .terminal
                .last_command_output(after["revision"].as_u64().unwrap())
                .unwrap()
                .is_none()
        );
    }
    let mut fixture = Fixture::new(4, 30, &[marked]);
    fixture.snapshot(0);
    fixture.terminal.resize(5, 40).unwrap();
    let frame = fixture.snapshot(0);
    assert!(
        fixture
            .terminal
            .last_command_output(frame["revision"].as_u64().unwrap())
            .unwrap()
            .is_none()
    );
}

#[test]
fn command_anchor_does_not_guess_after_history_fills_or_missing_prompt_mark() {
    let mut bytes = String::from(
        "\x1b]133;A\x07$ echo x\r\n\x1b]1337;CoincideCommand=echo x\x07\x1b]133;C\x07",
    );
    bytes.push_str(&"x\r\n".repeat(10010));
    bytes.push_str("\x1b]133;D;0\x07\x1b]133;A\x07$ ");
    let mut fixture = Fixture::new(3, 20, &[&bytes]);
    let frame = fixture.snapshot(0);
    assert_eq!(frame["viewport"]["historySize"], 10000);
    assert!(
        fixture
            .terminal
            .last_command_output(frame["revision"].as_u64().unwrap())
            .unwrap()
            .is_none()
    );
    let bytes =
        "$ echo x\r\nshadow echo x\r\n\x1b]1337;CoincideCommand=echo x\x07\x1b]133;D;0\x07$ ";
    let mut fixture = Fixture::new(4, 20, &[bytes]);
    let frame = fixture.snapshot(0);
    assert!(
        fixture
            .terminal
            .last_command_output(frame["revision"].as_u64().unwrap())
            .unwrap()
            .is_none()
    );
}
