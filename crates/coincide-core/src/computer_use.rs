//! Native Computer Use protocol and broker. Authority is native-UI-only, session
//! scoped and off by default. No sockets, scripts, provider commands or file IO.
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
            Self::SetValue(v) if v.text.len() > 16_384 || v.text.contains('\0') => {
                Err(Failure::InvalidRequest)
            }
            Self::ClickPoint(p)
                if !p.x.is_finite() || !p.y.is_finite() || p.x < 0.0 || p.y < 0.0 =>
            {
                Err(Failure::InvalidRequest)
            }
            _ => Ok(()),
        }
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
pub fn catalog() -> Value {
    let uuid = json!({"type":"string","format":"uuid"});
    let schema = |properties: Value, required: Value| json!({"type":"object","properties":properties,"required":required,"additionalProperties":false});
    json!({"protocol":"rust-native-v1","tokenLifetimeSeconds":15,"nativeVerified":false,"automaticInputRetry":false,"inputFailuresMayHaveActed":true,"tools":[
        {"name":"list_apps","inputSchema":schema(json!({}),json!([]))},
        {"name":"list_windows","inputSchema":schema(json!({"pid":{"type":["integer","null"],"minimum":1}}),json!([]))},
        {"name":"get_window_state","description":"Refresh invalidates earlier tokens. A screenshot is saved as a private PNG file at screenshot.path; coordinates are window points, not image pixels.","inputSchema":schema(json!({"pid":{"type":"integer","minimum":1},"window_id":{"type":"integer","minimum":1},"max_elements":{"type":"integer","minimum":1,"maximum":128,"default":64},"include_screenshot":{"type":"boolean","default":false}}),json!(["pid","window_id"]))},
        {"name":"click","description":"AX press on a fresh element token; no coordinate fallback.","inputSchema":schema(json!({"element_token":uuid.clone()}),json!(["element_token"]))},
        {"name":"set_value","inputSchema":schema(json!({"element_token":uuid.clone(),"text":{"type":"string","maxLength":16384}}),json!(["element_token","text"]))},
        {"name":"press_key","description":"Focused element in foreground app only. No arbitrary hotkeys.","inputSchema":schema(json!({"element_token":uuid,"key":{"enum":["enter","escape","tab","backspace","left","right","up","down"]}}),json!(["element_token","key"]))},
        {"name":"click_point","description":"Fresh screenshot observation required; visible foreground exact window only.","inputSchema":schema(json!({"observation":{"type":"string","format":"uuid"},"x":{"type":"number","minimum":0},"y":{"type":"number","minimum":0}}),json!(["observation","x","y"]))}
    ],"unsupported":["browser","scripts","commands","run_steps","launch_app","hotkey","drag"]})
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
    pub fn native_enable(&self, enabled: bool) {
        let mut g = self.0.lock().unwrap_or_else(|e| e.into_inner());
        g.enabled = enabled;
        g.threads.clear();
    }
    pub fn native_grant(&self, thread: Uuid) -> Result<(), Failure> {
        let mut g = self.0.lock().map_err(|_| Failure::Revoked)?;
        if !g.enabled {
            return Err(Failure::Off);
        }
        if g.threads.len() >= 32 && !g.threads.contains_key(&thread) {
            return Err(Failure::Busy);
        }
        g.threads.insert(thread, Uuid::new_v4());
        Ok(())
    }
    pub fn native_revoke(&self, thread: Uuid) {
        self.0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .threads
            .remove(&thread);
    }
    pub fn grant(&self, thread: Uuid) -> Result<Uuid, Failure> {
        let g = self.0.lock().map_err(|_| Failure::Revoked)?;
        if !g.enabled {
            return Err(Failure::Off);
        }
        g.threads.get(&thread).copied().ok_or(Failure::NotGranted)
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
    owner: Option<Uuid>,
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
        if self.observation.as_ref().is_some_and(|o| {
            self.authority.grant(o.thread) != Ok(o.grant) || Instant::now() >= o.expires
        }) {
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
    pub fn execute(
        &mut self,
        thread: Uuid,
        grant: Uuid,
        request: Request,
        deadline: Instant,
    ) -> Result<Value, Failure> {
        self.reap_revoked();
        self.valid(thread, grant, deadline)?;
        if self
            .observation
            .as_ref()
            .is_some_and(|o| Instant::now() >= o.expires)
        {
            self.invalidate();
        }
        match request {
            Request::Tools => {
                return Ok(catalog());
            }
            Request::Status => {
                return Ok(
                    json!({"enabled":true,"permissions":self.permissions,"desktopBusy":self.owner.is_some_and(|t|t!=thread),"nativeVerified":false}),
                );
            }
            Request::Release => {
                if self.owner == Some(thread) {
                    self.invalidate();
                }
                return Ok(json!({"released":true}));
            }
            _ => {}
        }
        let Request::Call(tool) = request else {
            unreachable!()
        };
        tool.validate()?;
        if self.owner.is_some_and(|t| t != thread) {
            return Err(Failure::Busy);
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
        let call = match tool {
            Tool::ListApps(_) => NativeCall::ListApps,
            Tool::ListWindows(w) => NativeCall::ListWindows(w.pid),
            Tool::GetWindowState(o) => {
                if o.include_screenshot && self.permissions.screen_capture != Permission::Granted {
                    return Err(Failure::PermissionDenied);
                }
                self.invalidate();
                self.owner = Some(thread);
                NativeCall::Observe {
                    pid: o.pid,
                    window: o.window_id,
                    limit: o.max_elements,
                    screenshot: o.include_screenshot,
                }
            }
            Tool::Click(e) => {
                let token = self.token(e.element_token, thread, grant)?;
                if token.secure {
                    return Err(Failure::PermissionDenied);
                }
                NativeCall::Press {
                    native: token.native,
                }
            }
            Tool::SetValue(v) => {
                let token = self.token(v.element_token, thread, grant)?;
                if token.secure {
                    return Err(Failure::PermissionDenied);
                }
                NativeCall::SetValue {
                    native: token.native,
                    text: v.text,
                }
            }
            Tool::PressKey(v) => {
                let token = self.token(v.element_token, thread, grant)?;
                if token.secure {
                    return Err(Failure::PermissionDenied);
                }
                NativeCall::Key {
                    native: token.native,
                    key: v.key,
                }
            }
            Tool::ClickPoint(p) => {
                let o = self
                    .observation
                    .as_ref()
                    .filter(|o| {
                        o.id == p.observation
                            && o.thread == thread
                            && o.grant == grant
                            && Instant::now() < o.expires
                            && o.screenshot
                            && p.x < o.width
                            && p.y < o.height
                    })
                    .ok_or(Failure::StaleObservation)?;
                if self.permissions.screen_capture != Permission::Granted {
                    return Err(Failure::PermissionDenied);
                }
                NativeCall::Point {
                    pid: o.pid,
                    window: o.window,
                    x: p.x,
                    y: p.y,
                }
            }
        };
        let target = match &call {
            NativeCall::Observe { pid, window, .. } => Some((*pid, *window)),
            _ => None,
        };
        let mutation = matches!(
            call,
            NativeCall::Press { .. }
                | NativeCall::SetValue { .. }
                | NativeCall::Key { .. }
                | NativeCall::Point { .. }
        );
        self.valid(thread, grant, deadline)?;
        let permit = Permit {
            authority: self.authority.clone(),
            thread,
            grant,
            deadline,
        };
        let result = self.backend.call(call, &permit);
        if result.is_err() && target.is_some() {
            self.invalidate();
        }
        // A failed/timed-out action may already have acted; tokens are consumed
        // regardless and no operation is ever automatically retried.
        if mutation {
            self.invalidate();
        }
        if let Err(error) = self.valid(thread, grant, deadline) {
            self.invalidate();
            return Err(error);
        }
        let result = result?;
        if target.is_some() && !matches!(result, NativeResult::Snapshot(_)) {
            self.invalidate();
            return Err(Failure::Native);
        }
        let value = match result {
            NativeResult::Data(value) => value,
            NativeResult::Done => json!({"dispatched":true,"verificationRequired":true}),
            NativeResult::Snapshot(snapshot) => {
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
                            pid: target.ok_or(Failure::Native)?.0,
                            window: target.ok_or(Failure::Native)?.1,
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
                    pid: target.ok_or(Failure::Native)?.0,
                    window: target.ok_or(Failure::Native)?.1,
                    width: snapshot.width,
                    height: snapshot.height,
                    screenshot: image.is_some(),
                });
                json!({"observation":observation,"elements":nodes,"screenshot":image,"coordinateSpace":"window_points","window_width":snapshot.width,"window_height":snapshot.height,"pid":target.ok_or(Failure::Native)?.0,"window_id":target.ok_or(Failure::Native)?.1})
            }
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
        Ok(value)
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
}
