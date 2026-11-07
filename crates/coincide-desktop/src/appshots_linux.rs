//! X11 window-only Appshots. XComposite supplies the selected window's own
//! backing pixmap; there is deliberately no root/screen fallback. Wayland does
//! not expose an automatic front-window capture/input API, so this adapter
//! reports that limitation instead of treating an XWayland window as the desktop.
use super::{Capture, Permissions};
use anyhow::{Context, Result, bail, ensure};
use atspi::{Role, State, StateSet, proxy::accessible::AccessibleProxyBlocking};
use std::{
    cell::Cell,
    collections::HashSet,
    io,
    os::fd::AsRawFd,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};
use x11rb::{
    connection::Connection,
    protocol::{
        Event,
        composite::ConnectionExt as _,
        xinput::{self, ConnectionExt as _},
        xproto::*,
    },
    reexports::x11rb_protocol::{parse_display, xauth},
    rust_connection::{DefaultStream, PollMode, RustConnection, Stream},
    utils::RawFdContainer,
};

const WAYLAND: &str = "Automatic Appshots requires an X11 session. Wayland requires a window selection portal; automatic front-window capture is unavailable in this build.";
static INPUT: Mutex<Option<InputOwner>> = Mutex::new(None);
static PENDING: AtomicBool = AtomicBool::new(false);

struct InputOwner {
    stop: Arc<AtomicBool>,
    worker: JoinHandle<()>,
}

fn x11_session() -> bool {
    std::env::var_os("WAYLAND_DISPLAY").is_none()
        && !std::env::var("XDG_SESSION_TYPE").is_ok_and(|value| value == "wayland")
}

/// All X requests, including setup, have a shared deadline and cancellation
/// check. A stopped display must not leave a capture/input worker in reply().
struct BoundedStream<'a> {
    inner: DefaultStream,
    allowed: &'a dyn Fn() -> bool,
    deadline: Cell<Instant>,
}
impl Stream for BoundedStream<'_> {
    fn poll(&self, mode: PollMode) -> io::Result<()> {
        loop {
            self.check()?;
            let mut fd = libc::pollfd {
                fd: self.inner.as_raw_fd(),
                events: (if mode.readable() { libc::POLLIN } else { 0 })
                    | (if mode.writable() { libc::POLLOUT } else { 0 }),
                revents: 0,
            };
            // SAFETY: fd points to one live pollfd; the stream owns its socket
            // for this call and a 20 ms wakeup bounds cancellation latency.
            let status = unsafe { libc::poll(&mut fd, 1, 20) };
            if status > 0 {
                return Ok(());
            }
            if status < 0 {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return Err(error);
                }
            }
        }
    }
    fn read(&self, buf: &mut [u8], fds: &mut Vec<RawFdContainer>) -> io::Result<usize> {
        self.check()?;
        self.inner.read(buf, fds)
    }
    fn write(&self, buf: &[u8], fds: &mut Vec<RawFdContainer>) -> io::Result<usize> {
        self.check()?;
        self.inner.write(buf, fds)
    }
}
impl BoundedStream<'_> {
    fn check(&self) -> io::Result<()> {
        if !(self.allowed)() || Instant::now() >= self.deadline.get() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "Appshot X11 request cancelled or timed out",
            ));
        }
        Ok(())
    }
}
type XConnection<'a> = RustConnection<BoundedStream<'a>>;

fn connect(allowed: &dyn Fn() -> bool) -> Result<(XConnection<'_>, usize)> {
    ensure!(x11_session(), "{WAYLAND}");
    ensure!(allowed(), "Appshot cancelled");
    let parsed = parse_display::parse_display(None).context("No X11 display is available")?;
    // A local desktop feature must not create an unbounded remote TCP connect.
    let mut last = None;
    for address in parsed.connect_instruction() {
        if !matches!(address, parse_display::ConnectAddress::Socket(_)) {
            continue;
        }
        match DefaultStream::connect(&address) {
            Ok((stream, (family, address))) => {
                let (auth_name, auth_data) =
                    xauth::get_auth(family, &address, parsed.display)?.unwrap_or_default();
                let stream = BoundedStream {
                    inner: stream,
                    allowed,
                    deadline: Cell::new(Instant::now() + Duration::from_millis(400)),
                };
                let screen = usize::from(parsed.screen);
                let connection = RustConnection::connect_to_stream_with_auth_info(
                    stream, screen, auth_name, auth_data,
                )?;
                return Ok((connection, screen));
            }
            Err(error) => last = Some(error),
        }
    }
    bail!(
        "Could not connect to the local X11 display{}",
        if last.is_some() {
            " socket"
        } else {
            " (remote displays are unsupported)"
        }
    )
}

