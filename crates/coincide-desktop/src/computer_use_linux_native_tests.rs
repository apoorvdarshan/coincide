//! Only an explicit fresh GitHub Linux runner, private DBus and Xvfb may invoke
//! these ignored tests. The separate GTK child owns all app data and windows.
use crate::computer_use::Runtime;
use coincide_core::{
    agent::WorkerThreadStatus,
    computer_use::{Failure, Request},
    native_file,
};
use gtk::{
    glib::{self, translate::ToGlibPtr},
    prelude::*,
};
use serde_json::{Value, json};
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    process::{Child, Command, Stdio},
    rc::Rc,
    time::{Duration, Instant},
};
use uuid::Uuid;
use x11rb::{
    connection::Connection,
    protocol::{
        composite::{ConnectionExt as _, Redirect},
        xproto::*,
    },
    wrapper::ConnectionExt as _,
};
const MARKER: &str = "private-xvfb-owned-gtk-v1";
fn fresh_runner() {
    assert_eq!(std::env::var("GITHUB_ACTIONS").as_deref(), Ok("true"));
    assert_eq!(std::env::var("COINCIDE_LINUX_CU_CI").as_deref(), Ok(MARKER));
    assert!(std::env::var("DISPLAY").unwrap().starts_with(':'));
    assert!(
        std::env::var("DBUS_SESSION_BUS_ADDRESS")
            .unwrap()
            .starts_with("unix:")
    );
}
fn wait<T>(description: &str, mut read: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(12);
    loop {
        if let Some(value) = read() {
            return value;
        }
        assert!(Instant::now() < deadline, "Timed out: {description}");
        std::thread::sleep(Duration::from_millis(10));
    }
}
// Native GTK XID lookup is used only on this explicit synthetic X11 child.
#[link(name = "gdk-3")]
unsafe extern "C" {
    fn gdk_x11_window_get_xid(window: *mut gtk::gdk::ffi::GdkWindow) -> libc::c_ulong;
}
#[test]
#[ignore = "fresh GHA private Xvfb GTK child only"]
fn owned_gtk_child() {
    fresh_runner();
    assert!(std::env::var_os("WAYLAND_DISPLAY").is_none());
    let root = PathBuf::from(std::env::var_os("COINCIDE_LINUX_CU_ROOT").unwrap());
    assert!(
        root.is_absolute()
            && root
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("coincide-linux-cu-owned-")
    );
    gtk::init().unwrap();
    let window = gtk::Window::new(gtk::WindowType::Toplevel);
    window.set_title("Owned Linux CU fixture");
    window.set_decorated(false);
    window.set_default_size(520, 300);
    window.move_(100, 100);
    let column = gtk::Box::new(gtk::Orientation::Vertical, 12);
    // GTK3 entries report ATK_ROLE_TEXT, which AT-SPI exposes as Text.
    let edit = gtk::Entry::new();
    edit.set_text("synthetic original 🦀");
    edit.accessible().unwrap().set_name("Owned edit");
    let button = gtk::Button::with_label("Owned action");
    let password = gtk::Entry::new();
    password.set_visibility(false);
    password.set_text("synthetic-private-password");
    password
        .accessible()
        .unwrap()
        .set_name("Synthetic protected input");
    column.pack_start(&edit, false, false, 0);
    column.pack_start(&button, false, false, 0);
    column.pack_start(&password, false, false, 0);
    window.add(&column);
    window.show_all();
    edit.grab_focus();
    let gdk = window.window().unwrap();
    // SAFETY: GTK owns this realized GdkX11Window for the entire fixture lifetime.
    let xid = unsafe { gdk_x11_window_get_xid(gdk.to_glib_none().0) } as u32;
    let (connection, screen) = x11rb::connect(None).unwrap();
    let screenroot = connection.setup().roots[screen].root;
    let atom = |name: &[u8]| {
        connection
            .intern_atom(false, name)
            .unwrap()
            .reply()
            .unwrap()
            .atom
    };
    connection
        .change_property32(
            PropMode::REPLACE,
            screenroot,
            atom(b"_NET_CLIENT_LIST_STACKING"),
            AtomEnum::WINDOW,
            &[xid],
        )
        .unwrap()
        .check()
        .unwrap();
    connection
        .change_property32(
            PropMode::REPLACE,
            screenroot,
            atom(b"_NET_ACTIVE_WINDOW"),
            AtomEnum::WINDOW,
            &[xid],
        )
        .unwrap()
        .check()
        .unwrap();
    connection
        .change_property32(
            PropMode::REPLACE,
            xid,
            atom(b"_NET_WM_PID"),
            AtomEnum::CARDINAL,
            &[std::process::id()],
        )
        .unwrap()
        .check()
        .unwrap();
    connection
        .composite_query_version(0, 2)
        .unwrap()
        .reply()
        .unwrap();
    connection
        .composite_redirect_window(xid, Redirect::AUTOMATIC)
        .unwrap()
        .check()
        .unwrap();
    // No window manager is present on this private display. The fixture, never
    // the product adapter, explicitly focuses its own native top-level window.
    connection
        .set_input_focus(InputFocus::PARENT, xid, 0u32)
        .unwrap()
        .check()
        .unwrap();
    connection.flush().unwrap();
    let clicks = Rc::new(Cell::new(0));
    let dirty = Rc::new(Cell::new(true));
    let ready = Rc::new(Cell::new(false));
    let pending = Rc::new(RefCell::new(None::<String>));
    let sequence = Rc::new(RefCell::new(String::new()));
    let clock = window
        .frame_clock()
        .expect("realized owned GTK frame clock");
    let (paint_dirty, paint_ready, paint_pending, paint_sequence) = (
        dirty.clone(),
        ready.clone(),
        pending.clone(),
        sequence.clone(),
    );
    let paint_window = window.clone();
    let paint_handler = clock.connect_after_paint(move |_| {
        // A command acknowledgement is an actual rendered-frame receipt. The
        // earlier timer acknowledgement raced deferred resize/focus properties
        // after hide(), so a new strict watcher correctly saw a source change.
        paint_window.window().unwrap().display().sync();
        paint_dirty.set(false);
        paint_ready.set(true);
        if let Some(command) = paint_pending.borrow_mut().take() {
            *paint_sequence.borrow_mut() = command;
        }
    });
    let (count, click_dirty, click_window) = (clicks.clone(), dirty.clone(), window.clone());
    button.connect_clicked(move |_| {
        count.set(count.get() + 1);
        click_dirty.set(true);
        click_window.queue_draw();
    });
    let (edit_dirty, edit_window) = (dirty.clone(), window.clone());
    edit.connect_changed(move |_| {
        edit_dirty.set(true);
        edit_window.queue_draw();
    });
    clock.request_phase(gtk::gdk::FrameClockPhase::LAYOUT | gtk::gdk::FrameClockPhase::PAINT);
    let timer_clock = clock.clone();
    let timer_window = window.clone();
    let start = Instant::now();
    glib::timeout_add_local(Duration::from_millis(20), move || {
        if start.elapsed() > Duration::from_secs(60) {
            gtk::main_quit();
            return glib::ControlFlow::Break;
        }
        if let Ok(command) = std::fs::read_to_string(root.join("command")) {
            if *sequence.borrow() != command
                && pending.borrow().as_deref() != Some(command.as_str())
            {
                match command.as_str() {
                    "close" => {
                        gtk::main_quit();
                        return glib::ControlFlow::Break;
                    }
                    "hide-password" => {
                        password.hide();
                        edit.grab_focus();
                    }
                    "focus-password" => {
                        password.show();
                        password.grab_focus();
                    }
                    "move" => timer_window.move_(130, 130),
                    "focus-edit" => {
                        edit.set_position(-1);
                        edit.grab_focus();
                    }
                    _ => panic!("Unknown private fixture command"),
                }
                *pending.borrow_mut() = Some(command);
                dirty.set(true);
                timer_window.queue_draw();
                timer_clock.request_phase(
                    gtk::gdk::FrameClockPhase::LAYOUT | gtk::gdk::FrameClockPhase::PAINT,
                );
            }
        }
        if !ready.get() || dirty.get() {
            return glib::ControlFlow::Continue;
        }
        let allocation = button.allocation();
        let point = button
            .translate_coordinates(
                &timer_window,
                allocation.width() / 2,
                allocation.height() / 2,
            )
            .unwrap();
        let value = json!({"pid":std::process::id(),"window":xid,"text":edit.text().as_str(),"clicks":clicks.get(),"command":*sequence.borrow(),"pointX":point.0,"pointY":point.1});
        std::fs::write(root.join("next.json"), serde_json::to_vec(&value).unwrap()).unwrap();
        std::fs::rename(root.join("next.json"), root.join("state.json")).unwrap();
        glib::ControlFlow::Continue
    });
    gtk::main();
    clock.disconnect(paint_handler);
    window.close();
}
// Closing uses the same atomic publication as ordinary commands: truncating
// the live file can expose an empty/partial command to GTK's frame callback.
fn publish_command(root: &std::path::Path, command: &str) -> std::io::Result<()> {
    std::fs::write(root.join("command-next"), command)?;
    std::fs::rename(root.join("command-next"), root.join("command"))
}

