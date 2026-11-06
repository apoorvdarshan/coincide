//! Real panel/native handlers, simulated OS path-prompt primitive, real owned
//! local Git processes. This does not exercise a physical OS dialog or CUA.
use super::*;
use coincide_core::{api::Engine, native_file, store::Store};
use gpui_kit::{AppContext, Entity, TestAppContext, VisualTestContext};
use std::{
    fs,
    path::Path,
    process::{Command, Stdio},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
const CHILD: &str = "COINCIDE_INSTRUCTION_UI_CHILD";
const ROOT: &str = "COINCIDE_INSTRUCTION_UI_ROOT";
fn git(path: &Path, args: &[&str]) -> Vec<u8> {
    let result = Command::new("git")
        .args([
            "--no-replace-objects",
            "--literal-pathspecs",
            "-c",
            "protocol.allow=never",
            "-c",
            "protocol.file.allow=always",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env(
            "GIT_CONFIG_GLOBAL",
            if cfg!(windows) { "NUL" } else { "/dev/null" },
        )
        .env("GIT_TERMINAL_PROMPT", "0")
        .current_dir(path)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "synthetic local fixture command failed"
    );
    result.stdout
}
fn settle(
    cx: &mut VisualTestContext,
    panel: &Entity<InstructionsPanel>,
    done: impl Fn(&InstructionsPanel) -> bool,
) {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        cx.run_until_parked();
        panel.update(cx, |panel, cx| panel.poll_instruction_git(cx));
        if panel
            .read(cx)
            .setup
            .git
            .visible_status()
            .contains("stopped:")
        {
            panic!("{}", panel.read(cx).setup.visible_status());
        }
        if done(panel.read(cx)) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "{}",
            panel.read(cx).setup.visible_status()
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}
#[gpui_kit::test]
#[ignore = "only private_instructions_ui_child runs this with a fresh synthetic HOME"]
fn headless_native_handlers_busy_initialization_picker_cas_git_and_owned_quit(
    cx: &mut TestAppContext,
) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os(ROOT).unwrap())
        .canonicalize()
        .unwrap();
    let data = root.join("data");
    native_file::private_directory(&data).unwrap();
    let engine = Arc::new(Mutex::new(Engine::new(
        Store::open(&data.join("state.sqlite")).unwrap(),
    )));
    let original = json!({"global":null,"projects":{},"unknown":{"keep":[1,2]}});
    engine
        .lock()
        .unwrap()
        .store
        .save_document("instructions.json", &original)
        .unwrap();
    let master = root.join("master.md");
    fs::write(&master, "Synthetic approved master version two\n").unwrap();
    let repo = root.join("repo");
    fs::create_dir(&repo).unwrap();
    git(&repo, &["init", "--initial-branch=main"]);
    git(&repo, &["config", "user.name", "Synthetic Native UI"]);
    git(
        &repo,
        &["config", "user.email", "native-ui@example.invalid"],
    );
    fs::write(repo.join("AGENTS.md"), "Synthetic old copy\n").unwrap();
    fs::write(repo.join("README.md"), "Synthetic base readme\n").unwrap();
    git(&repo, &["add", "--", "AGENTS.md", "README.md"]);
    git(&repo, &["commit", "-m", "Synthetic base"]);
    let bare = root.join("remote.git");
    fs::create_dir(&bare).unwrap();
    git(&bare, &["init", "--bare", "--initial-branch=main"]);
    git(&repo, &["remote", "add", "origin", bare.to_str().unwrap()]);
    git(&repo, &["push", "-u", "origin", "main"]);
    let peer = root.join("peer");
    git(
        &root,
        &["clone", bare.to_str().unwrap(), peer.to_str().unwrap()],
    );
    git(&peer, &["config", "user.name", "Synthetic Native UI"]);
    git(
        &peer,
        &["config", "user.email", "native-ui@example.invalid"],
    );
    fs::write(peer.join("README.md"), "Synthetic incoming readme\n").unwrap();
    git(&peer, &["add", "--", "README.md"]);
    git(&peer, &["commit", "-m", "Synthetic incoming"]);
    git(&peer, &["push", "origin", "main"]);
    let remote_before = git(&bare, &["rev-parse", "main"]);
    cx.update(gpui_kit::init);
    let editors = engine.lock().unwrap().native_ui_editors();
    // Force the exact initial EngineBusy case, not a synthetic missing flag.
    let guard = engine.lock().unwrap();
    let (panel, cx) = cx.add_window_view(|window, cx| {
        InstructionsPanel::new(engine.clone(), editors.editor(), window, cx)
    });
    assert!(panel.read(cx).setup.metadata.is_none());
    cx.update(|window, cx| panel.update(cx, |panel, cx| panel.setup_choose_master(window, cx)));
    assert!(!cx.did_prompt_for_paths());
    assert!(panel.read(cx).setup.visible_status().contains("not ready"));
    drop(guard);
    // Retry the same real native handler after the owner becomes available.
    cx.update(|window, cx| panel.update(cx, |panel, cx| panel.setup_choose_master(window, cx)));
    assert!(cx.did_prompt_for_paths());
    {
        let mut owner = engine.lock().unwrap();
        let refused = owner.dispatch(json!({"method":"app.quit","params":{}}));
        assert!(refused.get("error").is_some());
        assert!(!owner.admissions_frozen() && !owner.shutdown);
    }
    // A settings edit while the OS picker is open must refuse instead of
    // silently adopting the new document when the future returns.
    let external = json!({"global":null,"projects":{},"unknown":{"keep":[1,2]},"external":true});
    engine
        .lock()
        .unwrap()
        .store
        .save_document("instructions.json", &external)
        .unwrap();
    cx.simulate_path_prompt_response(|options| {
        assert!(options.files && !options.directories && !options.multiple);
        Some(vec![master.clone()])
    });
    cx.run_until_parked();
    assert_eq!(
        engine
            .lock()
            .unwrap()
            .store
            .document("instructions.json")
            .unwrap(),
        Some(external.clone())
    );
    assert!(panel.read(cx).setup.visible_status().contains("changed"));
    assert_ne!(
        panel.read(cx).native_target_label(),
        master.display().to_string()
    );
    // Cancel a real pending picker; no config/text write or authority results.
    cx.update(|window, cx| panel.update(cx, |panel, cx| panel.setup_choose_master(window, cx)));
    assert!(cx.did_prompt_for_paths());
    assert!(
        engine
            .lock()
            .unwrap()
            .dispatch(json!({"method":"app.quit","params":{}}))
            .get("error")
            .is_some()
    );
    cx.simulate_path_prompt_response(|_| None);
    cx.run_until_parked();
    assert!(!panel.read(cx).setup.picker_pending);
    assert_eq!(
        engine
            .lock()
            .unwrap()
            .store
            .document("instructions.json")
            .unwrap(),
        Some(external.clone())
    );
    assert_eq!(
        fs::read(&master).unwrap(),
        b"Synthetic approved master version two\n"
    );
    // A new explicit click is a new review baseline, preserving unknown fields.
    cx.update(|window, cx| panel.update(cx, |panel, cx| panel.setup_choose_master(window, cx)));
    assert!(cx.did_prompt_for_paths());
    cx.simulate_path_prompt_response(|_| Some(vec![master.clone()]));
    cx.run_until_parked();
    assert_eq!(
        panel.read(cx).native_target_label(),
        master.display().to_string()
    );
    assert_eq!(
        panel.read(cx).editor.read(cx).value().as_ref(),
        "Synthetic approved master version two\n"
    );
    cx.update(|window, cx| {
        panel.update(cx, |panel, cx| {
            panel.choose_instruction_copy(false, window, cx)
        })
    });
    assert!(cx.did_prompt_for_paths());
    cx.simulate_path_prompt_response(|options| {
        assert!(options.files && !options.directories);
        Some(vec![repo.join("AGENTS.md")])
    });
    cx.run_until_parked();
    assert!(panel.read(cx).setup.copy.review.is_some());
    assert_eq!(
        fs::read(repo.join("AGENTS.md")).unwrap(),
        b"Synthetic old copy\n"
    );
    cx.update(|window, cx| {
        panel.update(cx, |panel, cx| {
            panel.apply_copy_sync(Some(crate::instructions::sync::Keep::Master), window, cx)
        })
    });
    assert_eq!(
        fs::read(repo.join("AGENTS.md")).unwrap(),
        fs::read(&master).unwrap()
    );
    panel.update(cx, |panel, cx| panel.choose_git_repository(cx));
    assert!(cx.did_prompt_for_paths());
    cx.simulate_path_prompt_response(|options| {
        assert!(!options.files && options.directories);
        Some(vec![repo.clone()])
    });
    settle(cx, &panel, |panel| panel.setup.git.reviewing());
    assert_eq!(git(&bare, &["rev-parse", "main"]), remote_before);
    panel.update(cx, |panel, cx| panel.apply_git_copy(true, cx));
    settle(cx, &panel, |panel| {
        !panel.setup.git.busy()
            && panel
                .setup
                .git
                .visible_status()
                .contains("Git copy finished")
    });
    assert!(
        panel
            .read(cx)
            .setup
            .git
            .visible_status()
            .contains("Commit: true · Pulled: true · Pushed: true")
    );
    assert_eq!(
        git(&bare, &["show", "main:AGENTS.md"]),
        fs::read(&master).unwrap()
    );
    assert_eq!(
        git(&bare, &["show", "main:README.md"]),
        b"Synthetic incoming readme\n"
    );
    assert_eq!(
        git(&bare, &["rev-parse", "main"]),
        git(&repo, &["rev-parse", "HEAD"])
    );
    assert!(git(&repo, &["for-each-ref", "refs/coincide/instructions/"]).is_empty());
    let config = engine
        .lock()
        .unwrap()
        .store
        .document("instructions.json")
        .unwrap()
        .unwrap();
    assert_eq!(config["unknown"], external["unknown"]);
    assert_eq!(config["external"], true);
    assert_eq!(config["global"]["masterPath"], json!(master));
    assert_eq!(
        config["global"]["fileCopy"]["path"],
        json!(repo.join("AGENTS.md"))
    );
    // Closing the visual window and dropping its external entity must not
    // cancel ownership of an outstanding platform picker. Its retained task
    // and independent lease survive until the actual prompt result returns.
    {
        let (closing, closing_cx) = cx.add_window_view(|window, cx| {
            InstructionsPanel::new(engine.clone(), editors.editor(), window, cx)
        });
        closing_cx.update(|window, cx| {
            closing.update(cx, |panel, cx| panel.setup_choose_master(window, cx))
        });
        assert!(closing_cx.did_prompt_for_paths());
        let weak = closing.downgrade();
        closing_cx.update(|window, _| window.remove_window());
        drop(closing);
        closing_cx.run_until_parked();
        assert!(
            weak.upgrade().is_some(),
            "pending native future must retain its panel owner"
        );
        assert!(
            engine
                .lock()
                .unwrap()
                .dispatch(json!({"method":"app.quit","params":{}}))
                .get("error")
                .is_some()
        );
        closing_cx.simulate_path_prompt_response(|_| None);
        closing_cx.run_until_parked();
        assert!(
            weak.upgrade().is_none(),
            "closed-window owner releases only after actual future completion"
        );
    }
    assert_eq!(
        engine
            .lock()
            .unwrap()
            .store
            .document("instructions.json")
            .unwrap(),
        Some(config)
    );
    // Use the production normal-Quit drain owner, with this panel's actual
    // worker/picker status as the external-owner proof. No full Coincide/CUA.
    let control = Arc::new(Mutex::new(
        coincide_core::control::serve(root.join("ctl"), engine.clone()).unwrap(),
    ));
    let quit = crate::shutdown_runtime::Runtime::start(engine.clone(), control).unwrap();
    assert!(!quit.status().complete());
    panel.update(cx, |panel, _| panel.request_instruction_git_shutdown());
    let status = panel.update(cx, |panel, _| panel.instruction_git_shutdown_status());
    assert!(
        status.closed
            && status.unjoined == 0
            && status.pending_pickers == 0
            && status.panicked == 0
            && status.unclassified == 0
            && status.returned == 2
    );
    quit.set_external_drained(true);
    let deadline = Instant::now() + Duration::from_secs(10);
    while !quit.status().complete() {
        assert!(Instant::now() < deadline, "{:?}", quit.status());
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(engine.lock().unwrap().store.is_closed());
    cx.update(|_, cx| cx.quit());
}
#[::core::prelude::v1::test]
fn private_instructions_ui_child() {
    let base = std::env::temp_dir().join(format!(
        "ci-ui-{}",
        &uuid::Uuid::new_v4().simple().to_string()[..8]
    ));
    native_file::private_directory(&base).unwrap();
    for directory in ["home", "tmp"] {
        native_file::private_directory(&base.join(directory)).unwrap();
    }
    let mut command = Command::new(std::env::current_exe().unwrap());
    command.args(["--ignored", "instructions::setup::headless_tests::headless_native_handlers_busy_initialization_picker_cas_git_and_owned_quit", "--exact", "--nocapture", "--test-threads=1"]).env_clear()
        .env(CHILD, "1").env(ROOT, &base).env("HOME", base.join("home")).env("USERPROFILE", base.join("home")).env("XDG_CONFIG_HOME", base.join("home/config"))
        .env("TMPDIR", base.join("tmp")).env("TMP", base.join("tmp")).env("TEMP", base.join("tmp")).env("LANG", "en_US.UTF-8").current_dir(&base);
    for key in ["PATH", "SystemRoot", "WINDIR"] {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    let result = command.output().unwrap();
    let stdout = String::from_utf8_lossy(&result.stdout);
    let stderr = String::from_utf8_lossy(&result.stderr);
    print!("{stdout}");
    eprint!("{stderr}");
    assert!(
        result.status.success() && stdout.contains("1 passed"),
        "headless native-handler fixture failed; retained {}\n{stdout}\n{stderr}",
        base.display()
    );
    fs::remove_dir_all(&base).unwrap();
}