/// Permission-free idle/display observations; no hook, pixels or window text.
pub(super) fn notification_activity() -> crate::notification_activity::Observation {
    use x11rb::protocol::{dpms, screensaver};
    let mut observed = crate::notification_activity::Observation::default();
    let allowed = || true;
    if let Ok((connection, screen)) = connect(&allowed) {
        let root = connection.setup().roots[screen].root;
        if let Ok(cookie) = screensaver::query_info(&connection, root)
            && let Ok(reply) = cookie.reply()
        {
            observed.idle_seconds = Some(u64::from(reply.ms_since_user_input) / 1000);
        }
        if let Ok(cookie) = dpms::info(&connection)
            && let Ok(reply) = cookie.reply()
        {
            observed.display_asleep = Some(reply.state && reply.power_level != dpms::DPMSMode::ON);
        }
    }
    observed
}

pub(super) fn configure(shortcut: Option<&str>) -> Result<()> {
    stop();
    ensure!(x11_session(), "{WAYLAND}");
    if let Some(shortcut) = shortcut {
        ensure!(
            coincide_core::appshots::valid_shortcut(shortcut),
            "Unsupported Appshots shortcut"
        );
    }
    let shortcut = shortcut.map(str::to_owned);
    let cancelled = Arc::new(AtomicBool::new(false));
    let cancel = cancelled.clone();
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    let worker = thread::Builder::new()
        .name("appshots-x11-input".into())
        .spawn(move || {
            let allowed = || !cancel.load(Ordering::Acquire);
            let result = (|| -> Result<_> {
                let (connection, screen) = connect(&allowed)?;
                let root = connection.setup().roots[screen].root;
                connection.xinput_xi_query_version(2, 0)?.reply()?;
                connection
                    .xinput_xi_select_events(
                        root,
                        &[xinput::EventMask {
                            deviceid: xinput::Device::ALL_MASTER.into(),
                            mask: vec![
                                xinput::XIEventMask::RAW_KEY_PRESS
                                    | xinput::XIEventMask::RAW_KEY_RELEASE,
                            ],
                        }],
                    )?
                    .check()?;
                let first = connection.setup().min_keycode;
                let count = connection.setup().max_keycode - first + 1;
                let mapping = connection.get_keyboard_mapping(first, count)?.reply()?;
                let keys = KeyMap::new(first, &mapping, shortcut.as_deref())?;
                let initial = connection.query_keymap()?.reply()?.keys;
                let keyboard = KeyboardState::new(initial, &keys);
                Ok((connection, keys, keyboard))
            })();
            let Ok((connection, mut keys, mut keyboard)) = result else {
                let _ = tx.send(Err("Could not read the X11 keyboard map".to_owned()));
                return;
            };
            if tx.send(Ok(())).is_err() {
                return;
            }
            while allowed() {
                connection
                    .stream()
                    .deadline
                    .set(Instant::now() + Duration::from_millis(200));
                // Read the event sequence, not periodic pressed-key snapshots:
                // a short intervening key must still block a modifier chord.
                for _ in 0..512 {
                    if !allowed() {
                        break;
                    }
                    let event = match connection.poll_for_event() {
                        Ok(Some(event)) => event,
                        Ok(None) => break,
                        Err(_) => return,
                    };
                    let transition = match event {
                        Event::XinputRawKeyPress(event)
                            if event.flags & xinput::KeyEventFlags::KEY_REPEAT
                                == xinput::KeyEventFlags::default() =>
                        {
                            u8::try_from(event.detail).ok().map(|key| (key, true))
                        }
                        Event::XinputRawKeyRelease(event) => {
                            u8::try_from(event.detail).ok().map(|key| (key, false))
                        }
                        Event::MappingNotify(_) => {
                            let mapping = (|| -> Result<_> {
                                let first = connection.setup().min_keycode;
                                let count = connection.setup().max_keycode - first + 1;
                                let mapping =
                                    connection.get_keyboard_mapping(first, count)?.reply()?;
                                let keys = KeyMap::new(first, &mapping, shortcut.as_deref())?;
                                let state = KeyboardState::new(
                                    connection.query_keymap()?.reply()?.keys,
                                    &keys,
                                );
                                Ok((keys, state))
                            })();
                            match mapping {
                                Ok((map, state)) => {
                                    keys = map;
                                    keyboard = state;
                                }
                                Err(_) => return,
                            }
                            None
                        }
                        _ => None,
                    };
                    if transition.is_some_and(|(key, down)| keyboard.event(key, down, &keys)) {
                        PENDING.store(true, Ordering::Release);
                    }
                }
                thread::sleep(Duration::from_millis(20));
            }
        })?;
    *INPUT
        .lock()
        .map_err(|_| anyhow::anyhow!("Appshots input owner unavailable"))? = Some(InputOwner {
        stop: cancelled,
        worker,
    });
    match rx.recv_timeout(Duration::from_millis(650)) {
        Ok(Ok(())) => Ok(()),
        result => {
            stop();
            bail!(
                "{}",
                result
                    .ok()
                    .and_then(Result::err)
                    .unwrap_or_else(|| "X11 shortcut setup timed out".into())
            )
        }
    }
}
pub(super) fn stop() {
    let owner = INPUT.lock().ok().and_then(|mut value| value.take());
    if let Some(owner) = owner {
        owner.stop.store(true, Ordering::Release);
        let _ = owner.worker.join();
    }
    PENDING.store(false, Ordering::Release);
}
pub(super) fn triggered() -> bool {
    PENDING.swap(false, Ordering::AcqRel)
}