#[test]
fn private_command_publication_never_exposes_partial_frames() {
    let root = tempfile::tempdir().unwrap();
    publish_command(root.path(), "focus-password").unwrap();
    let reading = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
    let shared = reading.clone();
    let folder = root.path().to_owned();
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
    let ready = barrier.clone();
    let reader = std::thread::spawn(move || {
        ready.wait();
        let mut frames = 0;
        while shared.load(std::sync::atomic::Ordering::Acquire) {
            let command = std::fs::read_to_string(folder.join("command")).unwrap();
            assert!(matches!(command.as_str(), "focus-password" | "close"));
            frames += 1;
        }
        frames
    });
    barrier.wait();
    for _ in 0..1000 {
        publish_command(root.path(), "close").unwrap();
        publish_command(root.path(), "focus-password").unwrap();
    }
    reading.store(false, std::sync::atomic::Ordering::Release);
    assert!(reader.join().unwrap() > 0);
}

struct Fixture {
    root: PathBuf,
    child: Option<Child>,
    runtime: Option<Runtime>,
    complete: bool,
}
impl Fixture {
    fn state(&self) -> Option<Value> {
        serde_json::from_slice(&std::fs::read(self.root.join("state.json")).ok()?).ok()
    }
    fn command(&self, command: &str) {
        publish_command(&self.root, command).unwrap();
        wait("owned child command acknowledgement", || {
            self.state().filter(|s| s["command"] == command)
        });
    }
    fn request(&self, thread: Uuid, name: &str, args: Value) -> Result<Value, Failure> {
        let runtime = self.runtime.as_ref().unwrap();
        let request = Request::parse(
            &serde_json::to_vec(&json!({"action":"call","name":name,"arguments":args})).unwrap(),
        )?;
        let id = runtime.handle().try_request(thread, request)?;
        wait("actual CU worker response", || match runtime.try_reply() {
            Ok(reply) => {
                assert_eq!(reply.id, id);
                assert_eq!(reply.thread, thread);
                Some(reply.result)
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => None,
            Err(_) => panic!("Owned CU worker disconnected"),
        })
    }
    fn observe(&self, thread: Uuid, screen: bool) -> Result<Value, Failure> {
        let s = self.state().unwrap();
        self.request(thread,"get_window_state",json!({"pid":s["pid"],"window_id":s["window"],"max_elements":128,"include_screenshot":screen}))
    }
    fn drain(&mut self) {
        if let Some(runtime) = &mut self.runtime {
            runtime.request_shutdown();
            wait("actual CU worker destructor/socket join", || {
                let status = runtime.shutdown_status();
                (status.worker == WorkerThreadStatus::Returned
                    && status.pending_reservations == Some(0))
                .then_some(())
            });
        }
        self.runtime = None;
        if let Some(child) = &mut self.child {
            publish_command(&self.root, "close").unwrap();
            assert!(child.wait().unwrap().success());
        }
        self.child = None;
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        // Unwinding must not mask the original assertion with a cleanup panic.
        if let Some(runtime) = self.runtime.as_mut() {
            runtime.request_shutdown();
            let deadline = Instant::now() + Duration::from_secs(12);
            while Instant::now() < deadline {
                if runtime.shutdown_status().worker == WorkerThreadStatus::Returned {
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        if let Some(child) = self.child.as_mut() {
            let _ = publish_command(&self.root, "close");
            // The owned child also has an unconditional 60 second exit. Never
            // force-kill it or remove its files before actual process return.
            let _ = child.wait();
        }
        self.child = None;
        self.runtime = None;
        if self.complete {
            let _ = std::fs::remove_dir_all(&self.root);
        } else {
            if let Ok(log) = std::fs::read_to_string(self.root.join("child.log")) {
                eprintln!(
                    "Owned GTK child: {}",
                    log.chars().take(8192).collect::<String>()
                );
            }
            eprintln!(
                "Private owned Linux CU fixture retained: {}",
                self.root.display()
            );
        }
    }
}
fn token(snapshot: &Value, role: &str, title: Option<&str>) -> Value {
    let elements = snapshot["elements"].as_array().unwrap();
    let Some(node) = elements
        .iter()
        .find(|n| n["role"] == role && title.is_none_or(|title| n["title"] == title))
    else {
        // Roles and titles only; values may hold fixture input.
        let seen: Vec<_> = elements.iter().map(|n| (&n["role"], &n["title"])).collect();
        panic!("actual owned GTK accessible node {role} {title:?} absent from {seen:?}");
    };
    node["element_token"].clone()
}
#[test]
#[ignore = "explicit fresh GHA/private DBus/Xvfb owned GTK acceptance only"]
fn actual_owned_x11_window_actions_capture_and_drain() {
    fresh_runner();
    assert!(std::env::var_os("WAYLAND_DISPLAY").is_none());
    let root = std::env::temp_dir().join(format!("coincide-linux-cu-owned-{}", Uuid::new_v4()));
    native_file::private_directory(&root).unwrap();
    let mut owner = Fixture {
        root,
        child: None,
        runtime: None,
        complete: false,
    };
    let mut command = Command::new(std::env::current_exe().unwrap());
    command.env_clear();
    for key in [
        "PATH",
        "DISPLAY",
        "XAUTHORITY",
        "DBUS_SESSION_BUS_ADDRESS",
        "XDG_RUNTIME_DIR",
    ] {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    for key in ["HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"] {
        let path = owner.root.join(key);
        native_file::private_directory(&path).unwrap();
        command.env(key, path);
    }
    let log = std::fs::File::create(owner.root.join("child.log")).unwrap();
    command
        .env("GITHUB_ACTIONS", "true")
        .env("COINCIDE_LINUX_CU_CI", MARKER)
        .env("COINCIDE_LINUX_CU_ROOT", &owner.root)
        .env("GTK_MODULES", "atk-bridge")
        .env("GTK_A11Y", "always")
        .arg("--ignored")
        .arg("--exact")
        .arg("computer_use::linux::native_tests::owned_gtk_child")
        .arg("--nocapture")
        .arg("--test-threads=1")
        .stdout(Stdio::from(log.try_clone().unwrap()))
        .stderr(Stdio::from(log));
    owner.child = Some(command.spawn().unwrap());
    let state = wait("owned GTK published native window", || owner.state());
    assert_eq!(
        state["pid"].as_u64(),
        Some(u64::from(owner.child.as_ref().unwrap().id()))
    );
    owner.runtime = Some(Runtime::spawn_native().unwrap());
    let handle = owner.runtime.as_ref().unwrap().handle();
    handle.native_enable(true).unwrap();
    let thread = Uuid::new_v4();
    handle.native_grant(thread).unwrap();
    // Await initial AT-SPI registration only; mutations below are each sent once.
    let initial = wait(
        "actual owned GTK accessibility registration",
        || match owner.observe(thread, false) {
            Ok(value) => Some(value),
            Err(Failure::PermissionDenied | Failure::Native) => None,
            Err(error) => panic!("Unexpected native registration failure: {error:?}"),
        },
    );
    assert!(
        initial["elements"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["secure"] == true && n["title"] == "" && n["value"].is_null())
    );
    assert!(!initial.to_string().contains("synthetic-private-password"));
    assert_eq!(
        owner.observe(thread, true).err(),
        Some(Failure::PermissionDenied)
    );
    owner.command("focus-password");
    assert_eq!(
        owner.observe(thread, false).err(),
        Some(Failure::PermissionDenied)
    );
    owner.command("hide-password");
    let observed = owner.observe(thread, false).unwrap();
    owner.request(thread,"set_value",json!({"element_token":token(&observed,"Text",Some("Owned edit")),"text":"native edited 🦀"})).unwrap();
    wait("actual GTK edit receipt", || {
        owner.state().filter(|s| s["text"] == "native edited 🦀")
    });
    let observed = owner.observe(thread, false).unwrap();
    owner
        .request(
            thread,
            "click",
            json!({"element_token":token(&observed,"Button",Some("Owned action"))}),
        )
        .unwrap();
    wait("actual GTK button receipt", || {
        owner.state().filter(|s| s["clicks"] == 1)
    });
    owner.command("focus-edit");
    let observed = owner.observe(thread, false).unwrap();
    owner
        .request(
            thread,
            "press_key",
            json!({"element_token":token(&observed,"Text",Some("Owned edit")),"key":"backspace"}),
        )
        .unwrap();
    wait("actual native key receipt", || {
        owner.state().filter(|s| s["text"] != "native edited 🦀")
    });
    let observed = owner.observe(thread, true).unwrap();
    assert_eq!(observed["screenshot"]["encoding"], "png_base64");
    assert!(observed["screenshot"]["width"].as_u64().unwrap() > 100);
    let state = owner.state().unwrap();
    owner
        .request(
            thread,
            "click_point",
            json!({"observation":observed["observation"],"x":state["pointX"],"y":state["pointY"]}),
        )
        .unwrap();
    wait("actual native pointer receipt", || {
        owner.state().filter(|s| s["clicks"] == 2)
    });
    let stale = owner.observe(thread, false).unwrap();
    owner.command("move");
    assert_eq!(
        owner
            .request(
                thread,
                "click",
                json!({"element_token":token(&stale,"Button",Some("Owned action"))})
            )
            .err(),
        Some(Failure::StaleObservation)
    );
    let observed = owner.observe(thread, false).unwrap();
    handle.native_revoke(thread);
    assert_eq!(
        owner
            .request(
                thread,
                "click",
                json!({"element_token":token(&observed,"Button",Some("Owned action"))})
            )
            .err(),
        Some(Failure::NotGranted)
    );
    assert_eq!(owner.state().unwrap()["clicks"], 2);
    owner.drain();
    owner.complete = true;
}

#[test]
#[ignore = "explicit fresh GHA synthetic Wayland marker with private Xvfb only"]
fn actual_wayland_refuses_existing_x11_display() {
    use super::{Backend, NativeBackend};
    use coincide_core::computer_use::Permission;
    fresh_runner();
    assert_eq!(
        std::env::var("WAYLAND_DISPLAY").as_deref(),
        Ok("coincide-private-wayland")
    );
    let mut backend = NativeBackend::default();
    let permissions = backend.permissions().unwrap();
    assert_eq!(permissions.accessibility, Permission::Unsupported);
    assert_eq!(permissions.screen_capture, Permission::Unsupported);
    assert!(backend.observed.is_none());
}
