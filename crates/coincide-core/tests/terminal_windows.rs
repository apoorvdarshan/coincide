//! Native ConPTY coverage. The test executable doubles as the phased PTY child:
//! Terminal::spawn takes an executable without arguments, so a private cwd marker
//! selects child behavior. Direct stdout writes bypass libtest's print capture.
//! No shell, PowerShell, Unix tools, environment mutation, or control IPC needed.
#![cfg(windows)]

use coincide_core::terminal::{Terminal, TerminalInput, TerminalPoint, TerminalScroll};
use serde_json::{Value, json};
use std::{
    ffi::c_void,
    fs,
    io::{Read, Write},
    thread,
    time::{Duration, Instant},
};

const MARKER: &str = "terminal-windows-child.marker";
const MAGIC: &str = "Coincide isolated ConPTY scroll fixture v1";
const READY: &str = "terminal-windows-child.ready";
const TIMEOUT: Duration = Duration::from_secs(20);

#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetStdHandle(kind: u32) -> *mut c_void;
    fn GetConsoleMode(handle: *mut c_void, mode: *mut u32) -> i32;
    fn SetConsoleMode(handle: *mut c_void, mode: u32) -> i32;
}

fn configure_console() {
    // Only the task-created child calls these APIs on its own ConPTY console.
    // Raw input prevents echo/canonical buffering from corrupting phase barriers.
    for (kind, clear, set) in [
        (-10_i32, 0x0001 | 0x0002 | 0x0004, 0x0200), // stdin: raw + VT input
        (-11_i32, 0, 0x0001 | 0x0004),               // stdout: processed + VT output
    ] {
        unsafe {
            let handle = GetStdHandle(kind as u32);
            assert!(!handle.is_null() && handle as isize != -1);
            let mut mode = 0;
            assert_ne!(
                GetConsoleMode(handle, &mut mode),
                0,
                "{}",
                std::io::Error::last_os_error()
            );
            assert_ne!(
                SetConsoleMode(handle, (mode & !clear) | set),
                0,
                "{}",
                std::io::Error::last_os_error()
            );
        }
    }
}

fn emit(text: &str) {
    let mut stdout = std::io::stdout().lock();
    stdout.write_all(text.as_bytes()).unwrap();
    stdout.flush().unwrap();
}

fn expect_input(expected: u8) {
    let mut byte = [0];
    std::io::stdin().read_exact(&mut byte).unwrap();
    assert_eq!(byte[0], expected, "unexpected PTY input phase");
}

fn phased_child() -> ! {
    configure_console();
    // File readiness is only for console setup: every output phase below is
    // acknowledged from a rendered terminal frame, not from a sleep or file.
    fs::write(READY, MAGIC).unwrap();
    expect_input(b'g');
    emit("\x1b[2J\x1b[HREADY");
    for row in 0..12 {
        expect_input(b'r');
        emit(&format!("\r\nROW{row:02}"));
    }
    expect_input(b'a');
    emit("\x1b[?1049h\x1b[2J\x1b[HALTERNATE");
    expect_input(b'm');
    emit("\x1b[?1049l");
    expect_input(b'i');
    emit("\x1b[?1h\x1b[?2004h\r\nINPUT READY");
    let expected = expected_input();
    let mut received = vec![0; expected.len()];
    std::io::stdin().read_exact(&mut received).unwrap();
    assert_eq!(
        received, expected,
        "Mode-aware input bytes changed in ConPTY"
    );
    emit("\x1b[?1l\x1b[?2004l\r\nINPUT OK");
    let mut normal = [0; 7];
    std::io::stdin().read_exact(&mut normal).unwrap();
    assert_eq!(&normal, b"\x1b[Atail");
    emit("\r\nNORMAL OK");
    expect_input(b'q');
    // Avoid libtest's summary adding unrelated PTY output after the final phase.
    std::process::exit(0);
}