struct KeyboardState {
    down: [u8; 32],
    both: coincide_core::appshots::BothPrimary,
    chord_down: bool,
}
impl KeyboardState {
    fn new(down: [u8; 32], keys: &KeyMap) -> Self {
        let mut both = coincide_core::appshots::BothPrimary::default();
        let pressed = |key: u8| key != 0 && down[usize::from(key / 8)] & (1 << (key % 8)) != 0;
        if !pressed(keys.control[0]) && !pressed(keys.control[1]) {
            both.update(false, false, false);
        }
        Self {
            chord_down: keys
                .chord
                .as_ref()
                .is_some_and(|chord| chord.matches(&down, keys)),
            down,
            both,
        }
    }
    fn event(&mut self, key: u8, pressed: bool, keys: &KeyMap) -> bool {
        if key < 8 {
            return false;
        }
        let byte = &mut self.down[usize::from(key / 8)];
        if pressed {
            *byte |= 1 << (key % 8);
        } else {
            *byte &= !(1 << (key % 8));
        }
        if let Some(chord) = &keys.chord {
            let down = chord.matches(&self.down, keys);
            let fire = pressed && key == chord.key && down && !self.chord_down;
            self.chord_down = down;
            fire
        } else {
            let down =
                |key: u8| key != 0 && self.down[usize::from(key / 8)] & (1 << (key % 8)) != 0;
            let other = (8..=255).any(|key| down(key) && !keys.control.contains(&key));
            self.both
                .update(down(keys.control[0]), down(keys.control[1]), other)
        }
    }
}
struct KeyMap {
    control: [u8; 2],
    shift: [u8; 2],
    alt: [u8; 2],
    super_keys: [u8; 2],
    chord: Option<Chord>,
}
struct Chord {
    key: u8,
    shift: bool,
    alt: bool,
}
impl KeyMap {
    fn new(first: u8, mapping: &GetKeyboardMappingReply, shortcut: Option<&str>) -> Result<Self> {
        let code = |symbol: u32| -> u8 {
            mapping
                .keysyms
                .chunks(usize::from(mapping.keysyms_per_keycode).max(1))
                .position(|row| row.contains(&symbol))
                .and_then(|index| u8::try_from(index).ok())
                .and_then(|index| first.checked_add(index))
                .unwrap_or(0)
        };
        let chord = shortcut
            .map(|shortcut| -> Result<Chord> {
                let key = shortcut
                    .split('+')
                    .find(|part| part.len() == 1)
                    .context("Shortcut key is missing")?
                    .to_ascii_lowercase();
                let key = code(u32::from(key.as_bytes()[0]));
                ensure!(
                    key != 0,
                    "Shortcut key is unavailable in this keyboard layout"
                );
                Ok(Chord {
                    key,
                    shift: shortcut.split('+').any(|s| s == "shift"),
                    alt: shortcut.split('+').any(|s| s == "alt"),
                })
            })
            .transpose()?;
        let result = Self {
            control: [code(0xffe3), code(0xffe4)],
            shift: [code(0xffe1), code(0xffe2)],
            alt: [code(0xffe9), code(0xffea)],
            super_keys: [code(0xffeb), code(0xffec)],
            chord,
        };
        ensure!(
            result.control.iter().all(|key| *key != 0),
            "Both Control keys must be present in the X11 keyboard map"
        );
        Ok(result)
    }
}
impl Chord {
    fn matches(&self, bits: &[u8; 32], keys: &KeyMap) -> bool {
        let down = |key: u8| key != 0 && bits[usize::from(key / 8)] & (1 << (key % 8)) != 0;
        down(self.key)
            && keys.control.iter().copied().any(down)
            && keys.shift.iter().copied().any(down) == self.shift
            && keys.alt.iter().copied().any(down) == self.alt
            && !keys.super_keys.iter().copied().any(down)
            && (8..=255).all(|key| {
                !down(key)
                    || key == self.key
                    || keys.control.contains(&key)
                    || (self.shift && keys.shift.contains(&key))
                    || (self.alt && keys.alt.contains(&key))
            })
    }
}

