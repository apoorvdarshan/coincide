//! Native Computer Use protocol and broker. Authority is native-UI-only and off
//! by default; while the saved switch is on every thread has a capability
//! (Swift's ComputerUseController). No scripts, provider commands or file IO.
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use uuid::Uuid;
pub const MAX_REQUEST: usize = 262_144;
pub const MAX_RESULT: usize = 4_194_304;
pub const MAX_NODES: usize = 128;
pub const TOKEN_LIFETIME: Duration = Duration::from_secs(15);
/// How long a thread keeps the shared desktop after its last action unless it
/// releases it first (Swift `ComputerUseController.desktopLease`).
pub const DESKTOP_LEASE: Duration = Duration::from_secs(60);
/// Saved switch in settings.json, shared with the Swift app's `AppSettings`.
pub const SETTING: &str = "computerUseEnabled";
const MAX_THREADS: usize = 4096;
/// Tools every backend serves through the core broker.
const BASE_TOOLS: &[&str] = &[
    "list_apps",
    "list_windows",
    "get_window_state",
    "get_desktop_state",
    "verify_state",
    "click",
    "set_value",
    "press_key",
    "click_point",
];
/// Tools a backend serves only when it lists them in `Backend::extended_tools`.
pub const EXTENDED_TOOLS: &[&str] = &[
    "double_click",
    "right_click",
    "type_text",
    "hotkey",
    "scroll",
    "drag",
    "move_cursor",
    "invoke_menu",
    "launch_app",
    "set_window_frame",
    "zoom",
];
/// The saved switch; anything but `true` (missing, malformed) is off.
pub fn saved_enabled(settings: &Value) -> bool {
    settings.get(SETTING) == Some(&Value::Bool(true))
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Failure {
    InvalidRequest,
    Off,
    NotGranted,
    Unsupported,
    PermissionDenied,
    Busy,
    StaleObservation,
    TimedOut,
    TooLarge,
    Native,
    Revoked,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Permission {
    Unknown,
    Granted,
    Denied,
    Unsupported,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Permissions {
    pub accessibility: Permission,
    pub screen_capture: Permission,
}
impl Default for Permissions {
    fn default() -> Self {
        Self {
            accessibility: Permission::Unknown,
            screen_capture: Permission::Unknown,
        }
    }
}
#[derive(Debug, Clone, Copy)]
pub enum PermissionKind {
    Accessibility,
    ScreenCapture,
}
#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Key {
    Enter,
    Escape,
    Tab,
    Backspace,
    Left,
    Right,
    Up,
    Down,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Empty {}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Windows {
    #[serde(default)]
    pub pid: Option<i32>,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Observe {
    pub pid: i32,
    pub window_id: u32,
    #[serde(default = "default_nodes")]
    pub max_elements: usize,
    #[serde(default)]
    pub include_screenshot: bool,
}
fn default_nodes() -> usize {
    64
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Element {
    pub element_token: Uuid,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetValue {
    pub element_token: Uuid,
    pub text: String,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PressKey {
    pub element_token: Uuid,
    pub key: Key,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Point {
    pub observation: Uuid,
    pub x: f64,
    pub y: f64,
}
/// Either a fresh element token, or a point in a fresh screenshot observation.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Pointer {
    #[serde(default)]
    pub element_token: Option<Uuid>,
    #[serde(default)]
    pub observation: Option<Uuid>,
    #[serde(default)]
    pub x: Option<f64>,
    #[serde(default)]
    pub y: Option<f64>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    Up,
    Down,
    Left,
    Right,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Scroll {
    #[serde(default)]
    pub element_token: Option<Uuid>,
    #[serde(default)]
    pub observation: Option<Uuid>,
    #[serde(default)]
    pub x: Option<f64>,
    #[serde(default)]
    pub y: Option<f64>,
    pub direction: Direction,
    #[serde(default = "default_scroll")]
    pub amount: u32,
}
fn default_scroll() -> u32 {
    3
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TypeText {
    pub element_token: Uuid,
    pub text: String,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Hotkey {
    pub element_token: Uuid,
    pub keys: Vec<String>,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Drag {
    pub observation: Uuid,
    pub from_x: f64,
    pub from_y: f64,
    pub to_x: f64,
    pub to_y: f64,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Menu {
    pub pid: i32,
    pub path: Vec<String>,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Launch {
    pub bundle_id: String,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Frame {
    pub pid: i32,
    pub window_id: u32,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Desktop {
    #[serde(default)]
    pub include_screenshot: bool,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Verify {
    pub pid: i32,
    pub window_id: u32,
    pub text: String,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Zoom {
    pub observation: Uuid,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Modifier {
    Command,
    Control,
    Option,
    Shift,
}
/// A validated hotkey: at least one modifier, then one named key or a single
/// ASCII letter, digit or punctuation mark.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chord {
    pub modifiers: Vec<Modifier>,
    pub key: String,
}
pub const CHORD_KEYS: &[&str] = &[
    "enter",
    "escape",
    "tab",
    "space",
    "backspace",
    "delete",
    "left",
    "right",
    "up",
    "down",
    "home",
    "end",
    "page_up",
    "page_down",
    "f1",
    "f2",
    "f3",
    "f4",
    "f5",
    "f6",
    "f7",
    "f8",
    "f9",
    "f10",
    "f11",
    "f12",
];
impl Chord {
    pub fn parse(keys: &[String]) -> Option<Self> {
        let (key, modifiers) = keys.split_last()?;
        if keys.len() > 5 || modifiers.is_empty() {
            return None;
        }
        let mut parsed = vec![];
        for modifier in modifiers {
            let modifier = match modifier.to_ascii_lowercase().as_str() {
                "cmd" | "command" | "meta" | "super" | "win" => Modifier::Command,
                "ctrl" | "control" => Modifier::Control,
                "alt" | "option" => Modifier::Option,
                "shift" => Modifier::Shift,
                _ => return None,
            };
            if parsed.contains(&modifier) {
                return None;
            }
            parsed.push(modifier);
        }
        let key = key.to_ascii_lowercase();
        let key = match key.as_str() {
            "return" => "enter".to_owned(),
            "esc" => "escape".to_owned(),
            "pageup" => "page_up".to_owned(),
            "pagedown" => "page_down".to_owned(),
            "arrowleft" => "left".to_owned(),
            "arrowright" => "right".to_owned(),
            "arrowup" => "up".to_owned(),
            "arrowdown" => "down".to_owned(),
            _ => key,
        };
        let single = key.len() == 1 && key.bytes().all(|b| b.is_ascii_graphic());
        (single || CHORD_KEYS.contains(&key.as_str())).then_some(Self {
            modifiers: parsed,
            key,
        })
    }
}
fn point_ok(x: f64, y: f64) -> bool {
    x.is_finite() && y.is_finite() && x >= 0.0 && y >= 0.0
}
fn pointer_ok(
    element: Option<Uuid>,
    observation: Option<Uuid>,
    x: Option<f64>,
    y: Option<f64>,
) -> bool {
    match (element, observation, x, y) {
        (Some(_), None, None, None) => true,
        (None, Some(_), Some(x), Some(y)) => point_ok(x, y),
        _ => false,
    }
}
fn text_ok(text: &str, limit: usize) -> bool {
    text.len() <= limit && !text.contains('\0')
}
#[derive(Debug, Deserialize)]
#[serde(
    tag = "name",
    content = "arguments",
    rename_all = "snake_case",
    deny_unknown_fields
)]
pub enum Tool {
    ListApps(Empty),
    ListWindows(Windows),
    GetWindowState(Observe),
    Click(Element),
    SetValue(SetValue),
    PressKey(PressKey),
    ClickPoint(Point),
    DoubleClick(Pointer),
    RightClick(Pointer),
    TypeText(TypeText),
    Hotkey(Hotkey),
    Scroll(Scroll),
    Drag(Drag),
    MoveCursor(Point),
    InvokeMenu(Menu),
    LaunchApp(Launch),
    SetWindowFrame(Frame),
    GetDesktopState(Desktop),
    VerifyState(Verify),
    Zoom(Zoom),
}

impl Tool {
    fn validate(&self) -> Result<(), Failure> {
        match self {
            Self::ListWindows(w) if w.pid.is_some_and(|pid| pid <= 0) => {
                Err(Failure::InvalidRequest)
            }
            Self::GetWindowState(o)
                if o.pid <= 0 || o.window_id == 0 || !(1..=MAX_NODES).contains(&o.max_elements) =>
            {
                Err(Failure::InvalidRequest)
            }
            Self::SetValue(v) if !text_ok(&v.text, 16_384) => Err(Failure::InvalidRequest),
            Self::ClickPoint(p) | Self::MoveCursor(p) if !point_ok(p.x, p.y) => {
                Err(Failure::InvalidRequest)
            }
            Self::DoubleClick(p) | Self::RightClick(p)
                if !pointer_ok(p.element_token, p.observation, p.x, p.y) =>
            {
                Err(Failure::InvalidRequest)
            }
            Self::Scroll(s)
                if !pointer_ok(s.element_token, s.observation, s.x, s.y)
                    || !(1..=50).contains(&s.amount) =>
            {
                Err(Failure::InvalidRequest)
            }
            Self::TypeText(t) if t.text.is_empty() || !text_ok(&t.text, 16_384) => {
                Err(Failure::InvalidRequest)
            }
            Self::Hotkey(h) if Chord::parse(&h.keys).is_none() => Err(Failure::InvalidRequest),
            Self::Drag(d) if !point_ok(d.from_x, d.from_y) || !point_ok(d.to_x, d.to_y) => {
                Err(Failure::InvalidRequest)
            }
            Self::InvokeMenu(m)
                if m.pid <= 0
                    || !(1..=8).contains(&m.path.len())
                    || m.path
                        .iter()
                        .any(|item| item.trim().is_empty() || !text_ok(item, 256)) =>
            {
                Err(Failure::InvalidRequest)
            }
            Self::LaunchApp(l)
                if l.bundle_id.is_empty()
                    || l.bundle_id.len() > 255
                    || !l
                        .bundle_id
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-') =>
            {
                Err(Failure::InvalidRequest)
            }
            Self::SetWindowFrame(f)
                if f.pid <= 0
                    || f.window_id == 0
                    || !f.x.is_finite()
                    || !f.y.is_finite()
                    || !(1.0..=100_000.0).contains(&f.width)
                    || !(1.0..=100_000.0).contains(&f.height)
                    || f.x.abs() > 100_000.0
                    || f.y.abs() > 100_000.0 =>
            {
                Err(Failure::InvalidRequest)
            }
            Self::VerifyState(v)
                if v.pid <= 0
                    || v.window_id == 0
                    || v.text.trim().is_empty()
                    || !text_ok(&v.text, 256) =>
            {
                Err(Failure::InvalidRequest)
            }
            Self::Zoom(z)
                if !point_ok(z.x, z.y)
                    || !z.width.is_finite()
                    || !z.height.is_finite()
                    || z.width < 1.0
                    || z.height < 1.0 =>
            {
                Err(Failure::InvalidRequest)
            }
            _ => Ok(()),
        }
    }
    /// The agent-visible name, as listed by `catalog`.
    pub fn name(&self) -> &'static str {
        match self {
            Self::ListApps(_) => "list_apps",
            Self::ListWindows(_) => "list_windows",
            Self::GetWindowState(_) => "get_window_state",
            Self::Click(_) => "click",
            Self::SetValue(_) => "set_value",
            Self::PressKey(_) => "press_key",
            Self::ClickPoint(_) => "click_point",
            Self::DoubleClick(_) => "double_click",
            Self::RightClick(_) => "right_click",
            Self::TypeText(_) => "type_text",
            Self::Hotkey(_) => "hotkey",
            Self::Scroll(_) => "scroll",
            Self::Drag(_) => "drag",
            Self::MoveCursor(_) => "move_cursor",
            Self::InvokeMenu(_) => "invoke_menu",
            Self::LaunchApp(_) => "launch_app",
            Self::SetWindowFrame(_) => "set_window_frame",
            Self::GetDesktopState(_) => "get_desktop_state",
            Self::VerifyState(_) => "verify_state",
            Self::Zoom(_) => "zoom",
        }
    }
    /// Reading never waits for the shared desktop (Swift `readOnlyTools`).
    fn reads_without_desktop(&self) -> bool {
        matches!(
            self,
            Self::ListApps(_) | Self::ListWindows(_) | Self::GetDesktopState(_)
        )
    }
}

#[derive(Debug)]
pub enum Request {
    Tools,
    Status,
    Release,
    Call(Tool),
}
impl Request {
    pub fn parse(bytes: &[u8]) -> Result<Self, Failure> {
        if bytes.len() > MAX_REQUEST {
            return Err(Failure::TooLarge);
        }
        let mut object = serde_json::from_slice::<Value>(bytes)
            .map_err(|_| Failure::InvalidRequest)?
            .as_object()
            .cloned()
            .ok_or(Failure::InvalidRequest)?;
        let action = object
            .remove("action")
            .and_then(|v| v.as_str().map(str::to_owned))
            .ok_or(Failure::InvalidRequest)?;
        match action.as_str() {
            "tools" | "status" | "release" if object.is_empty() => Ok(match action.as_str() {
                "tools" => Self::Tools,
                "status" => Self::Status,
                _ => Self::Release,
            }),
            "call"
                if object.len() == 2
                    && object.contains_key("name")
                    && object.contains_key("arguments") =>
            {
                let tool: Tool = serde_json::from_value(Value::Object(object))
                    .map_err(|_| Failure::InvalidRequest)?;
                tool.validate()?;
                Ok(Self::Call(tool))
            }
            _ => Err(Failure::InvalidRequest),
        }
    }
}

/// Advertise only implemented strict tool schemas, never the legacy full catalog.
/// `extended` lists the platform's own tools from `EXTENDED_TOOLS`.
pub fn catalog(extended: &[&str]) -> Value {
    let uuid = json!({"type":"string","format":"uuid"});
    let coordinate = json!({"type":"number","minimum":0});
    let schema = |properties: Value, required: Value| json!({"type":"object","properties":properties,"required":required,"additionalProperties":false});
    let pointer = json!({"element_token":uuid.clone(),"observation":uuid.clone(),"x":coordinate.clone(),"y":coordinate.clone()});
    let mut scroll = pointer.clone();
    scroll["direction"] = json!({"enum":["up","down","left","right"]});
    scroll["amount"] = json!({"type":"integer","minimum":1,"maximum":50,"default":3});
    let tools = [
        json!({"name":"list_apps","inputSchema":schema(json!({}),json!([]))}),
        json!({"name":"list_windows","inputSchema":schema(json!({"pid":{"type":["integer","null"],"minimum":1}}),json!([]))}),
        json!({"name":"get_window_state","description":"Refresh invalidates earlier tokens. A screenshot is saved as a private PNG file at screenshot.path; coordinates are window points, not image pixels.","inputSchema":schema(json!({"pid":{"type":"integer","minimum":1},"window_id":{"type":"integer","minimum":1},"max_elements":{"type":"integer","minimum":1,"maximum":128,"default":64},"include_screenshot":{"type":"boolean","default":false}}),json!(["pid","window_id"]))}),
        json!({"name":"get_desktop_state","description":"Running apps and on-screen windows. The screenshot, where supported, covers the main display without web browsers; its coordinates are screen points.","inputSchema":schema(json!({"include_screenshot":{"type":"boolean","default":false}}),json!([]))}),
        json!({"name":"verify_state","description":"Fresh read of a window: elements whose title or value contains text. Invalidates earlier tokens; issues none.","inputSchema":schema(json!({"pid":{"type":"integer","minimum":1},"window_id":{"type":"integer","minimum":1},"text":{"type":"string","minLength":1,"maxLength":256}}),json!(["pid","window_id","text"]))}),
        json!({"name":"zoom","description":"Sharper image of a region of the observed window, in window points.","inputSchema":schema(json!({"observation":uuid.clone(),"x":coordinate.clone(),"y":coordinate.clone(),"width":{"type":"number","minimum":1},"height":{"type":"number","minimum":1}}),json!(["observation","x","y","width","height"]))}),
        json!({"name":"click","description":"AX press on a fresh element token; no coordinate fallback.","inputSchema":schema(json!({"element_token":uuid.clone()}),json!(["element_token"]))}),
        json!({"name":"double_click","description":"A fresh element token, or observation with x and y from a fresh screenshot. Foreground exact window only.","inputSchema":schema(pointer.clone(),json!([]))}),
        json!({"name":"right_click","description":"A fresh element token (opens its menu), or observation with x and y from a fresh screenshot.","inputSchema":schema(pointer,json!([]))}),
        json!({"name":"set_value","inputSchema":schema(json!({"element_token":uuid.clone(),"text":{"type":"string","maxLength":16384}}),json!(["element_token","text"]))}),
        json!({"name":"type_text","description":"Types into the focused element of the foreground app.","inputSchema":schema(json!({"element_token":uuid.clone(),"text":{"type":"string","minLength":1,"maxLength":16384}}),json!(["element_token","text"]))}),
        json!({"name":"press_key","description":"Focused element in foreground app only.","inputSchema":schema(json!({"element_token":uuid.clone(),"key":{"enum":["enter","escape","tab","backspace","left","right","up","down"]}}),json!(["element_token","key"]))}),
        json!({"name":"hotkey","description":"Modifiers then one key, e.g. [\"cmd\",\"shift\",\"t\"], sent to the focused element of the foreground app.","inputSchema":schema(json!({"element_token":uuid.clone(),"keys":{"type":"array","minItems":2,"maxItems":5,"items":{"type":"string"}}}),json!(["element_token","keys"]))}),
        json!({"name":"scroll","inputSchema":schema(scroll,json!(["direction"]))}),
        json!({"name":"drag","description":"Left-button drag between two points of a fresh screenshot observation.","inputSchema":schema(json!({"observation":uuid.clone(),"from_x":coordinate.clone(),"from_y":coordinate.clone(),"to_x":coordinate.clone(),"to_y":coordinate.clone()}),json!(["observation","from_x","from_y","to_x","to_y"]))}),
        json!({"name":"move_cursor","inputSchema":schema(json!({"observation":uuid.clone(),"x":coordinate.clone(),"y":coordinate.clone()}),json!(["observation","x","y"]))}),
        json!({"name":"click_point","description":"Fresh screenshot observation required; visible foreground exact window only.","inputSchema":schema(json!({"observation":uuid,"x":coordinate.clone(),"y":coordinate}),json!(["observation","x","y"]))}),
        json!({"name":"invoke_menu","description":"Menu bar path of a running app, e.g. [\"File\",\"New Window\"].","inputSchema":schema(json!({"pid":{"type":"integer","minimum":1},"path":{"type":"array","minItems":1,"maxItems":8,"items":{"type":"string","maxLength":256}}}),json!(["pid","path"]))}),
        json!({"name":"launch_app","inputSchema":schema(json!({"bundle_id":{"type":"string","maxLength":255}}),json!(["bundle_id"]))}),
        json!({"name":"set_window_frame","description":"Moves and resizes a window, in screen points.","inputSchema":schema(json!({"pid":{"type":"integer","minimum":1},"window_id":{"type":"integer","minimum":1},"x":{"type":"number"},"y":{"type":"number"},"width":{"type":"number","minimum":1},"height":{"type":"number","minimum":1}}),json!(["pid","window_id","x","y","width","height"]))}),
    ];
    let available = |name: &str| {
        BASE_TOOLS.contains(&name) || (EXTENDED_TOOLS.contains(&name) && extended.contains(&name))
    };
    let mut unsupported = vec!["browser", "scripts", "commands", "run_steps"];
    unsupported.extend(
        EXTENDED_TOOLS
            .iter()
            .filter(|name| !extended.contains(name)),
    );
    json!({"protocol":"rust-native-v1","tokenLifetimeSeconds":15,"desktopLeaseSeconds":DESKTOP_LEASE.as_secs(),"nativeVerified":false,"automaticInputRetry":false,"inputFailuresMayHaveActed":true,
        "tools":tools.into_iter().filter(|tool| tool["name"].as_str().is_some_and(available)).collect::<Vec<_>>(),
        "unsupported":unsupported})
}

#[derive(Default)]
struct Grants {
    enabled: bool,
    threads: BTreeMap<Uuid, Uuid>,
}
#[derive(Clone, Default)]
pub struct Authority(Arc<Mutex<Grants>>);
impl Authority {
    /// Trusted native UI controls only. Never register these as agent methods.
    /// Either direction ends every thread's current epoch.
    pub fn native_enable(&self, enabled: bool) {
        let mut g = self.0.lock().unwrap_or_else(|e| e.into_inner());
        g.enabled = enabled;
        g.threads.clear();
    }
    /// Start a new epoch for a thread: its earlier observations, tokens and
    /// queued work are revoked, and its later requests run under the new one.
    pub fn native_grant(&self, thread: Uuid) -> Result<(), Failure> {
        let mut g = self.0.lock().map_err(|_| Failure::Revoked)?;
        if !g.enabled {
            return Err(Failure::Off);
        }
        if g.threads.len() >= MAX_THREADS && !g.threads.contains_key(&thread) {
            return Err(Failure::Busy);
        }
        g.threads.insert(thread, Uuid::new_v4());
        Ok(())
    }
    /// End a thread's epoch, for example when the thread is deleted.
    pub fn native_revoke(&self, thread: Uuid) {
        self.0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .threads
            .remove(&thread);
    }
    /// While Computer Use is on, every thread has access (Swift adds the
    /// capability to every message of every thread, background ones included).
    /// The first request after enabling or revocation starts a new epoch, so a
    /// stamp captured earlier never matches again.
    pub fn grant(&self, thread: Uuid) -> Result<Uuid, Failure> {
        let mut g = self.0.lock().map_err(|_| Failure::Revoked)?;
        if !g.enabled {
            return Err(Failure::Off);
        }
        if let Some(stamp) = g.threads.get(&thread) {
            return Ok(*stamp);
        }
        if g.threads.len() >= MAX_THREADS {
            return Err(Failure::Busy);
        }
        let stamp = Uuid::new_v4();
        g.threads.insert(thread, stamp);
        Ok(stamp)
    }
    pub fn enabled(&self) -> bool {
        self.0.lock().map(|g| g.enabled).unwrap_or(false)
    }
    /// The threads allowed this session, for Settings' activity list.
    pub fn granted(&self) -> Vec<Uuid> {
        self.0
            .lock()
            .map(|g| {
                if g.enabled {
                    g.threads.keys().copied().collect()
                } else {
                    Vec::new()
                }
            })
            .unwrap_or_default()
    }
}
/// Broker-internal records; raw native handles never enter agent-visible JSON.
pub struct Node {
    pub native_id: u64,
    pub role: String,
    pub title: String,
    pub value: Option<String>,
    pub secure: bool,
    pub focused: bool,
}
pub struct Snapshot {
    pub nodes: Vec<Node>,
    pub screenshot: Option<Image>,
    pub width: f64,
    pub height: f64,
}
pub struct Image {
    pub png_base64: String,
    pub width: u32,
    pub height: u32,
}
pub enum NativeCall {
    ListApps,
    ListWindows(Option<i32>),
    Observe {
        pid: i32,
        window: u32,
        limit: usize,
        screenshot: bool,
    },
    Press {
        native: u64,
    },
    SetValue {
        native: u64,
        text: String,
    },
    Key {
        native: u64,
        key: Key,
    },
    Point {
        pid: i32,
        window: u32,
        x: f64,
        y: f64,
    },
    /// Only sent for tools the backend lists in `extended_tools`.
    Extended(Extended),
}
/// Where a pointer action lands: a validated element (its center, or its own
/// menu action), or a point in the observed window, in window points.
#[derive(Debug, Clone, PartialEq)]
pub enum Target {
    Element(u64),
    Point {
        pid: i32,
        window: u32,
        x: f64,
        y: f64,
    },
}
#[derive(Debug, Clone, PartialEq)]
pub enum Extended {
    DoubleClick(Target),
    RightClick(Target),
    Scroll {
        target: Target,
        direction: Direction,
        amount: u32,
    },
    MoveCursor {
        pid: i32,
        window: u32,
        x: f64,
        y: f64,
    },
    Drag {
        pid: i32,
        window: u32,
        from: [f64; 2],
        to: [f64; 2],
    },
    TypeText {
        native: u64,
        text: String,
    },
    Hotkey {
        native: u64,
        chord: Chord,
    },
    InvokeMenu {
        pid: i32,
        path: Vec<String>,
    },
    LaunchApp {
        bundle_id: String,
    },
    SetWindowFrame {
        pid: i32,
        window: u32,
        frame: [f64; 4],
    },
    /// Main display, without web browsers. Returns `Data({"screenshot":..})`.
    DesktopScreenshot,
    /// Region of the observed window. Returns `Data({"image":..})`.
    Zoom {
        pid: i32,
        window: u32,
        region: [f64; 4],
    },
}
impl Extended {
    pub fn tool(&self) -> &'static str {
        match self {
            Self::DoubleClick(_) => "double_click",
            Self::RightClick(_) => "right_click",
            Self::Scroll { .. } => "scroll",
            Self::MoveCursor { .. } => "move_cursor",
            Self::Drag { .. } => "drag",
            Self::TypeText { .. } => "type_text",
            Self::Hotkey { .. } => "hotkey",
            Self::InvokeMenu { .. } => "invoke_menu",
            Self::LaunchApp { .. } => "launch_app",
            Self::SetWindowFrame { .. } => "set_window_frame",
            Self::DesktopScreenshot => "get_desktop_state",
            Self::Zoom { .. } => "zoom",
        }
    }
}
pub enum NativeResult {
    Data(Value),
    Snapshot(Snapshot),
    Done,
}
/// Unforgeable operation lease created only by Broker. Native adapters recheck
/// immediately before input so revocation/expiry during AX validation is honored.
pub struct Permit {
    authority: Authority,
    thread: Uuid,
    grant: Uuid,
    deadline: Instant,
}
impl Permit {
    pub fn check(&self) -> Result<(), Failure> {
        if Instant::now() >= self.deadline {
            return Err(Failure::TimedOut);
        }
        if self.authority.grant(self.thread) != Ok(self.grant) {
            return Err(Failure::Revoked);
        }
        Ok(())
    }
}
pub trait Backend {
    fn permissions(&mut self) -> Result<Permissions, Failure>;
    fn request_permission(&mut self, kind: PermissionKind) -> Result<Permissions, Failure>;
    fn call(&mut self, call: NativeCall, permit: &Permit) -> Result<NativeResult, Failure>;
    fn invalidate(&mut self);
    /// Names from `EXTENDED_TOOLS` this platform implements. `get_desktop_state`
    /// here means it can also add a display screenshot.
    fn extended_tools(&self) -> &'static [&'static str] {
        &[]
    }
}
struct Token {
    thread: Uuid,
    grant: Uuid,
    expires: Instant,
    native: u64,
    secure: bool,
    observation: Uuid,
    pid: i32,
    window: u32,
}
struct Observation {
    id: Uuid,
    thread: Uuid,
    grant: Uuid,
    expires: Instant,
    pid: i32,
    window: u32,
    width: f64,
    height: f64,
    screenshot: bool,
}
pub struct Broker<B> {
    backend: B,
    authority: Authority,
    permissions: Permissions,
    tokens: BTreeMap<Uuid, Token>,
    observation: Option<Observation>,
    /// The thread holding the shared desktop, until its lease ends.
    owner: Option<(Uuid, Instant)>,
}
impl<B: Backend> Broker<B> {
    pub fn new(backend: B, authority: Authority) -> Self {
        Self {
            backend,
            authority,
            permissions: Permissions::default(),
            tokens: BTreeMap::new(),
            observation: None,
            owner: None,
        }
    }
    pub fn cached_permissions(&self) -> Permissions {
        self.permissions
    }
    /// The thread whose actions currently hold the shared desktop.
    pub fn desktop_owner(&self) -> Option<Uuid> {
        self.owner
            .filter(|(_, expiry)| Instant::now() < *expiry)
            .map(|(thread, _)| thread)
    }
    /// Native permission buttons/refresh only. Off prevents even preflight queries.
    pub fn native_permission(
        &mut self,
        request: Option<PermissionKind>,
    ) -> Result<Permissions, Failure> {
        if !self.authority.enabled() {
            return Err(Failure::Off);
        }
        self.permissions = match request {
            Some(kind) => self.backend.request_permission(kind)?,
            None => self.backend.permissions()?,
        };
        if self.permissions.accessibility != Permission::Granted
            || self.permissions.screen_capture != Permission::Granted
        {
            self.invalidate();
        }
        Ok(self.permissions)
    }
    pub fn invalidate(&mut self) {
        let active =
            self.observation.take().is_some() || !self.tokens.is_empty() || self.owner.is_some();
        if active {
            self.backend.invalidate();
        }
        self.tokens.clear();
        self.owner = None;
    }
    pub fn reap_revoked(&mut self) {
        if !self.authority.enabled() {
            self.permissions = Permissions::default();
        }
        let now = Instant::now();
        let observation_ended = self
            .observation
            .as_ref()
            .is_some_and(|o| self.authority.grant(o.thread) != Ok(o.grant) || now >= o.expires);
        let lease_ended = self.owner.is_some_and(|(_, expiry)| now >= expiry);
        if observation_ended || lease_ended || (!self.authority.enabled() && self.owner.is_some()) {
            self.invalidate();
        }
    }
    fn valid(&self, thread: Uuid, grant: Uuid, deadline: Instant) -> Result<(), Failure> {
        if Instant::now() >= deadline {
            return Err(Failure::TimedOut);
        }
        if self.authority.grant(thread) != Ok(grant) {
            return Err(Failure::Revoked);
        }
        Ok(())
    }
    fn token(&self, id: Uuid, thread: Uuid, grant: Uuid) -> Result<&Token, Failure> {
        self.tokens
            .get(&id)
            .filter(|t| {
                t.thread == thread
                    && t.grant == grant
                    && Instant::now() < t.expires
                    && self.observation.as_ref().is_some_and(|o| {
                        o.id == t.observation && o.pid == t.pid && o.window == t.window
                    })
            })
            .ok_or(Failure::StaleObservation)
    }
    /// An actionable element token: never a secure (password) field.
    fn actionable(&self, id: Uuid, thread: Uuid, grant: Uuid) -> Result<u64, Failure> {
        let token = self.token(id, thread, grant)?;
        if token.secure {
            return Err(Failure::PermissionDenied);
        }
        Ok(token.native)
    }
    /// The thread's current observation; `screenshot` requires pixels from it.
    fn observed(
        &self,
        id: Uuid,
        thread: Uuid,
        grant: Uuid,
        screenshot: bool,
    ) -> Result<&Observation, Failure> {
        self.observation
            .as_ref()
            .filter(|o| {
                o.id == id
                    && o.thread == thread
                    && o.grant == grant
                    && Instant::now() < o.expires
                    && (o.screenshot || !screenshot)
            })
            .ok_or(Failure::StaleObservation)
    }
    /// A point of a fresh screenshot observation, inside its window.
    fn point(
        &self,
        id: Uuid,
        thread: Uuid,
        grant: Uuid,
        x: f64,
        y: f64,
    ) -> Result<Target, Failure> {
        let o = self.observed(id, thread, grant, true)?;
        if x >= o.width || y >= o.height {
            return Err(Failure::StaleObservation);
        }
        if self.permissions.screen_capture != Permission::Granted {
            return Err(Failure::PermissionDenied);
        }
        Ok(Target::Point {
            pid: o.pid,
            window: o.window,
            x,
            y,
        })
    }
    fn target(
        &self,
        element: Option<Uuid>,
        observation: Option<Uuid>,
        x: Option<f64>,
        y: Option<f64>,
        thread: Uuid,
        grant: Uuid,
    ) -> Result<Target, Failure> {
        match (element, observation, x, y) {
            (Some(element), None, None, None) => {
                Ok(Target::Element(self.actionable(element, thread, grant)?))
            }
            (None, Some(observation), Some(x), Some(y)) => {
                self.point(observation, thread, grant, x, y)
            }
            _ => Err(Failure::InvalidRequest),
        }
    }
    /// Take or keep the shared desktop for one thread at a time. Another
    /// thread's hold blocks until it releases or its lease ends.
    fn claim(&mut self, thread: Uuid) -> Result<(), Failure> {
        match self.owner {
            Some((owner, expiry)) if owner != thread && Instant::now() < expiry => {
                Err(Failure::Busy)
            }
            Some((owner, _)) if owner == thread => Ok(()),
            _ => {
                // The previous owner's observation and tokens end with its lease.
                self.invalidate();
                self.owner = Some((thread, Instant::now() + DESKTOP_LEASE));
                Ok(())
            }
        }
    }
    fn extend_lease(&mut self, thread: Uuid) {
        if let Some((owner, expiry)) = self.owner.as_mut()
            && *owner == thread
        {
            *expiry = Instant::now() + DESKTOP_LEASE;
        }
    }
    fn status(&self, thread: Uuid) -> Value {
        let desktop = match self.desktop_owner() {
            None => "free",
            Some(owner) if owner == thread => "this thread",
            Some(_) => "another thread",
        };
        json!({"enabled":true,"permissions":self.permissions,"desktop":desktop,"desktopBusy":desktop == "another thread","nativeVerified":false})
    }
    pub fn execute(
        &mut self,
        thread: Uuid,
        grant: Uuid,
        request: Request,
        deadline: Instant,
    ) -> Result<Value, Failure> {
        self.reap_revoked();
        self.valid(thread, grant, deadline)?;
        let tool = match request {
            Request::Tools => return Ok(catalog(self.backend.extended_tools())),
            Request::Status => return Ok(self.status(thread)),
            Request::Release => {
                if self.owner.is_some_and(|(owner, _)| owner == thread) {
                    self.invalidate();
                }
                return Ok(json!({"released":true}));
            }
            Request::Call(tool) => tool,
        };
        tool.validate()?;
        let name = tool.name();
        if EXTENDED_TOOLS.contains(&name) && !self.backend.extended_tools().contains(&name) {
            return Err(Failure::Unsupported);
        }
        let shared = !tool.reads_without_desktop();
        if shared {
            self.claim(thread)?;
        }
        self.permissions = match self.backend.permissions() {
            Ok(p) => p,
            Err(e) => {
                self.invalidate();
                return Err(e);
            }
        };
        self.valid(thread, grant, deadline)?;
        if self.permissions.accessibility != Permission::Granted {
            self.invalidate();
            return Err(Failure::PermissionDenied);
        }
        let permit = Permit {
            authority: self.authority.clone(),
            thread,
            grant,
            deadline,
        };
        let value = match tool {
            Tool::GetDesktopState(d) => self.desktop_state(d, &permit)?,
            Tool::VerifyState(v) => self.verify(v, &permit)?,
            tool => self.call(tool, thread, grant, &permit)?,
        };
        if serde_json::to_vec(&value)
            .map_err(|_| Failure::Native)?
            .len()
            > MAX_RESULT
        {
            self.invalidate();
            return Err(Failure::TooLarge);
        }
        self.valid(thread, grant, deadline)?;
        if shared {
            self.extend_lease(thread);
        }
        Ok(value)
    }
    /// Apps and windows read without the shared desktop; the display
    /// screenshot only where the platform implements it.
    fn desktop_state(&mut self, d: Desktop, permit: &Permit) -> Result<Value, Failure> {
        let mut data = |call| match self.backend.call(call, permit)? {
            NativeResult::Data(value) => Ok(value),
            _ => Err(Failure::Native),
        };
        let apps = data(NativeCall::ListApps)?;
        let windows = data(NativeCall::ListWindows(None))?;
        let screenshot = if d.include_screenshot {
            if !self.backend.extended_tools().contains(&"get_desktop_state") {
                return Err(Failure::Unsupported);
            }
            if self.permissions.screen_capture != Permission::Granted {
                return Err(Failure::PermissionDenied);
            }
            match self
                .backend
                .call(NativeCall::Extended(Extended::DesktopScreenshot), permit)?
            {
                NativeResult::Data(value) => value["screenshot"].clone(),
                _ => return Err(Failure::Native),
            }
        } else {
            Value::Null
        };
        permit.check()?;
        Ok(
            json!({"apps":apps,"windows":windows,"screenshot":screenshot,"coordinateSpace":"screen_points"}),
        )
    }
    /// A fresh read that issues no tokens. Earlier tokens end, as with any
    /// refresh, because the native adapter replaces its observed elements.
    fn verify(&mut self, v: Verify, permit: &Permit) -> Result<Value, Failure> {
        let owner = self.owner;
        self.invalidate();
        self.owner = owner;
        let result = self.backend.call(
            NativeCall::Observe {
                pid: v.pid,
                window: v.window_id,
                limit: MAX_NODES,
                screenshot: false,
            },
            permit,
        );
        // The adapter's elements are never actionable through this call.
        self.backend.invalidate();
        let NativeResult::Snapshot(snapshot) = result? else {
            return Err(Failure::Native);
        };
        permit.check()?;
        let needle = v.text.to_lowercase();
        let matches = snapshot
            .nodes
            .iter()
            .filter(|node| {
                node.title.to_lowercase().contains(&needle)
                    || (!node.secure
                        && node
                            .value
                            .as_ref()
                            .is_some_and(|value| value.to_lowercase().contains(&needle)))
            })
            .take(16)
            .map(|node| json!({"role":node.role.chars().take(128).collect::<String>(),"title":node.title.chars().take(256).collect::<String>(),"value":if node.secure{None}else{node.value.as_ref().map(|v|v.chars().take(1024).collect::<String>())},"focused":node.focused}))
            .collect::<Vec<_>>();
        Ok(
            json!({"matched":!matches.is_empty(),"matches":matches,"inspected":snapshot.nodes.len(),"pid":v.pid,"window_id":v.window_id}),
        )
    }
    fn call(
        &mut self,
        tool: Tool,
        thread: Uuid,
        grant: Uuid,
        permit: &Permit,
    ) -> Result<Value, Failure> {
        let call = match tool {
            Tool::ListApps(_) => NativeCall::ListApps,
            Tool::ListWindows(w) => NativeCall::ListWindows(w.pid),
            Tool::GetWindowState(o) => {
                if o.include_screenshot && self.permissions.screen_capture != Permission::Granted {
                    return Err(Failure::PermissionDenied);
                }
                // A refresh replaces this thread's observation; it keeps the desktop.
                let owner = self.owner;
                self.invalidate();
                self.owner = owner;
                NativeCall::Observe {
                    pid: o.pid,
                    window: o.window_id,
                    limit: o.max_elements,
                    screenshot: o.include_screenshot,
                }
            }
            Tool::Click(e) => NativeCall::Press {
                native: self.actionable(e.element_token, thread, grant)?,
            },
            Tool::SetValue(v) => NativeCall::SetValue {
                native: self.actionable(v.element_token, thread, grant)?,
                text: v.text,
            },
            Tool::PressKey(v) => NativeCall::Key {
                native: self.actionable(v.element_token, thread, grant)?,
                key: v.key,
            },
            Tool::ClickPoint(p) => match self.point(p.observation, thread, grant, p.x, p.y)? {
                Target::Point { pid, window, x, y } => NativeCall::Point { pid, window, x, y },
                Target::Element(_) => return Err(Failure::Native),
            },
            Tool::DoubleClick(p) => NativeCall::Extended(Extended::DoubleClick(self.target(
                p.element_token,
                p.observation,
                p.x,
                p.y,
                thread,
                grant,
            )?)),
            Tool::RightClick(p) => NativeCall::Extended(Extended::RightClick(self.target(
                p.element_token,
                p.observation,
                p.x,
                p.y,
                thread,
                grant,
            )?)),
            Tool::Scroll(s) => NativeCall::Extended(Extended::Scroll {
                target: self.target(s.element_token, s.observation, s.x, s.y, thread, grant)?,
                direction: s.direction,
                amount: s.amount,
            }),
            Tool::MoveCursor(p) => match self.point(p.observation, thread, grant, p.x, p.y)? {
                Target::Point { pid, window, x, y } => {
                    NativeCall::Extended(Extended::MoveCursor { pid, window, x, y })
                }
                Target::Element(_) => return Err(Failure::Native),
            },
            Tool::Drag(d) => {
                let from = self.point(d.observation, thread, grant, d.from_x, d.from_y)?;
                self.point(d.observation, thread, grant, d.to_x, d.to_y)?;
                let Target::Point { pid, window, .. } = from else {
                    return Err(Failure::Native);
                };
                NativeCall::Extended(Extended::Drag {
                    pid,
                    window,
                    from: [d.from_x, d.from_y],
                    to: [d.to_x, d.to_y],
                })
            }
            Tool::TypeText(t) => NativeCall::Extended(Extended::TypeText {
                native: self.actionable(t.element_token, thread, grant)?,
                text: t.text,
            }),
            Tool::Hotkey(h) => NativeCall::Extended(Extended::Hotkey {
                native: self.actionable(h.element_token, thread, grant)?,
                chord: Chord::parse(&h.keys).ok_or(Failure::InvalidRequest)?,
            }),
            Tool::InvokeMenu(m) => NativeCall::Extended(Extended::InvokeMenu {
                pid: m.pid,
                path: m.path,
            }),
            Tool::LaunchApp(l) => NativeCall::Extended(Extended::LaunchApp {
                bundle_id: l.bundle_id,
            }),
            Tool::SetWindowFrame(f) => NativeCall::Extended(Extended::SetWindowFrame {
                pid: f.pid,
                window: f.window_id,
                frame: [f.x, f.y, f.width, f.height],
            }),
            Tool::Zoom(z) => {
                let o = self.observed(z.observation, thread, grant, false)?;
                if z.x + z.width > o.width + 0.5 || z.y + z.height > o.height + 0.5 {
                    return Err(Failure::InvalidRequest);
                }
                if self.permissions.screen_capture != Permission::Granted {
                    return Err(Failure::PermissionDenied);
                }
                NativeCall::Extended(Extended::Zoom {
                    pid: o.pid,
                    window: o.window,
                    region: [z.x, z.y, z.width, z.height],
                })
            }
            Tool::GetDesktopState(_) | Tool::VerifyState(_) => return Err(Failure::Native),
        };
        let target = match &call {
            NativeCall::Observe { pid, window, .. } => Some((*pid, *window)),
            _ => None,
        };
        // Zoom only reads the observed window; everything else here acts.
        let mutation = match &call {
            NativeCall::Press { .. }
            | NativeCall::SetValue { .. }
            | NativeCall::Key { .. }
            | NativeCall::Point { .. } => true,
            NativeCall::Extended(extended) => !matches!(extended, Extended::Zoom { .. }),
            _ => false,
        };
        self.valid(thread, grant, permit.deadline)?;
        let result = self.backend.call(call, permit);
        if result.is_err() && target.is_some() {
            self.invalidate();
        }
        // A failed/timed-out action may already have acted; tokens are consumed
        // regardless and no operation is ever automatically retried. The
        // desktop stays with this thread until release or lease end.
        if mutation {
            let owner = self.owner;
            self.invalidate();
            self.owner = owner;
        }
        if let Err(error) = self.valid(thread, grant, permit.deadline) {
            self.invalidate();
            return Err(error);
        }
        let result = result?;
        if target.is_some() && !matches!(result, NativeResult::Snapshot(_)) {
            self.invalidate();
            return Err(Failure::Native);
        }
        Ok(match result {
            NativeResult::Data(value) => value,
            NativeResult::Done => json!({"dispatched":true,"verificationRequired":true}),
            NativeResult::Snapshot(snapshot) => {
                let (pid, window) = target.ok_or(Failure::Native)?;
                self.publish(snapshot, thread, grant, pid, window)?
            }
        })
    }
    fn publish(
        &mut self,
        snapshot: Snapshot,
        thread: Uuid,
        grant: Uuid,
        pid: i32,
        window: u32,
    ) -> Result<Value, Failure> {
        if snapshot.nodes.len() > MAX_NODES
            || !snapshot.width.is_finite()
            || !snapshot.height.is_finite()
            || snapshot.width <= 0.0
            || snapshot.height <= 0.0
        {
            self.invalidate();
            return Err(Failure::TooLarge);
        }
        let observation = Uuid::new_v4();
        let expires = Instant::now() + TOKEN_LIFETIME;
        let mut nodes = vec![];
        for node in snapshot.nodes {
            let id = Uuid::new_v4();
            self.tokens.insert(
                id,
                Token {
                    thread,
                    grant,
                    expires,
                    native: node.native_id,
                    secure: node.secure,
                    observation,
                    pid,
                    window,
                },
            );
            nodes.push(json!({"element_token":id,"role":node.role.chars().take(128).collect::<String>(),"title":node.title.chars().take(256).collect::<String>(),"value":if node.secure{None}else{node.value.map(|v|v.chars().take(1024).collect::<String>())},"secure":node.secure,"focused":node.focused}));
        }
        let image=snapshot.screenshot.map(|i|json!({"encoding":"png_base64","data":i.png_base64,"width":i.width,"height":i.height}));
        self.observation = Some(Observation {
            id: observation,
            thread,
            grant,
            expires,
            pid,
            window,
            width: snapshot.width,
            height: snapshot.height,
            screenshot: image.is_some(),
        });
        Ok(
            json!({"observation":observation,"elements":nodes,"screenshot":image,"coordinateSpace":"window_points","window_width":snapshot.width,"window_height":snapshot.height,"pid":pid,"window_id":window}),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fake {
        calls: usize,
        authority: Option<Authority>,
    }
    impl Backend for Fake {
        fn permissions(&mut self) -> Result<Permissions, Failure> {
            self.calls += 1;
            Ok(Permissions {
                accessibility: Permission::Granted,
                screen_capture: Permission::Granted,
            })
        }
        fn request_permission(&mut self, _: PermissionKind) -> Result<Permissions, Failure> {
            self.permissions()
        }
        fn invalidate(&mut self) {}
        fn call(&mut self, call: NativeCall, permit: &Permit) -> Result<NativeResult, Failure> {
            permit.check()?;
            self.calls += 1;
            if let Some(a) = &self.authority {
                a.native_enable(false);
            }
            Ok(match call {
                NativeCall::Observe { .. } => NativeResult::Snapshot(Snapshot {
                    nodes: vec![Node {
                        native_id: 7,
                        role: "text".into(),
                        title: "fixture".into(),
                        value: Some("secret".into()),
                        secure: true,
                        focused: false,
                    }],
                    screenshot: None,
                    width: 100.0,
                    height: 100.0,
                }),
                _ => NativeResult::Done,
            })
        }
    }
    fn observe() -> Request {
        Request::parse(
            br#"{"action":"call","name":"get_window_state","arguments":{"pid":10,"window_id":20}}"#,
        )
        .unwrap()
    }
    fn granted() -> (Authority, Uuid, Uuid) {
        let a = Authority::default();
        let t = Uuid::new_v4();
        a.native_enable(true);
        a.native_grant(t).unwrap();
        let g = a.grant(t).unwrap();
        (a, t, g)
    }
    #[test]
    fn strict_protocol_refuses_authority_scripts_urls_and_unknown_fields() {
        for text in [
            r#"{"action":"enable"}"#,
            r#"{"action":"status","grant":true}"#,
            r#"{"action":"call","name":"run_script","arguments":{}}"#,
            r#"{"action":"call","name":"list_apps","arguments":{"url":"https://example.com"}}"#,
            r#"{"action":"call","name":"get_window_state","arguments":{"pid":1,"window_id":2,"max_elements":999}}"#,
        ] {
            assert!(Request::parse(text.as_bytes()).is_err());
        }
    }
    #[test]
    fn constructor_and_off_requests_are_inert() {
        let a = Authority::default();
        let mut b = Broker::new(
            Fake {
                calls: 0,
                authority: None,
            },
            a,
        );
        assert_eq!(b.native_permission(None), Err(Failure::Off));
        assert_eq!(
            b.execute(
                Uuid::new_v4(),
                Uuid::new_v4(),
                Request::Status,
                Instant::now() + Duration::from_secs(1)
            ),
            Err(Failure::Revoked)
        );
        assert_eq!(b.backend.calls, 0);
    }
    #[test]
    fn tokens_are_secure_thread_scoped_expiring_and_revoked() {
        let (a, t, g) = granted();
        let mut b = Broker::new(
            Fake {
                calls: 0,
                authority: None,
            },
            a.clone(),
        );
        let result = b
            .execute(t, g, observe(), Instant::now() + Duration::from_secs(1))
            .unwrap();
        assert!(result["elements"][0]["value"].is_null());
        let token =
            Uuid::parse_str(result["elements"][0]["element_token"].as_str().unwrap()).unwrap();
        assert!(matches!(
            b.execute(
                t,
                g,
                Request::Call(Tool::Click(Element {
                    element_token: token
                })),
                Instant::now() + Duration::from_secs(1)
            ),
            Err(Failure::PermissionDenied)
        ));
        let other = Uuid::new_v4();
        a.native_grant(other).unwrap();
        assert!(b.token(token, other, a.grant(other).unwrap()).is_err());
        b.tokens.get_mut(&token).unwrap().expires = Instant::now() - Duration::from_secs(1);
        assert!(b.token(token, t, g).is_err());
        a.native_revoke(t);
        assert!(
            b.execute(
                t,
                g,
                Request::Status,
                Instant::now() + Duration::from_secs(1)
            )
            .is_err()
        );
        assert!(b.tokens.is_empty());
    }
    #[test]
    fn observation_revision_window_and_single_use_are_bound() {
        let (a, t, g) = granted();
        let mut b = Broker::new(
            Fake {
                calls: 0,
                authority: None,
            },
            a.clone(),
        );
        let result = b
            .execute(t, g, observe(), Instant::now() + Duration::from_secs(1))
            .unwrap();
        assert_eq!(result["pid"], 10);
        assert_eq!(result["window_id"], 20);
        let id = Uuid::parse_str(result["elements"][0]["element_token"].as_str().unwrap()).unwrap();
        b.tokens.get_mut(&id).unwrap().window = 99;
        assert!(b.token(id, t, g).is_err());
        b.tokens.get_mut(&id).unwrap().window = 20;
        b.tokens.get_mut(&id).unwrap().secure = false; // synthetic non-secure actionable control
        b.execute(
            t,
            g,
            Request::Call(Tool::Click(Element { element_token: id })),
            Instant::now() + Duration::from_secs(1),
        )
        .unwrap();
        assert!(b.tokens.is_empty());
        assert_eq!(
            b.execute(
                t,
                g,
                Request::Call(Tool::Click(Element { element_token: id })),
                Instant::now() + Duration::from_secs(1)
            ),
            Err(Failure::StaleObservation)
        );
        let result = b
            .execute(t, g, observe(), Instant::now() + Duration::from_secs(1))
            .unwrap();
        let old =
            Uuid::parse_str(result["elements"][0]["element_token"].as_str().unwrap()).unwrap();
        b.execute(t, g, observe(), Instant::now() + Duration::from_secs(1))
            .unwrap();
        assert!(b.token(old, t, g).is_err());
    }
    #[test]
    fn desktop_owner_blocks_other_thread_until_release() {
        let (a, t, g) = granted();
        let other = Uuid::new_v4();
        a.native_grant(other).unwrap();
        let other_grant = a.grant(other).unwrap();
        let mut b = Broker::new(
            Fake {
                calls: 0,
                authority: None,
            },
            a,
        );
        b.execute(t, g, observe(), Instant::now() + Duration::from_secs(1))
            .unwrap();
        assert_eq!(
            b.execute(
                other,
                other_grant,
                observe(),
                Instant::now() + Duration::from_secs(1)
            ),
            Err(Failure::Busy)
        );
        b.execute(
            t,
            g,
            Request::Release,
            Instant::now() + Duration::from_secs(1),
        )
        .unwrap();
        assert!(
            b.execute(
                other,
                other_grant,
                observe(),
                Instant::now() + Duration::from_secs(1)
            )
            .is_ok()
        );
    }
    #[test]
    fn directly_constructed_invalid_request_is_rejected_before_backend() {
        let (a, t, g) = granted();
        let mut b = Broker::new(
            Fake {
                calls: 0,
                authority: None,
            },
            a,
        );
        let request = Request::Call(Tool::ClickPoint(Point {
            observation: Uuid::new_v4(),
            x: f64::NAN,
            y: 0.0,
        }));
        assert_eq!(
            b.execute(t, g, request, Instant::now() + Duration::from_secs(1)),
            Err(Failure::InvalidRequest)
        );
        assert_eq!(b.backend.calls, 0);
    }
    #[test]
    fn revoked_late_result_is_not_published_and_deadline_prevents_native_calls() {
        let (a, t, g) = granted();
        let mut b = Broker::new(
            Fake {
                calls: 0,
                authority: Some(a.clone()),
            },
            a,
        );
        assert_eq!(
            b.execute(t, g, observe(), Instant::now() - Duration::from_secs(1)),
            Err(Failure::TimedOut)
        );
        assert_eq!(b.backend.calls, 0);
        assert_eq!(
            b.execute(t, g, observe(), Instant::now() + Duration::from_secs(1)),
            Err(Failure::Revoked)
        );
        assert!(b.tokens.is_empty());
        assert!(b.owner.is_none());
    }
    /// Records native calls; serves every extended tool.
    struct Wide {
        calls: Vec<String>,
        extended: &'static [&'static str],
    }
    impl Backend for Wide {
        fn permissions(&mut self) -> Result<Permissions, Failure> {
            Ok(Permissions {
                accessibility: Permission::Granted,
                screen_capture: Permission::Granted,
            })
        }
        fn request_permission(&mut self, _: PermissionKind) -> Result<Permissions, Failure> {
            self.permissions()
        }
        fn invalidate(&mut self) {}
        fn extended_tools(&self) -> &'static [&'static str] {
            self.extended
        }
        fn call(&mut self, call: NativeCall, permit: &Permit) -> Result<NativeResult, Failure> {
            permit.check()?;
            Ok(match call {
                NativeCall::ListApps => {
                    self.calls.push("apps".into());
                    NativeResult::Data(json!([{"pid":10,"name":"Fixture"}]))
                }
                NativeCall::ListWindows(_) => {
                    self.calls.push("windows".into());
                    NativeResult::Data(json!([{"pid":10,"window_id":20}]))
                }
                NativeCall::Observe { screenshot, .. } => {
                    self.calls.push("observe".into());
                    NativeResult::Snapshot(Snapshot {
                        nodes: vec![
                            Node {
                                native_id: 7,
                                role: "AXButton".into(),
                                title: "Save Changes".into(),
                                value: None,
                                secure: false,
                                focused: true,
                            },
                            Node {
                                native_id: 8,
                                role: "AXTextField".into(),
                                title: "Password".into(),
                                value: Some("save".into()),
                                secure: true,
                                focused: false,
                            },
                        ],
                        screenshot: screenshot.then(|| Image {
                            png_base64: "fixture".into(),
                            width: 100,
                            height: 100,
                        }),
                        width: 100.0,
                        height: 100.0,
                    })
                }
                NativeCall::Extended(Extended::DesktopScreenshot) => {
                    self.calls.push("desktop".into());
                    NativeResult::Data(json!({"screenshot":{"data":"fixture"}}))
                }
                NativeCall::Extended(extended) => {
                    self.calls.push(format!("{extended:?}"));
                    NativeResult::Done
                }
                _ => {
                    self.calls.push("other".into());
                    NativeResult::Done
                }
            })
        }
    }
    /// Every extended tool, plus the display screenshot.
    const FULL: &[&str] = &[
        "double_click",
        "right_click",
        "type_text",
        "hotkey",
        "scroll",
        "drag",
        "move_cursor",
        "invoke_menu",
        "launch_app",
        "set_window_frame",
        "zoom",
        "get_desktop_state",
    ];
    fn wide(extended: &'static [&'static str]) -> (Broker<Wide>, Authority, Uuid, Uuid) {
        let (a, t, g) = granted();
        (
            Broker::new(
                Wide {
                    calls: vec![],
                    extended,
                },
                a.clone(),
            ),
            a,
            t,
            g,
        )
    }
    fn call(text: &str) -> Request {
        Request::parse(text.as_bytes()).unwrap()
    }
    fn soon() -> Instant {
        Instant::now() + Duration::from_secs(1)
    }
    #[test]
    fn enabled_authority_grants_every_thread_and_revocation_starts_a_new_epoch() {
        let a = Authority::default();
        let t = Uuid::new_v4();
        assert_eq!(a.grant(t), Err(Failure::Off));
        a.native_enable(true);
        let first = a.grant(t).unwrap();
        assert_eq!(a.grant(t), Ok(first), "a thread keeps its epoch while on");
        assert_ne!(a.grant(Uuid::new_v4()), Ok(first));
        a.native_revoke(t);
        let second = a.grant(t).unwrap();
        assert_ne!(second, first, "revocation never revives the old epoch");
        a.native_enable(false);
        assert_eq!(a.grant(t), Err(Failure::Off));
        a.native_enable(true);
        assert_ne!(a.grant(t), Ok(second));
    }
    #[test]
    fn saved_switch_is_on_only_for_true() {
        assert!(saved_enabled(&json!({"computerUseEnabled":true})));
        for settings in [
            json!({}),
            json!({"computerUseEnabled":false}),
            json!({"computerUseEnabled":"true"}),
            json!({"computerUseEnabled":1}),
            json!(null),
        ] {
            assert!(!saved_enabled(&settings));
        }
    }
    #[test]
    fn catalog_lists_only_tools_the_platform_implements() {
        let names = |value: &Value| {
            value["tools"]
                .as_array()
                .unwrap()
                .iter()
                .map(|tool| tool["name"].as_str().unwrap().to_owned())
                .collect::<Vec<_>>()
        };
        let base = catalog(&[]);
        assert_eq!(names(&base).len(), BASE_TOOLS.len());
        assert!(!names(&base).contains(&"hotkey".to_owned()));
        assert!(
            base["unsupported"]
                .as_array()
                .unwrap()
                .contains(&json!("hotkey"))
        );
        let full = catalog(EXTENDED_TOOLS);
        let listed = names(&full);
        assert_eq!(listed.len(), BASE_TOOLS.len() + EXTENDED_TOOLS.len());
        for name in BASE_TOOLS.iter().chain(EXTENDED_TOOLS) {
            assert!(listed.contains(&(*name).to_owned()), "{name}");
        }
        assert_eq!(
            full["unsupported"],
            json!(["browser", "scripts", "commands", "run_steps"])
        );
        assert_eq!(full["desktopLeaseSeconds"], 60);
    }
    #[test]
    fn extended_tool_arguments_are_strict() {
        let token = Uuid::new_v4();
        let observation = Uuid::new_v4();
        for text in [
            format!(r#"{{"action":"call","name":"double_click","arguments":{{"element_token":"{token}","observation":"{observation}","x":1,"y":1}}}}"#),
            format!(r#"{{"action":"call","name":"double_click","arguments":{{"observation":"{observation}","x":1}}}}"#),
            r#"{"action":"call","name":"right_click","arguments":{}}"#.to_owned(),
            format!(r#"{{"action":"call","name":"scroll","arguments":{{"element_token":"{token}","direction":"up","amount":0}}}}"#),
            format!(r#"{{"action":"call","name":"scroll","arguments":{{"element_token":"{token}","direction":"sideways"}}}}"#),
            format!(r#"{{"action":"call","name":"type_text","arguments":{{"element_token":"{token}","text":""}}}}"#),
            format!(r#"{{"action":"call","name":"hotkey","arguments":{{"element_token":"{token}","keys":["c"]}}}}"#),
            format!(r#"{{"action":"call","name":"hotkey","arguments":{{"element_token":"{token}","keys":["cmd","cmd","c"]}}}}"#),
            format!(r#"{{"action":"call","name":"hotkey","arguments":{{"element_token":"{token}","keys":["cmd","hyper","c"]}}}}"#),
            format!(r#"{{"action":"call","name":"drag","arguments":{{"observation":"{observation}","from_x":-1,"from_y":0,"to_x":1,"to_y":1}}}}"#),
            r#"{"action":"call","name":"invoke_menu","arguments":{"pid":1,"path":[]}}"#.to_owned(),
            r#"{"action":"call","name":"invoke_menu","arguments":{"pid":1,"path":[" "]}}"#.to_owned(),
            r#"{"action":"call","name":"launch_app","arguments":{"bundle_id":"com.example/../x"}}"#.to_owned(),
            r#"{"action":"call","name":"launch_app","arguments":{"bundle_id":"com.example","url":"https://example.com"}}"#.to_owned(),
            r#"{"action":"call","name":"set_window_frame","arguments":{"pid":1,"window_id":2,"x":0,"y":0,"width":0,"height":10}}"#.to_owned(),
            r#"{"action":"call","name":"verify_state","arguments":{"pid":1,"window_id":2,"text":""}}"#.to_owned(),
            format!(r#"{{"action":"call","name":"zoom","arguments":{{"observation":"{observation}","x":0,"y":0,"width":0.5,"height":5}}}}"#),
            r#"{"action":"call","name":"run_steps","arguments":{"steps":[]}}"#.to_owned(),
        ] {
            assert!(Request::parse(text.as_bytes()).is_err(), "{text}");
        }
        assert_eq!(
            Chord::parse(&["Command".into(), "shift".into(), "T".into()]),
            Some(Chord {
                modifiers: vec![Modifier::Command, Modifier::Shift],
                key: "t".into()
            })
        );
        assert_eq!(
            Chord::parse(&["ctrl".into(), "PageDown".into()])
                .unwrap()
                .key,
            "page_down"
        );
        assert!(Chord::parse(&["ctrl".into(), "f13".into()]).is_none());
    }
    #[test]
    fn unsupported_extended_tool_never_reaches_backend_or_takes_the_desktop() {
        let (mut b, _a, t, g) = wide(&[]);
        let token = Uuid::new_v4();
        assert_eq!(
            b.execute(
                t,
                g,
                call(&format!(r#"{{"action":"call","name":"type_text","arguments":{{"element_token":"{token}","text":"hi"}}}}"#)),
                soon()
            ),
            Err(Failure::Unsupported)
        );
        assert!(b.backend.calls.is_empty());
        assert!(b.desktop_owner().is_none());
    }
    #[test]
    fn reading_never_waits_for_the_desktop_and_actions_wait_for_its_lease() {
        let (mut b, a, t, g) = wide(FULL);
        let other = Uuid::new_v4();
        let other_grant = a.grant(other).unwrap();
        b.execute(t, g, observe(), soon()).unwrap();
        assert_eq!(b.desktop_owner(), Some(t));
        assert_eq!(
            b.execute(other, other_grant, Request::Status, soon())
                .unwrap()["desktop"],
            "another thread"
        );
        assert!(
            b.execute(
                other,
                other_grant,
                call(r#"{"action":"call","name":"list_windows","arguments":{}}"#),
                soon()
            )
            .is_ok()
        );
        let desktop = b
            .execute(
                other,
                other_grant,
                call(r#"{"action":"call","name":"get_desktop_state","arguments":{"include_screenshot":true}}"#),
                soon(),
            )
            .unwrap();
        assert_eq!(desktop["windows"][0]["window_id"], 20);
        assert_eq!(desktop["screenshot"]["data"], "fixture");
        assert_eq!(
            b.execute(
                other,
                other_grant,
                call(r#"{"action":"call","name":"launch_app","arguments":{"bundle_id":"com.example.App"}}"#),
                soon()
            ),
            Err(Failure::Busy)
        );
        // The owner's lease ends on its own after its last action.
        b.owner.as_mut().unwrap().1 = Instant::now() - Duration::from_millis(1);
        assert!(b.desktop_owner().is_none());
        b.execute(
            other,
            other_grant,
            call(r#"{"action":"call","name":"launch_app","arguments":{"bundle_id":"com.example.App"}}"#),
            soon(),
        )
        .unwrap();
        assert_eq!(b.desktop_owner(), Some(other));
        assert!(
            b.tokens.is_empty(),
            "the previous owner's tokens end with its lease"
        );
        assert!(
            b.backend
                .calls
                .iter()
                .any(|call| call.contains("LaunchApp") && call.contains("com.example.App"))
        );
    }
    #[test]
    fn element_and_point_targets_resolve_through_fresh_observations_only() {
        let (mut b, _a, t, g) = wide(FULL);
        let result = b
            .execute(
                t,
                g,
                call(r#"{"action":"call","name":"get_window_state","arguments":{"pid":10,"window_id":20,"include_screenshot":true}}"#),
                soon(),
            )
            .unwrap();
        let button = result["elements"][0]["element_token"]
            .as_str()
            .unwrap()
            .to_owned();
        let password = result["elements"][1]["element_token"]
            .as_str()
            .unwrap()
            .to_owned();
        let observation = result["observation"].as_str().unwrap().to_owned();
        assert_eq!(
            b.execute(
                t,
                g,
                call(&format!(r#"{{"action":"call","name":"type_text","arguments":{{"element_token":"{password}","text":"x"}}}}"#)),
                soon()
            ),
            Err(Failure::PermissionDenied)
        );
        assert_eq!(
            b.execute(
                t,
                g,
                call(&format!(r#"{{"action":"call","name":"double_click","arguments":{{"observation":"{observation}","x":150,"y":1}}}}"#)),
                soon()
            ),
            Err(Failure::StaleObservation)
        );
        b.execute(
            t,
            g,
            call(&format!(r#"{{"action":"call","name":"zoom","arguments":{{"observation":"{observation}","x":10,"y":10,"width":20,"height":20}}}}"#)),
            soon(),
        )
        .unwrap();
        assert!(!b.tokens.is_empty(), "zoom only reads the observed window");
        b.execute(
            t,
            g,
            call(&format!(r#"{{"action":"call","name":"right_click","arguments":{{"element_token":"{button}"}}}}"#)),
            soon(),
        )
        .unwrap();
        assert!(b.tokens.is_empty(), "an action consumes its observation");
        assert_eq!(b.desktop_owner(), Some(t), "and keeps the desktop");
        assert!(
            b.backend
                .calls
                .iter()
                .any(|c| c == "RightClick(Element(7))")
        );
        assert_eq!(
            b.execute(
                t,
                g,
                call(&format!(r#"{{"action":"call","name":"scroll","arguments":{{"observation":"{observation}","x":5,"y":5,"direction":"down"}}}}"#)),
                soon()
            ),
            Err(Failure::StaleObservation)
        );
    }
    #[test]
    fn verify_state_reads_fresh_without_issuing_tokens_or_secure_values() {
        let (mut b, _a, t, g) = wide(&[]);
        let result = b
            .execute(
                t,
                g,
                call(r#"{"action":"call","name":"verify_state","arguments":{"pid":10,"window_id":20,"text":"save"}}"#),
                soon(),
            )
            .unwrap();
        assert_eq!(result["matched"], true);
        assert_eq!(result["matches"].as_array().unwrap().len(), 1);
        assert_eq!(result["matches"][0]["title"], "Save Changes");
        assert!(b.tokens.is_empty() && b.observation.is_none());
        assert_eq!(b.desktop_owner(), Some(t));
    }
}