fn expected_input() -> Vec<u8> {
    "\x1bOA\x1b[200~paste\x1b[201~界e\u{301}"
        .as_bytes()
        .to_vec()
}

fn wait_frame(
    terminal: &mut Terminal,
    description: &str,
    predicate: impl Fn(&Value) -> bool,
) -> Value {
    let deadline = Instant::now() + TIMEOUT;
    loop {
        let frame = terminal.snapshot().unwrap();
        if predicate(&frame) {
            return frame;
        }
        assert!(
            Instant::now() < deadline,
            "{description} timed out: {frame}"
        );
        thread::sleep(Duration::from_millis(10));
    }
}

fn point(row: usize, col: usize) -> TerminalPoint {
    TerminalPoint { row, col }
}

#[test]
fn windows_native_pty_scroll_copy_and_alternate_screen() {
    if fs::read_to_string(MARKER).ok().as_deref() == Some(MAGIC) {
        phased_child();
    }
    // Spaces exercise executable/cwd argument handling without a shell. Retain
    // the directory until after Terminal is dropped, including on assertion panic.
    let dir = tempfile::Builder::new()
        .prefix("Coincide Windows PTY ")
        .tempdir()
        .unwrap();
    fs::write(dir.path().join(MARKER), MAGIC).unwrap();
    let executable = std::env::current_exe().unwrap();
    let mut terminal = Terminal::spawn(dir.path(), executable.to_str().unwrap(), 6, 40).unwrap();
    let deadline = Instant::now() + TIMEOUT;
    while !dir.path().join(READY).exists() {
        // Service native cursor/device queries during console initialization too.
        let frame = terminal.snapshot().unwrap();
        assert!(
            frame["exitCode"].is_null(),
            "ConPTY child exited during setup: {frame}"
        );
        assert!(
            Instant::now() < deadline,
            "ConPTY child did not configure its console: {frame}"
        );
        thread::sleep(Duration::from_millis(10));
    }
    terminal.write("g").unwrap();
    wait_frame(&mut terminal, "initial output", |frame| {
        frame["lines"][0] == "READY"
    });
    // Acknowledge each row to prevent ConPTY's redraw coalescing from replacing
    // intermediate output with only a final screen. No fixed scheduling sleeps.
    for row in 0..12 {
        terminal.write("r").unwrap();
        let expected = format!("ROW{row:02}");
        wait_frame(&mut terminal, "phased row output", |frame| {
            frame["lines"]
                .as_array()
                .unwrap()
                .iter()
                .any(|line| line.as_str() == Some(expected.as_str()))
        });
    }
    let live = terminal.snapshot().unwrap();
    assert_eq!(
        live["lines"],
        json!(["ROW06", "ROW07", "ROW08", "ROW09", "ROW10", "ROW11"])
    );
    assert!(live["viewport"]["historySize"].as_u64().unwrap() >= 6);
    assert_eq!(live["viewport"]["atBottom"], true);
    assert!(
        terminal
            .scroll_checked(live["revision"].as_u64().unwrap(), TerminalScroll::Lines(3))
            .unwrap()
    );
    let history = terminal.snapshot().unwrap();
    assert_eq!(history["viewport"]["displayOffset"], 3);
    assert_eq!(
        history["lines"],
        json!(["ROW03", "ROW04", "ROW05", "ROW06", "ROW07", "ROW08"])
    );
    assert_eq!(
        terminal
            .copy_selection(
                history["revision"].as_u64().unwrap(),
                point(0, 0),
                point(2, 4)
            )
            .unwrap(),
        "ROW03\nROW04\nROW05"
    );
    assert!(
        terminal
            .copy_selection(live["revision"].as_u64().unwrap(), point(0, 0), point(0, 4))
            .is_err()
    );
    assert!(
        terminal
            .scroll_checked(live["revision"].as_u64().unwrap(), TerminalScroll::Bottom)
            .is_err()
    );
    let styled = terminal.styled_snapshot(0, 6).unwrap();
    assert_eq!(styled["revision"], history["revision"]);
    assert_eq!(styled["viewport"], history["viewport"]);
    assert_eq!(styled["grid"][0][0]["text"], "R");
    assert!(terminal.scroll(TerminalScroll::Bottom).unwrap());
    let bottom = terminal.snapshot().unwrap();
    assert_eq!(bottom["lines"], live["lines"]);
    assert!(
        !terminal
            .scroll_checked(bottom["revision"].as_u64().unwrap(), TerminalScroll::Bottom)
            .unwrap()
    );
    assert_eq!(terminal.snapshot().unwrap()["revision"], bottom["revision"]);

    terminal.write("a").unwrap();
    let alternate = wait_frame(&mut terminal, "alternate screen", |frame| {
        frame["viewport"]["alternateScreen"] == true && frame["lines"][0] == "ALTERNATE"
    });
    assert_eq!(alternate["viewport"]["historySize"], 0);
    assert!(!terminal.scroll(TerminalScroll::Lines(i32::MAX)).unwrap());
    assert_eq!(terminal.snapshot().unwrap()["lines"], alternate["lines"]);
    terminal.write("m").unwrap();
    let restored = wait_frame(&mut terminal, "main screen restoration", |frame| {
        frame["viewport"]["alternateScreen"] == false && frame["lines"] == live["lines"]
    });
    assert!(
        terminal
            .scroll_checked(alternate["revision"].as_u64().unwrap(), TerminalScroll::Top)
            .is_err()
    );
    assert_eq!(restored["viewport"]["atBottom"], true);
    terminal.write("i").unwrap();
    let input_ready = wait_frame(&mut terminal, "input modes enabled", |frame| {
        frame["modes"]["applicationCursor"] == true
            && frame["modes"]["bracketedPaste"] == true
            && frame["lines"]
                .as_array()
                .unwrap()
                .iter()
                .any(|line| line == "INPUT READY")
    });
    assert_eq!(
        terminal.styled_snapshot(0, 6).unwrap()["modes"],
        input_ready["modes"]
    );
    for input in [
        TerminalInput::Text {
            text: "\x03".into(),
        },
        TerminalInput::Paste {
            text: "\x1b[201~".into(),
        },
        TerminalInput::Paste {
            text: "a".repeat(32757),
        },
    ] {
        assert!(terminal.input(input).is_err());
    }
    let up = || TerminalInput::Key {
        key: "up".into(),
        modifiers: Default::default(),
    };
    assert_eq!(terminal.input(up()).unwrap()["encodedBytes"], 3);
    assert_eq!(
        terminal
            .input(TerminalInput::Paste {
                text: "paste".into()
            })
            .unwrap()["encodedBytes"],
        17
    );
    assert_eq!(
        terminal
            .input(TerminalInput::Text {
                text: "界e\u{301}".into()
            })
            .unwrap()["encodedBytes"],
        6
    );
    let disabled = wait_frame(&mut terminal, "input receipt and modes disabled", |frame| {
        frame["modes"]["applicationCursor"] == false
            && frame["modes"]["bracketedPaste"] == false
            && frame["lines"]
                .as_array()
                .unwrap()
                .iter()
                .any(|line| line == "INPUT OK")
    });
    assert!(disabled["revision"].as_u64() > input_ready["revision"].as_u64());
    terminal.input(up()).unwrap();
    assert_eq!(
        terminal
            .input(TerminalInput::Paste {
                text: "tail".into()
            })
            .unwrap()["encodedBytes"],
        4
    );
    let completed = wait_frame(&mut terminal, "normal input receipt", |frame| {
        frame["lines"]
            .as_array()
            .unwrap()
            .iter()
            .any(|line| line == "NORMAL OK")
    });
    terminal.write("q").unwrap();
    let exited = wait_frame(&mut terminal, "child exit", |frame| frame["exitCode"] == 0);
    assert_eq!(exited["lines"], completed["lines"]);
}