pub(super) fn permissions(_action: u8) -> Permissions {
    if !x11_session() {
        return Permissions {
            detail: WAYLAND.into(),
            ..Default::default()
        };
    }
    // X11 has no separate OS consent panel. Do not turn on a screen reader or
    // change session accessibility settings from a permission-refresh button.
    let screen = connect(&|| true).is_ok_and(|(connection, _)| {
        connection
            .query_extension(b"Composite")
            .ok()
            .and_then(|c| c.reply().ok())
            .is_some_and(|r| r.present)
    });
    let accessibility = accessibility_bus().is_ok();
    Permissions { screen, accessibility, detail: "X11 captures only a composited app window. Window text and password detection use the app’s AT-SPI accessibility tree when available. Enable accessibility in your desktop settings if text is unavailable.".into() }
}

fn atom(connection: &XConnection<'_>, name: &[u8]) -> Result<Atom> {
    Ok(connection.intern_atom(false, name)?.reply()?.atom)
}
fn property(
    connection: &XConnection<'_>,
    window: Window,
    name: &[u8],
    kind: AtomEnum,
) -> Result<GetPropertyReply> {
    Ok(connection
        .get_property(false, window, atom(connection, name)?, kind, 0, 2048)?
        .reply()?)
}
fn active_window(connection: &XConnection<'_>, root: Window) -> Result<Window> {
    let property = property(connection, root, b"_NET_ACTIVE_WINDOW", AtomEnum::WINDOW)?;
    let window = property
        .value32()
        .and_then(|mut values| values.next())
        .context("The window manager did not identify a front window")?;
    ensure!(
        window != 0 && window != root,
        "The desktop is not an app window"
    );
    Ok(window)
}
fn owner_pid(connection: &XConnection<'_>, window: Window) -> Result<u32> {
    let property = property(connection, window, b"_NET_WM_PID", AtomEnum::CARDINAL)?;
    let pid = property
        .value32()
        .and_then(|mut values| values.next())
        .context("The window has no process identity")?;
    ensure!(pid > 0, "The window has no process identity");
    Ok(pid)
}
fn target_window(connection: &XConnection<'_>, root: Window) -> Result<(Window, Window)> {
    let front = active_window(connection, root)?;
    if eligible_window(connection, front)? {
        return Ok((front, front));
    }
    let stacking = property(
        connection,
        root,
        b"_NET_CLIENT_LIST_STACKING",
        AtomEnum::WINDOW,
    )?;
    let windows: Vec<_> = stacking
        .value32()
        .context("The window stacking order is unavailable")?
        .collect();
    for window in windows.into_iter().rev().take(512) {
        connection.stream().check()?;
        if eligible_window(connection, window)? {
            return Ok((front, window));
        }
    }
    bail!("No other eligible app window is available")
}
fn eligible_window(connection: &XConnection<'_>, window: Window) -> Result<bool> {
    let Ok(pid) = owner_pid(connection, window) else {
        return Ok(false);
    };
    if pid == std::process::id() {
        return Ok(false);
    }
    let Ok(attributes) = connection.get_window_attributes(window)?.reply() else {
        return Ok(false);
    };
    let Ok(geometry) = connection.get_geometry(window)?.reply() else {
        return Ok(false);
    };
    Ok(attributes.map_state == MapState::VIEWABLE
        && !attributes.override_redirect
        && geometry.width >= 40
        && geometry.height >= 40
        && eligible_type(connection, window)?)
}
fn eligible_type(connection: &XConnection<'_>, window: Window) -> Result<bool> {
    let types = property(connection, window, b"_NET_WM_WINDOW_TYPE", AtomEnum::ATOM)?;
    let Some(types) = types.value32() else {
        return Ok(true);
    };
    let normal = atom(connection, b"_NET_WM_WINDOW_TYPE_NORMAL")?;
    let dialog = atom(connection, b"_NET_WM_WINDOW_TYPE_DIALOG")?;
    let types: Vec<_> = types.collect();
    Ok(types.is_empty()
        || types
            .into_iter()
            .all(|kind| kind == normal || kind == dialog))
}

