//! Native X11 CU, serialized by the existing Runtime worker. Constructors are
//! inert. XWayland is deliberately refused: it cannot identify the whole desktop.
//! X11 has no secure-desktop isolation; this adapter denies known lock/browser
//! executables, protected windows and uninspectable/ambiguous accessibility trees.
use super::{linux_policy as policy, *};
use crate::appshots_platform::backend as shared;
use atspi::{Role, State, StateSet};
use base64::Engine as _;
use serde_json::json;
use std::{
    collections::{BTreeMap, HashSet},
    fs::{File, Metadata},
    io::Read,
    os::unix::fs::MetadataExt,
};
use x11rb::{
    connection::Connection,
    protocol::{
        Event,
        composite::ConnectionExt as _,
        res::{self, ConnectionExt as _},
        xproto::*,
        xtest::ConnectionExt as _,
    },
    rust_connection::RustConnection,
};
type R<T> = Result<T, Failure>;
macro_rules! x {
    ($e:expr) => {
        $e.map_err(|_| Failure::Native)?
    };
}

fn native<T, E>(result: Result<T, E>) -> R<T> {
    result.map_err(|_| Failure::Native)
}
fn io<T>(result: std::io::Result<T>) -> R<T> {
    result.map_err(|_| Failure::StaleObservation)
}
fn bounded_file(path: impl AsRef<std::path::Path>, cap: usize) -> R<String> {
    let mut data = String::new();
    io(File::open(path))?
        .take((cap + 1) as u64)
        .read_to_string(&mut data)
        .map_err(|_| Failure::Native)?;
    if data.len() > cap {
        return Err(Failure::TooLarge);
    }
    Ok(data)
}
fn metadata_id(meta: &Metadata) -> (u64, u64, u32) {
    (meta.dev(), meta.ino(), meta.uid())
}
struct Process {
    pid: u32,
    start: u64,
    boot: String,
    proc: File,
    executable: File,
    proc_id: (u64, u64, u32),
    exe_id: (u64, u64, u32),
    name: String,
}
impl Process {
    fn open(pid: u32) -> R<Self> {
        if pid == 0 || pid == std::process::id() {
            return Err(Failure::PermissionDenied);
        }
        let base = format!("/proc/{pid}");
        let proc = io(File::open(&base))?;
        let executable = io(File::open(format!("{base}/exe")))?;
        let proc_id = metadata_id(&io(proc.metadata())?);
        let exe_id = metadata_id(&io(executable.metadata())?);
        // SAFETY: geteuid is a side-effect-free process identity getter.
        if proc_id.2 != unsafe { libc::geteuid() } {
            return Err(Failure::PermissionDenied);
        }
        let path = io(std::fs::read_link(format!("{base}/exe")))?;
        if policy::restricted_executable(&path.to_string_lossy()) {
            return Err(Failure::Unsupported);
        }
        let start = policy::process_start(&bounded_file(format!("{base}/stat"), 8192)?, pid)
            .ok_or(Failure::StaleObservation)?;
        let boot = bounded_file("/proc/sys/kernel/random/boot_id", 128)?;
        let name = shared::bounded_text(
            path.file_name().and_then(|s| s.to_str()).unwrap_or("app"),
            128,
        );
        let owner = Self {
            pid,
            start,
            boot,
            proc,
            executable,
            proc_id,
            exe_id,
            name,
        };
        owner.verify()?;
        Ok(owner)
    }
    fn verify(&self) -> R<()> {
        let base = format!("/proc/{}", self.pid);
        if metadata_id(&io(self.proc.metadata())?) != self.proc_id
            || metadata_id(&io(self.executable.metadata())?) != self.exe_id
            || metadata_id(&io(std::fs::metadata(&base))?) != self.proc_id
            || metadata_id(&io(std::fs::metadata(format!("{base}/exe")))?) != self.exe_id
            || policy::process_start(&bounded_file(format!("{base}/stat"), 8192)?, self.pid)
                != Some(self.start)
            || bounded_file("/proc/sys/kernel/random/boot_id", 128)? != self.boot
        {
            return Err(Failure::StaleObservation);
        }
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Geometry {
    frame: [i32; 4],
    visual: u32,
    depth: u8,
    root: u32,
}
fn geometry(connection: &shared::XConnection<'_>, window: u32) -> R<Geometry> {
    let g = x!(x!(connection.get_geometry(window)).reply());
    let a = x!(x!(connection.get_window_attributes(window)).reply());
    let p = x!(x!(connection.translate_coordinates(window, g.root, 0, 0)).reply());
    if g.width < 40
        || g.height < 40
        || u64::from(g.width) * u64::from(g.height) > 16_000_000
        || a.map_state != MapState::VIEWABLE
        || a.override_redirect
    {
        return Err(Failure::PermissionDenied);
    }
    Ok(Geometry {
        frame: [
            i32::from(p.dst_x),
            i32::from(p.dst_y),
            i32::from(g.width),
            i32::from(g.height),
        ],
        visual: a.visual,
        depth: g.depth,
        root: g.root,
    })
}
// All X protocol errors map to data-free failures; native messages may contain
// private app/window metadata and are never logged.
fn client(connection: &shared::XConnection<'_>, window: u32) -> R<(u32, u32, u32)> {
    x!(x!(connection.res_query_version(1, 2)).reply());
    let clients = x!(x!(connection.res_query_clients()).reply());
    if clients.clients.len() > 4096 {
        return Err(Failure::TooLarge);
    }
    let clients: Vec<_> = clients
        .clients
        .into_iter()
        .filter(|c| window & !c.resource_mask == c.resource_base)
        .collect();
    if clients.len() != 1 {
        return Err(Failure::StaleObservation);
    }
    let c = &clients[0];
    let ids = x!(x!(connection.res_query_client_ids(&[res::ClientIdSpec {
        client: window,
        mask: res::ClientIdMask::LOCAL_CLIENT_PID
    }]))
    .reply());
    let pids: Vec<_> = ids
        .ids
        .into_iter()
        .filter(|id| {
            id.spec.mask & res::ClientIdMask::LOCAL_CLIENT_PID != res::ClientIdMask::from(0u32)
        })
        .flat_map(|id| id.value)
        .collect();
    if pids.len() != 1 || pids[0] == 0 {
        return Err(Failure::Unsupported);
    }
    let declared = native(shared::owner_pid(connection, window))?;
    if declared != pids[0] {
        return Err(Failure::StaleObservation);
    }
    Ok((c.resource_base, c.resource_mask, pids[0]))
}
fn protected(connection: &shared::XConnection<'_>, window: u32) -> R<()> {
    if !native(shared::eligible_window(connection, window))? {
        return Err(Failure::PermissionDenied);
    }
    for name in [
        b"_NET_WM_CONTENT_PROTECTION".as_slice(),
        b"_NET_WM_PROTECTED_CONTENT".as_slice(),
    ] {
        let property = native(shared::property(connection, window, name, AtomEnum::ANY))?;
        if property.value.iter().any(|byte| *byte != 0) {
            return Err(Failure::PermissionDenied);
        }
    }
    Ok(())
}
fn always() -> bool {
    true
}
type WatchConnection = RustConnection<shared::BoundedStream<fn() -> bool>>;
struct Watch {
    connection: WatchConnection,
    window: u32,
}
impl Watch {
    fn open(window: u32) -> R<Self> {
        let (connection, _) = native(shared::connect_guarded(always as fn() -> bool))?;
        connection
            .stream()
            .deadline(Instant::now() + Duration::from_millis(150));
        x!(x!(connection.change_window_attributes(
            window,
            &ChangeWindowAttributesAux::new()
                .event_mask(EventMask::STRUCTURE_NOTIFY | EventMask::PROPERTY_CHANGE)
        ))
        .check());
        x!(x!(connection.get_input_focus()).reply());
        Ok(Self { connection, window })
    }
    fn unchanged(&self) -> R<()> {
        self.connection
            .stream()
            .deadline(Instant::now() + Duration::from_millis(150));
        // Round-trip barrier makes earlier resource changes observable before input.
        x!(x!(self.connection.get_input_focus()).reply());
        for _ in 0..256 {
            let Some(event) = x!(self.connection.poll_for_event()) else {
                return Ok(());
            };
            let changed = match event {
                Event::DestroyNotify(e) => e.window == self.window,
                Event::ConfigureNotify(e) => e.window == self.window,
                Event::ReparentNotify(e) => e.window == self.window,
                Event::UnmapNotify(e) => e.window == self.window,
                Event::MapNotify(e) => e.window == self.window,
                Event::PropertyNotify(e) => e.window == self.window,
                Event::Error(_) => true,
                _ => false,
            };
            if changed {
                return Err(Failure::StaleObservation);
            }
        }
        Err(Failure::TooLarge)
    }
}
struct Window {
    process: Process,
    identity: policy::Identity,
    geometry: Geometry,
    watch: Watch,
}
impl Window {
    fn open(connection: &shared::XConnection<'_>, root: u32, pid: u32, window: u32) -> R<Self> {
        if window == 0 || window == root {
            return Err(Failure::PermissionDenied);
        }
        let watch = Watch::open(window)?;
        protected(connection, window)?;
        let (client, mask, actual) = client(connection, window)?;
        if actual != pid {
            return Err(Failure::StaleObservation);
        }
        let process = Process::open(pid)?;
        let geometry = geometry(connection, window)?;
        let identity = policy::Identity {
            root,
            window,
            client,
            mask,
            pid,
            start: process.start,
            proc_inode: process.proc_id.1,
            exe_device: process.exe_id.0,
            exe_inode: process.exe_id.1,
        };
        let owner = Self {
            process,
            identity,
            geometry,
            watch,
        };
        owner.verify(connection)?;
        Ok(owner)
    }
    fn verify(&self, connection: &shared::XConnection<'_>) -> R<()> {
        self.watch.unchanged()?;
        self.process.verify()?;
        protected(connection, self.identity.window)?;
        let (client, mask, pid) = client(connection, self.identity.window)?;
        let now = policy::Identity {
            client,
            mask,
            pid,
            ..self.identity
        };
        if !self.identity.matches(now)
            || geometry(connection, self.identity.window)? != self.geometry
        {
            return Err(Failure::StaleObservation);
        }
        self.watch.unchanged()
    }
}
fn checked(permit: &Permit, deadline: Instant) -> R<()> {
    permit.check()?;
    if Instant::now() >= deadline {
        Err(Failure::TimedOut)
    } else {
        Ok(())
    }
}
fn proxy<'a>(
    bus: &'a zbus::blocking::Connection,
    object: &'a shared::Object,
    interface: &'a str,
) -> R<zbus::blocking::Proxy<'a>> {
    zbus::blocking::Proxy::new(bus, object.0.as_str(), object.1.as_str(), interface)
        .map_err(|_| Failure::Native)
}
fn bus_pid(bus: &zbus::blocking::Connection, name: &str) -> R<u32> {
    if !name.starts_with(':') {
        return Err(Failure::StaleObservation);
    }
    let dbus = zbus::blocking::Proxy::new(
        bus,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
    )
    .map_err(|_| Failure::Native)?;
    dbus.call("GetConnectionUnixProcessID", &(name,))
        .map_err(|_| Failure::StaleObservation)
}
fn children(
    bus: &zbus::blocking::Connection,
    object: &shared::Object,
    permit: &Permit,
    deadline: Instant,
    cap: usize,
) -> R<Vec<shared::Object>> {
    checked(permit, deadline)?;
    let accessible = native(shared::accessible(bus, object))?;
    let count = accessible.child_count().map_err(|_| Failure::Native)?;
    if count < 0 || count as usize > cap {
        return Err(Failure::TooLarge);
    }
    let allowed = || checked(permit, deadline).is_ok();
    let result = native(shared::children(&accessible, deadline, &allowed))?;
    checked(permit, deadline)?;
    if result.len() != count as usize {
        return Err(Failure::StaleObservation);
    }
    Ok(result)
}
fn bounds(bus: &zbus::blocking::Connection, object: &shared::Object) -> R<[i32; 4]> {
    let result: (i32, i32, i32, i32) = proxy(bus, object, "org.a11y.atspi.Component")?
        .call("GetExtents", &(0u32,))
        .map_err(|_| Failure::Native)?;
    Ok([result.0, result.1, result.2, result.3])
}
fn tree_root(
    bus: &zbus::blocking::Connection,
    window: &Window,
    permit: &Permit,
    deadline: Instant,
) -> R<shared::Object> {
    let registry = (
        "org.a11y.atspi.Registry".into(),
        zbus::zvariant::OwnedObjectPath::try_from("/org/a11y/atspi/accessible/root")
            .map_err(|_| Failure::Native)?,
    );
    let mut selected = None;
    for app in children(bus, &registry, permit, deadline, 128)? {
        checked(permit, deadline)?;
        if bus_pid(bus, &app.0)? != window.identity.pid {
            continue;
        }
        for object in children(bus, &app, permit, deadline, 64)? {
            if bounds(bus, &object).is_ok_and(|b| b == window.geometry.frame) {
                if selected.replace(object).is_some() {
                    return Err(Failure::StaleObservation);
                }
            }
        }
    }
    selected.ok_or(Failure::PermissionDenied)
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Element {
    object: shared::Object,
    parent: Option<shared::Object>,
    role: Role,
    title: String,
    value: Option<String>,
    secure: bool,
    focused: bool,
    frame: Option<[i32; 4]>,
    states: StateSet,
}
fn element(
    bus: &zbus::blocking::Connection,
    object: shared::Object,
    parent: Option<shared::Object>,
) -> R<Element> {
    let accessible = native(shared::accessible(bus, &object))?;
    let role = accessible.get_role().map_err(|_| Failure::Native)?;
    let states = accessible.get_state().map_err(|_| Failure::Native)?;
    let actual_parent = shared::object(accessible.parent().map_err(|_| Failure::Native)?);
    if parent.is_some() && parent != actual_parent {
        return Err(Failure::StaleObservation);
    }
    if states.contains(State::Defunct) {
        return Err(Failure::StaleObservation);
    }
    let secure = role == Role::PasswordText;
    let title = if secure {
        String::new()
    } else {
        shared::bounded_text(&accessible.name().map_err(|_| Failure::Native)?, 1024)
    };
    let value = if !secure && matches!(role, Role::Text | Role::Entry | Role::Paragraph) {
        proxy(bus, &object, "org.a11y.atspi.Text")?
            .call::<_, _, String>("GetText", &(0i32, 1024i32))
            .ok()
            .map(|s| shared::bounded_text(&s, 4096))
    } else {
        None
    };
    let frame = bounds(bus, &object).ok();
    drop(accessible);
    Ok(Element {
        object,
        parent: actual_parent,
        role,
        title,
        value,
        secure,
        focused: states.contains(State::Focused),
        frame,
        states,
    })
}
fn tree(
    bus: &zbus::blocking::Connection,
    window: &Window,
    permit: &Permit,
    deadline: Instant,
) -> R<(shared::Object, Vec<Element>)> {
    let root = tree_root(bus, window, permit, deadline)?;
    let mut pending = vec![(root.clone(), None, 0usize)];
    let mut seen = HashSet::new();
    let mut result = vec![];
    while let Some((object, parent, depth)) = pending.pop() {
        checked(permit, deadline)?;
        if depth > 48 || seen.len() >= 1024 {
            return Err(Failure::TooLarge);
        }
        if !seen.insert(object.clone()) {
            return Err(Failure::StaleObservation);
        }
        if object.0 != root.0 || bus_pid(bus, &object.0)? != window.identity.pid {
            return Err(Failure::StaleObservation);
        }
        let entry = element(bus, object.clone(), parent)?;
        // Password descendants may expose their content through a generic text
        // role. Never request those child objects, names or values.
        let next = if entry.secure {
            Vec::new()
        } else {
            children(
                bus,
                &object,
                permit,
                deadline,
                1024usize.saturating_sub(seen.len() + pending.len()),
            )?
        };
        pending.extend(
            next.into_iter()
                .rev()
                .map(|child| (child, Some(object.clone()), depth + 1)),
        );
        if entry.states.contains(State::Showing) && entry.states.contains(State::Visible) {
            result.push(entry);
        }
    }
    checked(permit, deadline)?;
    Ok((root, result))
}
struct Observed {
    window: Window,
    root: shared::Object,
    elements: BTreeMap<u64, Element>,
    screenshot: bool,
}
#[derive(Default)]
pub(super) struct NativeBackend {
    observed: Option<Observed>,
    next: u64,
}
impl NativeBackend {
    fn list(
        &self,
        connection: &shared::XConnection<'_>,
        root: u32,
        permit: &Permit,
        deadline: Instant,
    ) -> R<Vec<(u32, Process, Geometry)>> {
        let property = native(shared::property(
            connection,
            root,
            b"_NET_CLIENT_LIST_STACKING",
            AtomEnum::WINDOW,
        ))?;
        let windows: Vec<_> = property.value32().ok_or(Failure::Unsupported)?.collect();
        if windows.len() > 512 {
            return Err(Failure::TooLarge);
        }
        let mut result = vec![];
        for window in windows {
            checked(permit, deadline)?;
            if window == root || protected(connection, window).is_err() {
                continue;
            }
            let Ok((_, _, pid)) = client(connection, window) else {
                continue;
            };
            let Ok(process) = Process::open(pid) else {
                continue;
            };
            let Ok(geometry) = geometry(connection, window) else {
                continue;
            };
            if geometry.root == root {
                result.push((window, process, geometry));
            }
        }
        Ok(result)
    }
    fn perform(&mut self, call: NativeCall, permit: &Permit) -> R<NativeResult> {
        permit.check()?;
        if !shared::x11_session() {
            return Err(Failure::Unsupported);
        }
        let deadline = Instant::now() + Duration::from_secs(4);
        let allowed = || checked(permit, deadline).is_ok();
        let (connection, screen) = native(shared::connect(&allowed))?;
        connection.stream().deadline(deadline);
        let root = connection
            .setup()
            .roots
            .get(screen)
            .ok_or(Failure::Native)?
            .root;
        match call {
            NativeCall::ListApps | NativeCall::ListWindows(_) => {
                let apps = matches!(call, NativeCall::ListApps);
                let filter = if let NativeCall::ListWindows(pid) = call {
                    pid
                } else {
                    None
                };
                let mut seen = HashSet::new();
                let mut rows = vec![];
                for (window, process, geometry) in self.list(&connection, root, permit, deadline)? {
                    if filter.is_some_and(|pid| pid as u32 != process.pid) {
                        continue;
                    }
                    if apps {
                        if seen.insert(process.pid) {
                            rows.push(
                                json!({"pid":process.pid,"name":process.name,"bundle_id":""}),
                            );
                        }
                    } else {
                        let title = native(shared::property(
                            &connection,
                            window,
                            b"_NET_WM_NAME",
                            AtomEnum::ANY,
                        ))?;
                        rows.push(json!({"pid":process.pid,"window_id":window,"title":shared::bounded_text(&String::from_utf8_lossy(&title.value),512),"x":geometry.frame[0],"y":geometry.frame[1],"width":geometry.frame[2],"height":geometry.frame[3]}));
                    }
                }
                checked(permit, deadline)?;
                Ok(NativeResult::Data(json!(rows)))
            }
            NativeCall::Observe {
                pid,
                window,
                limit,
                screenshot,
            } => {
                self.invalidate();
                let window = Window::open(
                    &connection,
                    root,
                    u32::try_from(pid).map_err(|_| Failure::InvalidRequest)?,
                    window,
                )?;
                checked(permit, deadline)?;
                let bus = native(shared::accessibility_bus())?;
                let (accessible, nodes) = tree(&bus, &window, permit, deadline)?;
                if nodes
                    .iter()
                    .any(|node| node.secure && (screenshot || node.focused))
                {
                    return Err(Failure::PermissionDenied);
                }
                let source_nodes = nodes.clone();
                let mut elements = BTreeMap::new();
                let mut exposed = vec![];
                for entry in nodes.into_iter().take(limit.min(MAX_NODES)) {
                    self.next = self.next.checked_add(1).ok_or(Failure::TooLarge)?;
                    exposed.push(Node {
                        native_id: self.next,
                        role: format!("{:?}", entry.role),
                        title: entry.title.clone(),
                        value: entry.value.clone(),
                        secure: entry.secure,
                        focused: entry.focused,
                    });
                    elements.insert(self.next, entry);
                }
                window.verify(&connection)?;
                let image = if screenshot {
                    let png = native(shared::window_png(
                        &connection,
                        screen,
                        window.identity.window,
                        &allowed,
                    ))?;
                    checked(permit, deadline)?;
                    // Re-scan security after pixel IO; never publish if the tree changed.
                    let (after, post) = tree(&bus, &window, permit, deadline)?;
                    if after != accessible || post.iter().any(|e| e.secure) {
                        return Err(Failure::PermissionDenied);
                    }
                    if post != source_nodes {
                        return Err(Failure::StaleObservation);
                    }
                    Some(Image {
                        png_base64: base64::engine::general_purpose::STANDARD.encode(png),
                        width: window.geometry.frame[2] as u32,
                        height: window.geometry.frame[3] as u32,
                    })
                } else {
                    None
                };
                window.verify(&connection)?;
                checked(permit, deadline)?;
                let (width, height) = (
                    f64::from(window.geometry.frame[2]),
                    f64::from(window.geometry.frame[3]),
                );
                self.observed = Some(Observed {
                    window,
                    root: accessible,
                    elements,
                    screenshot,
                });
                Ok(NativeResult::Snapshot(Snapshot {
                    nodes: exposed,
                    screenshot: image,
                    width,
                    height,
                }))
            }
            action => {
                let observed = self.observed.as_ref().ok_or(Failure::StaleObservation)?;
                observed.window.verify(&connection)?;
                checked(permit, deadline)?;
                if native(shared::active_window(&connection, root))?
                    != observed.window.identity.window
                {
                    return Err(Failure::StaleObservation);
                }
                let bus = native(shared::accessibility_bus())?;
                let (current_root, entries) = tree(&bus, &observed.window, permit, deadline)?;
                if current_root != observed.root || entries.iter().any(|e| e.secure && e.focused) {
                    return Err(Failure::PermissionDenied);
                }
                let id = match &action {
                    NativeCall::Press { native }
                    | NativeCall::SetValue { native, .. }
                    | NativeCall::Key { native, .. } => Some(*native),
                    _ => None,
                };
                let target = if let Some(id) = id {
                    let prior = observed
                        .elements
                        .get(&id)
                        .ok_or(Failure::StaleObservation)?;
                    let current = entries
                        .iter()
                        .find(|entry| entry.object == prior.object)
                        .ok_or(Failure::StaleObservation)?;
                    if current != prior
                        || current.secure
                        || !current.states.contains(State::Enabled)
                        || !current.states.contains(State::Sensitive)
                    {
                        return Err(Failure::StaleObservation);
                    }
                    Some(current)
                } else {
                    None
                };
                match action {
                    NativeCall::Press { .. } => {
                        let object = &target.ok_or(Failure::Native)?.object;
                        let action = proxy(&bus, object, "org.a11y.atspi.Action")?;
                        let count: i32 = action
                            .get_property("NActions")
                            .map_err(|_| Failure::Unsupported)?;
                        if !(1..=32).contains(&count) {
                            return Err(Failure::Unsupported);
                        }
                        // Do not try an alternative after a possibly-dispatched error.
                        let mut selected = None;
                        for index in 0..count {
                            checked(permit, deadline)?;
                            let name: String = action
                                .call("GetName", &(index,))
                                .map_err(|_| Failure::Native)?;
                            if matches!(
                                name.to_ascii_lowercase().as_str(),
                                "click" | "press" | "activate" | "toggle" | "select"
                            ) {
                                selected = Some(index);
                                break;
                            }
                        }
                        let index = selected.ok_or(Failure::Unsupported)?;
                        recheck_element(&bus, target.ok_or(Failure::Native)?)?;
                        observed.window.verify(&connection)?;
                        checked(permit, deadline)?;
                        let done: bool = action
                            .call("DoAction", &(index,))
                            .map_err(|_| Failure::Native)?;
                        if !done {
                            return Err(Failure::Native);
                        }
                    }
                    NativeCall::SetValue { text, .. } => {
                        let target = target.ok_or(Failure::Native)?;
                        if !target.states.contains(State::Editable) {
                            return Err(Failure::PermissionDenied);
                        }
                        let edit = proxy(&bus, &target.object, "org.a11y.atspi.EditableText")?;
                        recheck_element(&bus, target)?;
                        observed.window.verify(&connection)?;
                        checked(permit, deadline)?;
                        let done: bool = edit
                            .call("SetTextContents", &(text.as_str(),))
                            .map_err(|_| Failure::Native)?;
                        if !done {
                            return Err(Failure::Native);
                        }
                    }
                    NativeCall::Key { key, .. } => {
                        let target = target.ok_or(Failure::Native)?;
                        // No focus-stealing: the observed target must already own focus.
                        if !target.focused {
                            return Err(Failure::StaleObservation);
                        }
                        let symbol = match key {
                            Key::Enter => 0xff0d,
                            Key::Escape => 0xff1b,
                            Key::Tab => 0xff09,
                            Key::Backspace => 0xff08,
                            Key::Left => 0xff51,
                            Key::Right => 0xff53,
                            Key::Up => 0xff52,
                            Key::Down => 0xff54,
                        };
                        let setup = connection.setup();
                        let mapping = x!(x!(connection.get_keyboard_mapping(
                            setup.min_keycode,
                            setup.max_keycode - setup.min_keycode + 1
                        ))
                        .reply());
                        if mapping.keysyms_per_keycode == 0 {
                            return Err(Failure::Native);
                        }
                        let mut matches = mapping
                            .keysyms
                            .chunks(usize::from(mapping.keysyms_per_keycode))
                            .enumerate()
                            .filter(|(_, symbols)| symbols.first() == Some(&symbol));
                        let (index, _) = matches.next().ok_or(Failure::Unsupported)?;
                        if matches.next().is_some() {
                            return Err(Failure::Unsupported);
                        }
                        let keycode = setup
                            .min_keycode
                            .checked_add(index as u8)
                            .ok_or(Failure::Unsupported)?;
                        input_guard(&connection, observed, permit, deadline)?;
                        recheck_element(&bus, target)?;
                        keyboard_focus(&connection, observed)?;
                        input_pair(
                            &connection,
                            observed,
                            permit,
                            deadline,
                            KEY_PRESS_EVENT,
                            KEY_RELEASE_EVENT,
                            keycode,
                        )?;
                    }
                    NativeCall::Point { pid, window, x, y } => {
                        if !observed.screenshot
                            || pid as u32 != observed.window.identity.pid
                            || window != observed.window.identity.window
                        {
                            return Err(Failure::StaleObservation);
                        }
                        let (px, py) = policy::point(observed.window.geometry.frame, x, y)
                            .ok_or(Failure::InvalidRequest)?;
                        let hit: atspi::ObjectRefOwned =
                            proxy(&bus, &observed.root, "org.a11y.atspi.Component")?
                                .call(
                                    "GetAccessibleAtPoint",
                                    &(i32::from(px), i32::from(py), 0u32),
                                )
                                .map_err(|_| Failure::Native)?;
                        let hit = native(
                            shared::object(hit).ok_or_else(|| anyhow::anyhow!("No accessible hit")),
                        )?;
                        let entry = entries
                            .iter()
                            .find(|e| e.object == hit)
                            .ok_or(Failure::StaleObservation)?;
                        if entry.secure || !entry.states.contains(State::Enabled) {
                            return Err(Failure::PermissionDenied);
                        }
                        input_guard(&connection, observed, permit, deadline)?;
                        x!(x!(connection.xtest_fake_input(
                            MOTION_NOTIFY_EVENT,
                            0,
                            0,
                            root,
                            px,
                            py,
                            0
                        ))
                        .check());
                        pointer_target(&connection, observed)?;
                        recheck_element(&bus, entry)?;
                        input_pair(
                            &connection,
                            observed,
                            permit,
                            deadline,
                            BUTTON_PRESS_EVENT,
                            BUTTON_RELEASE_EVENT,
                            1,
                        )?;
                    }
                    _ => return Err(Failure::InvalidRequest),
                }
                checked(permit, deadline)?;
                Ok(NativeResult::Done)
            }
        }
    }
}
fn recheck_element(bus: &zbus::blocking::Connection, prior: &Element) -> R<()> {
    if element(bus, prior.object.clone(), prior.parent.clone())? != *prior {
        return Err(Failure::StaleObservation);
    }
    Ok(())
}
// The release connection is opened BEFORE down and owned on this same worker.
// Its only operation is the matching up event: cleanup must remain possible
// after cancellation, including when down's reply was lost. No input retry.
fn input_pair(
    connection: &shared::XConnection<'_>,
    observed: &Observed,
    permit: &Permit,
    deadline: Instant,
    down: u8,
    up: u8,
    detail: u8,
) -> R<()> {
    let (release, screen) = native(shared::connect_guarded(always as fn() -> bool))?;
    let root = observed.window.identity.root;
    if release.setup().roots.get(screen).map(|screen| screen.root) != Some(root) {
        return Err(Failure::StaleObservation);
    }
    policy::paired_input(
        || {
            input_guard(connection, observed, permit, deadline)?;
            if down == KEY_PRESS_EVENT {
                keyboard_focus(connection, observed)?;
            }
            if down == BUTTON_PRESS_EVENT {
                pointer_target(connection, observed)?;
            }
            checked(permit, deadline)
        },
        || {
            connection
                .xtest_fake_input(down, detail, 0, root, 0, 0, 0)
                .map_err(|_| Failure::Native)
                .and_then(|cookie| cookie.check().map_err(|_| Failure::Native))
        },
        || {
            release
                .stream()
                .deadline(Instant::now() + Duration::from_millis(150));
            release
                .xtest_fake_input(up, detail, 0, root, 0, 0, 0)
                .map_err(|_| Failure::Native)
                .and_then(|cookie| cookie.check().map_err(|_| Failure::Native))
        },
    )
}
fn keyboard_focus(connection: &shared::XConnection<'_>, observed: &Observed) -> R<()> {
    let mut current = x!(x!(connection.get_input_focus()).reply()).focus;
    if current == 0 || current == observed.window.identity.root {
        return Err(Failure::StaleObservation);
    }
    if client(connection, current)?.2 != observed.window.identity.pid {
        return Err(Failure::StaleObservation);
    }
    for _ in 0..32 {
        if current == observed.window.identity.window {
            return Ok(());
        }
        let tree = x!(x!(connection.query_tree(current)).reply());
        if tree.parent == 0 || tree.parent == tree.root {
            return Err(Failure::StaleObservation);
        }
        current = tree.parent;
    }
    Err(Failure::TooLarge)
}
fn pointer_target(connection: &shared::XConnection<'_>, observed: &Observed) -> R<()> {
    let mut current = observed.window.identity.root;
    let mut inside = false;
    for _ in 0..32 {
        inside |= current == observed.window.identity.window;
        let pointer = x!(x!(connection.query_pointer(current)).reply());
        if !pointer.same_screen {
            return Err(Failure::StaleObservation);
        }
        if pointer.child == 0 {
            if inside && client(connection, current)?.2 == observed.window.identity.pid {
                return Ok(());
            }
            return Err(Failure::StaleObservation);
        }
        current = pointer.child;
    }
    Err(Failure::TooLarge)
}
fn input_guard(
    connection: &shared::XConnection<'_>,
    observed: &Observed,
    permit: &Permit,
    deadline: Instant,
) -> R<()> {
    observed.window.verify(connection)?;
    if native(shared::active_window(
        connection,
        observed.window.identity.root,
    ))? != observed.window.identity.window
    {
        return Err(Failure::StaleObservation);
    }
    let pointer = x!(x!(connection.query_pointer(observed.window.identity.root)).reply());
    if u16::from(pointer.mask) != 0 {
        return Err(Failure::PermissionDenied);
    }
    let keys = x!(x!(connection.query_keymap()).reply());
    if keys.keys.iter().any(|byte| *byte != 0) {
        return Err(Failure::PermissionDenied);
    }
    checked(permit, deadline)
}
impl Backend for NativeBackend {
    fn permissions(&mut self) -> R<Permissions> {
        if !shared::x11_session() {
            return Ok(Permissions {
                accessibility: Permission::Unsupported,
                screen_capture: Permission::Unsupported,
            });
        }
        // Only explicit Refresh or a granted Broker operation calls this method.
        let bus = shared::accessibility_bus();
        let accessibility = if let Ok(bus) = bus {
            let _ = bus.close();
            Permission::Granted
        } else {
            Permission::Denied
        };
        let allowed = || true;
        let screen_capture = shared::connect(&allowed)
            .ok()
            .is_some_and(|(connection, _)| {
                connection
                    .composite_query_version(0, 2)
                    .ok()
                    .and_then(|cookie| cookie.reply().ok())
                    .is_some()
            });
        Ok(Permissions {
            accessibility,
            screen_capture: if screen_capture {
                Permission::Granted
            } else {
                Permission::Denied
            },
        })
    }
    fn request_permission(&mut self, _: PermissionKind) -> R<Permissions> {
        self.permissions()
    }
    fn invalidate(&mut self) {
        self.observed = None;
    }
    fn call(&mut self, call: NativeCall, permit: &Permit) -> R<NativeResult> {
        let result = self.perform(call, permit);
        let result = permit.check().and(result);
        if result.is_err() {
            self.invalidate();
        }
        result
    }
}

#[cfg(test)]
#[path = "computer_use_linux_native_tests.rs"]
mod native_tests;