pub(super) fn capture(read_text: bool, allowed: &dyn Fn() -> bool) -> Result<Capture> {
    let (connection, screen) = connect(allowed)?;
    connection
        .stream()
        .deadline
        .set(Instant::now() + Duration::from_secs(6));
    let root = connection.setup().roots[screen].root;
    let (front, window) = target_window(&connection, root)?;
    let pid = owner_pid(&connection, window)?;
    let attributes = connection.get_window_attributes(window)?.reply()?;
    ensure!(
        attributes.map_state == MapState::VIEWABLE
            && !attributes.override_redirect
            && eligible_type(&connection, window)?,
        "The front window is not an eligible app window"
    );
    for name in [
        b"_NET_WM_CONTENT_PROTECTION".as_slice(),
        b"_NET_WM_PROTECTED_CONTENT".as_slice(),
    ] {
        let protected = property(&connection, window, name, AtomEnum::ANY)?;
        ensure!(
            protected.value.is_empty() || protected.value.iter().all(|byte| *byte == 0),
            "The app marked this window as protected"
        );
    }
    let geometry = connection.get_geometry(window)?.reply()?;
    ensure!(
        geometry.width >= 40
            && geometry.height >= 40
            && u64::from(geometry.width) * u64::from(geometry.height) <= 16_000_000,
        "Window dimensions exceed capture limits"
    );
    let origin = connection
        .translate_coordinates(window, root, 0, 0)?
        .reply()?;
    let frame = (
        i32::from(origin.dst_x),
        i32::from(origin.dst_y),
        i32::from(geometry.width),
        i32::from(geometry.height),
    );
    let text = inspect_accessibility(pid, frame, read_text, allowed)?;
    ensure!(allowed(), "Appshot cancelled");
    ensure!(
        target_window(&connection, root)? == (front, window)
            && owner_pid(&connection, window)? == pid,
        "The front window changed before capture"
    );
    let pixmap = connection.generate_id()?;
    connection.composite_query_version(0, 2)?.reply()?;
    connection
        .composite_name_window_pixmap(window, pixmap)?
        .check()
        .context("This window has no composited backing image; enable your X11 compositor")?;
    let result = (|| -> Result<_> {
        let image = connection
            .get_image(
                ImageFormat::Z_PIXMAP,
                pixmap,
                0,
                0,
                geometry.width,
                geometry.height,
                u32::MAX,
            )?
            .reply()?;
        let visual = connection.setup().roots[screen]
            .allowed_depths
            .iter()
            .flat_map(|d| d.visuals.iter())
            .find(|v| v.visual_id == attributes.visual)
            .context("The window visual is unavailable")?;
        let format = connection
            .setup()
            .pixmap_formats
            .iter()
            .find(|f| f.depth == geometry.depth)
            .context("Unsupported window pixel format")?;
        let rgba = rgba_pixels(
            &image.data,
            geometry.width,
            geometry.height,
            format,
            visual,
            connection.setup().image_byte_order,
        )?;
        ensure!(allowed(), "Appshot cancelled");
        let png = coincide_core::appshots::encode_rgba(
            u32::from(geometry.width),
            u32::from(geometry.height),
            rgba,
        )?;
        let title_property = property(&connection, window, b"_NET_WM_NAME", AtomEnum::ANY)?;
        let title = String::from_utf8_lossy(&title_property.value)
            .trim_matches('\0')
            .trim()
            .to_owned();
        let class = property(&connection, window, b"WM_CLASS", AtomEnum::STRING)?;
        let app = class
            .value
            .split(|byte| *byte == 0)
            .filter(|part| !part.is_empty())
            .next_back()
            .map(|part| String::from_utf8_lossy(part).into_owned())
            .filter(|part| !part.is_empty())
            .unwrap_or_else(|| "the app".into());
        inspect_accessibility(pid, frame, false, allowed)?;
        ensure!(
            allowed()
                && target_window(&connection, root)? == (front, window)
                && owner_pid(&connection, window)? == pid,
            "The front window changed during capture"
        );
        Ok(Capture {
            png,
            app,
            title: (!title.is_empty()).then_some(title),
            text,
        })
    })();
    // The X connection owns this named pixmap and also frees it on disconnect.
    let _ = connection.free_pixmap(pixmap);
    let _ = connection.flush();
    result
}

fn rgba_pixels(
    data: &[u8],
    width: u16,
    height: u16,
    format: &Format,
    visual: &Visualtype,
    order: ImageOrder,
) -> Result<Vec<u8>> {
    ensure!(
        matches!(format.bits_per_pixel, 16 | 24 | 32) && matches!(format.scanline_pad, 8 | 16 | 32),
        "Unsupported X11 pixel format"
    );
    ensure!(
        visual.class == VisualClass::TRUE_COLOR,
        "Indexed X11 visuals cannot be captured"
    );
    let bits = usize::from(format.bits_per_pixel);
    let pad = usize::from(format.scanline_pad);
    let stride = (usize::from(width) * bits).div_ceil(pad) * pad / 8;
    ensure!(
        data.len() == stride * usize::from(height),
        "Invalid X11 image length"
    );
    let masks = [visual.red_mask, visual.green_mask, visual.blue_mask];
    ensure!(
        masks.iter().all(|mask| *mask != 0)
            && masks[0] & masks[1] == 0
            && masks[0] & masks[2] == 0
            && masks[1] & masks[2] == 0,
        "Invalid X11 color masks"
    );
    let mut rgba = Vec::with_capacity(usize::from(width) * usize::from(height) * 4);
    for row in data.chunks_exact(stride) {
        for column in 0..usize::from(width) {
            let mut bytes = [0; 4];
            let pixel = &row[column * (bits / 8)..(column + 1) * (bits / 8)];
            let value = if order == ImageOrder::LSB_FIRST {
                bytes[..pixel.len()].copy_from_slice(pixel);
                u32::from_le_bytes(bytes)
            } else {
                bytes[4 - pixel.len()..].copy_from_slice(pixel);
                u32::from_be_bytes(bytes)
            };
            for mask in masks {
                let component = (value & mask) >> mask.trailing_zeros();
                let maximum = mask >> mask.trailing_zeros();
                rgba.push(
                    ((u64::from(component) * 255 + u64::from(maximum) / 2) / u64::from(maximum))
                        as u8,
                );
            }
            rgba.push(255);
        }
    }
    Ok(rgba)
}

fn bounded_text(text: &str, limit: usize) -> String {
    let end = text
        .char_indices()
        .find(|(index, ch)| index + ch.len_utf8() > limit)
        .map(|(index, _)| index)
        .unwrap_or(text.len());
    text[..end].to_owned()
}

fn accessibility_bus() -> Result<zbus::blocking::Connection> {
    let session = zbus::blocking::connection::Builder::session()?
        .method_timeout(Duration::from_millis(150))
        .build()?;
    let proxy =
        zbus::blocking::Proxy::new(&session, "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus")?;
    let address: String = proxy.call("GetAddress", &())?;
    let connection = zbus::blocking::connection::Builder::address(address.as_str())?
        .method_timeout(Duration::from_millis(150))
        .build()?;
    session.close()?;
    Ok(connection)
}

type Object = (String, zbus::zvariant::OwnedObjectPath);
fn accessible<'a>(
    bus: &'a zbus::blocking::Connection,
    object: &'a Object,
) -> Result<AccessibleProxyBlocking<'a>> {
    Ok(AccessibleProxyBlocking::builder(bus)
        .destination(object.0.as_str())?
        .path(object.1.as_str())?
        .cache_properties(zbus::proxy::CacheProperties::No)
        .build()?)
}
fn object(reference: atspi::ObjectRefOwned) -> Option<Object> {
    Some((
        reference.name_as_str()?.into(),
        reference.path().to_owned().into(),
    ))
}
fn children(
    proxy: &AccessibleProxyBlocking<'_>,
    deadline: Instant,
    allowed: &dyn Fn() -> bool,
) -> Result<Vec<Object>> {
    // Fetch bounded children individually; a giant application tree must not
    // allocate an unbounded GetChildren reply before the traversal limit.
    let count = proxy.child_count()?.clamp(0, 6000);
    let mut children = Vec::new();
    for index in 0..count {
        if !allowed() || Instant::now() >= deadline {
            break;
        }
        if let Some(child) = object(proxy.get_child_at_index(index)?) {
            children.push(child);
        }
    }
    Ok(children)
}

fn inspect_accessibility(
    pid: u32,
    frame: (i32, i32, i32, i32),
    read_text: bool,
    allowed: &dyn Fn() -> bool,
) -> Result<Option<String>> {
    let Ok(bus) = accessibility_bus() else {
        return Ok(None);
    };
    let result = (|| -> Result<Option<String>> {
        let deadline = Instant::now() + Duration::from_millis(1500);
        let dbus = zbus::blocking::Proxy::new(
            &bus,
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
        )?;
        let registry = AccessibleProxyBlocking::builder(&bus)
            .destination("org.a11y.atspi.Registry")?
            .cache_properties(zbus::proxy::CacheProperties::No)
            .build()?;
        let mut selected = None;
        for app in children(&registry, deadline, allowed)? {
            if !allowed() || Instant::now() >= deadline {
                break;
            }
            let process: u32 = match dbus.call("GetConnectionUnixProcessID", &(app.0.as_str(),)) {
                Ok(pid) => pid,
                Err(_) => continue,
            };
            if process != pid {
                continue;
            }
            for window in children(&accessible(&bus, &app)?, deadline, allowed)? {
                if !allowed() || Instant::now() >= deadline {
                    break;
                }
                let component = zbus::blocking::Proxy::new(
                    &bus,
                    window.0.as_str(),
                    window.1.as_str(),
                    "org.a11y.atspi.Component",
                )?;
                let Ok(bounds): Result<(i32, i32, i32, i32), _> =
                    component.call("GetExtents", &(0u32,))
                else {
                    continue;
                };
                drop(component);
                if [
                    bounds.0.abs_diff(frame.0),
                    bounds.1.abs_diff(frame.1),
                    bounds.2.abs_diff(frame.2),
                    bounds.3.abs_diff(frame.3),
                ]
                .iter()
                .all(|d| *d <= 4)
                {
                    ensure!(
                        selected.is_none(),
                        "The accessibility window identity is ambiguous"
                    );
                    selected = Some(window);
                }
            }
        }
        let Some(selected) = selected else {
            return Ok(None);
        };
        let mut pending = vec![selected];
        let mut seen = HashSet::new();
        let mut pieces = Vec::<String>::new();
        let mut length = 0;
        while let Some(node) = pending.pop() {
            ensure!(allowed(), "Appshot cancelled");
            if seen.len() >= 6000 || Instant::now() >= deadline {
                break;
            }
            if !seen.insert(node.clone()) {
                continue;
            }
            let Ok(proxy) = accessible(&bus, &node) else {
                continue;
            };
            let Ok(role) = proxy.get_role() else {
                continue;
            };
            let states: StateSet = proxy.get_state().unwrap_or_default();
            if role == Role::PasswordText {
                ensure!(
                    !states.contains(State::Focused),
                    "Password entry is active in this window"
                );
                continue;
            }
            if !states.contains(State::Showing) || !states.contains(State::Visible) {
                continue;
            }
            if read_text
                && length < 32_000
                && matches!(
                    role,
                    Role::Text | Role::Entry | Role::Label | Role::Static | Role::Paragraph
                )
            {
                let text = zbus::blocking::Proxy::new(
                    &bus,
                    node.0.as_str(),
                    node.1.as_str(),
                    "org.a11y.atspi.Text",
                )?;
                let text: String = text
                    .call(
                        "GetText",
                        &(0i32, i32::try_from(32_000 - length).unwrap_or(0)),
                    )
                    .unwrap_or_else(|_| proxy.name().unwrap_or_default());
                let text = bounded_text(text.trim(), 32_000 - length);
                if !text.is_empty() && pieces.last() != Some(&text) {
                    length += text.len() + 1;
                    pieces.push(text);
                }
            }
            if let Ok(mut next) = children(&proxy, deadline, allowed) {
                next.truncate(6000usize.saturating_sub(seen.len() + pending.len()));
                pending.extend(next.into_iter().rev());
            }
        }
        Ok((!pieces.is_empty()).then(|| pieces.join("\n")))
    })();
    let _ = bus.close();
    result
}
pub(super) fn sound() {
    if let Some(display) = gtk::gdk::Display::default() {
        display.beep();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn padded_big_endian_and_rgb565_pixels_are_decoded_without_neighbor_data() {
        let mut visual = Visualtype {
            visual_id: 1,
            class: VisualClass::TRUE_COLOR,
            bits_per_rgb_value: 8,
            colormap_entries: 256,
            red_mask: 0xff0000,
            green_mask: 0x00ff00,
            blue_mask: 0x0000ff,
        };
        let format = Format {
            depth: 24,
            bits_per_pixel: 24,
            scanline_pad: 32,
        };
        assert_eq!(
            rgba_pixels(
                &[0x12, 0x34, 0x56, 0xee],
                1,
                1,
                &format,
                &visual,
                ImageOrder::MSB_FIRST
            )
            .unwrap(),
            vec![0x12, 0x34, 0x56, 255]
        );
        visual.red_mask = 0xf800;
        visual.green_mask = 0x07e0;
        visual.blue_mask = 0x001f;
        assert_eq!(
            rgba_pixels(
                &[0, 0xf8],
                1,
                1,
                &Format {
                    depth: 16,
                    bits_per_pixel: 16,
                    scanline_pad: 16
                },
                &visual,
                ImageOrder::LSB_FIRST
            )
            .unwrap(),
            vec![255, 0, 0, 255]
        );
        assert!(rgba_pixels(&[0], 1, 1, &format, &visual, ImageOrder::LSB_FIRST).is_err());
    }
    #[test]
    fn non_ascii_text_uses_bytes_without_splitting_a_character() {
        assert_eq!(bounded_text("éxyz", 1), "");
        assert_eq!(bounded_text("éxyz", 2), "é");
        assert_eq!(bounded_text("éxyz", 3), "éx");
        assert_eq!(bounded_text("éxyz", 100), "éxyz");
    }
    #[test]
    fn raw_key_sequence_observes_short_intervening_key_and_rearms_after_release() {
        let keys = KeyMap {
            control: [37, 105],
            shift: [50, 62],
            alt: [64, 108],
            super_keys: [133, 134],
            chord: None,
        };
        let mut keyboard = KeyboardState::new([0; 32], &keys);
        for (key, down) in [(37, true), (38, true), (38, false), (105, true)] {
            assert!(!keyboard.event(key, down, &keys));
        }
        assert!(!keyboard.event(37, false, &keys));
        assert!(!keyboard.event(105, false, &keys));
        assert!(!keyboard.event(37, true, &keys));
        assert!(keyboard.event(105, true, &keys));
        assert!(!keyboard.event(105, true, &keys));
    }
    #[test]
    fn custom_shortcut_requires_exact_modifier_and_key_set() {
        let keys = KeyMap {
            control: [37, 105],
            shift: [50, 62],
            alt: [64, 108],
            super_keys: [133, 134],
            chord: None,
        };
        let chord = Chord {
            key: 38,
            shift: false,
            alt: true,
        };
        let mut bits = [0u8; 32];
        for key in [37, 38, 64] {
            bits[key / 8] |= 1 << (key % 8);
        }
        assert!(chord.matches(&bits, &keys));
        bits[50 / 8] |= 1 << (50 % 8);
        assert!(!chord.matches(&bits, &keys));
        let keys = KeyMap {
            chord: Some(chord),
            ..keys
        };
        let mut keyboard = KeyboardState::new([0; 32], &keys);
        for (key, pressed) in [
            (37, true),
            (64, true),
            (50, true),
            (38, true),
            (50, false),
            (38, true),
            (38, false),
        ] {
            assert!(
                !keyboard.event(key, pressed, &keys),
                "modifier release is not a hotkey press"
            );
        }
        assert!(keyboard.event(38, true, &keys));
    }
}
