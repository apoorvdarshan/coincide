//! Coincide Remote's wire protocol, byte-compatible with CoincideRemoteKit's
//! `RemoteProtocol.swift`: JSON text messages over a WebSocket inside TLS whose
//! certificate the phone pins. Every message carries the version `v`; the phone
//! sends requests (`v`, `id`, `type`, `body`) and the Mac answers with
//! `response`/`error` (repeating the id as `re`) or sends `event`s on its own.
//!
//! Field names follow the Swift models exactly (`threadID`, not `threadId`),
//! dates are milliseconds since 1970 as JSON numbers, and binary data is
//! standard base64, as `RemoteProtocol.makeEncoder()` writes them.
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use uuid::Uuid;

pub const VERSION: i64 = 1;
pub const MINIMUM_VERSION: i64 = 1;
/// The Bonjour service type the Mac advertises.
pub const SERVICE_TYPE: &str = "_coincide._tcp";
/// The port the server listens on unless it's taken.
pub const DEFAULT_PORT: u16 = 47_391;
/// Largest message either side accepts, which leaves room for a few photos.
pub const MAX_MESSAGE_BYTES: usize = 32 * 1024 * 1024;

pub fn is_supported(version: i64) -> bool {
    (MINIMUM_VERSION..=VERSION).contains(&version)
}

/// Every request type `RemoteRequest.name` defines. A known type this server
/// doesn't carry out yet is answered `unsupported`, exactly as an older Mac
/// answers a newer phone, which then hides or falls back for that feature.
pub const REQUEST_TYPES: &[&str] = &[
    "hello",
    "pair",
    "ping",
    "workspace",
    "openThread",
    "closeThread",
    "loadEarlier",
    "markSeen",
    "send",
    "steerQueued",
    "removeQueued",
    "stop",
    "respond",
    "answer",
    "dismissQuestion",
    "updateSettings",
    "newThread",
    "threadAction",
    "diff",
    "runScript",
    "usageLimits",
    "presence",
    "showThread",
    "newBotConversation",
    "saveBot",
    "deleteBot",
    "settings",
    "changeSetting",
    "settingsAction",
    "settingsDocument",
    "saveSettingsDocument",
    "setProjectExpanded",
    "media",
    "completions",
    "checkout",
    "changeCheckout",
    "usageDashboard",
    "forkThread",
    "rewindOptions",
    "rewind",
    "composerNotice",
    "usageWarningAction",
    "setSidebarOptions",
    "projectDefaults",
    "saveProjectDefaults",
    "removeProject",
    "scheduledTasks",
    "saveScheduledTask",
    "scheduledTaskAction",
    "gitState",
    "gitAction",
    "pullRequests",
    "pullRequest",
    "pullRequestAction",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ErrorCode {
    Unauthorized,
    PairingFailed,
    RateLimited,
    Unsupported,
    BadRequest,
    NotFound,
    NotAllowed,
    Failed,
    Conflict,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteError {
    pub code: ErrorCode,
    pub message: String,
}
impl RemoteError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
    pub fn bad_request() -> Self {
        Self::new(ErrorCode::BadRequest, "The request couldn’t be read.")
    }
    pub fn unsupported(kind: &str) -> Self {
        Self::new(
            ErrorCode::Unsupported,
            format!("Unsupported request “{kind}”."),
        )
    }
    pub fn thread_not_found() -> Self {
        Self::new(ErrorCode::NotFound, "That thread no longer exists.")
    }
    pub fn failed(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::Failed, message)
    }
}
impl std::fmt::Display for RemoteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for RemoteError {}

// MARK: Requests

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Hello {
    #[serde(rename = "deviceID")]
    pub device_id: String,
    pub token: String,
    pub app_version: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairRequest {
    pub secret: String,
    pub device_name: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Image {
    pub name: String,
    #[serde(with = "base64_data")]
    pub data: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Delivery {
    #[default]
    Automatic,
    Alternate,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SendRequest {
    #[serde(rename = "threadID")]
    pub thread_id: Uuid,
    pub text: String,
    #[serde(default)]
    pub images: Vec<Image>,
    #[serde(default)]
    pub delivery: Delivery,
}

/// What a phone says about itself (`RemotePresence`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Presence {
    /// `active`, `inactive`, `background`, or a state a newer phone adds.
    pub state: String,
    #[serde(
        rename = "openThreadID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub open_thread_id: Option<Uuid>,
    #[serde(default)]
    pub idle_seconds: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub alert_zone: Option<String>,
}

/// Something done to a thread from its menu (`RemoteThreadAction`).
#[derive(Clone, Debug, PartialEq)]
pub enum ThreadAction {
    Rename(String),
    Pin(bool),
    Archive(bool),
    /// Milliseconds since 1970; none wakes it.
    Snooze(Option<f64>),
    Settle(bool),
    MarkUnread,
    Move(Uuid),
    Delete,
}
impl ThreadAction {
    fn decode(value: &Value) -> Result<Self, RemoteError> {
        let field = |key: &str| value.get(key).filter(|v| !v.is_null());
        let flag = |key: &str| {
            field(key)
                .and_then(Value::as_bool)
                .ok_or_else(RemoteError::bad_request)
        };
        Ok(
            match value["action"]
                .as_str()
                .ok_or_else(RemoteError::bad_request)?
            {
                "rename" => Self::Rename(
                    field("title")
                        .and_then(Value::as_str)
                        .ok_or_else(RemoteError::bad_request)?
                        .to_owned(),
                ),
                "pin" => Self::Pin(flag("value")?),
                "archive" => Self::Archive(flag("value")?),
                "snooze" => Self::Snooze(match field("date") {
                    Some(date) => Some(date.as_f64().ok_or_else(RemoteError::bad_request)?),
                    None => None,
                }),
                "settle" => Self::Settle(flag("value")?),
                "markUnread" => Self::MarkUnread,
                "move" => Self::Move(uuid(field("projectID"))?),
                "delete" => Self::Delete,
                // `RemoteProtocolError.unsupported` inside a body reads as a bad request.
                _ => return Err(RemoteError::bad_request()),
            },
        )
    }
}

/// A request this server carries out, decoded with the Swift decoder's rules.
#[derive(Clone, Debug, PartialEq)]
pub enum Request {
    Hello(Hello),
    Pair(PairRequest),
    Ping,
    Workspace {
        include_archived: bool,
    },
    OpenThread {
        thread_id: Uuid,
        limit: i64,
    },
    CloseThread {
        thread_id: Uuid,
    },
    LoadEarlier {
        thread_id: Uuid,
        before_index: i64,
        limit: i64,
    },
    MarkSeen {
        thread_id: Uuid,
    },
    Send(SendRequest),
    SteerQueued {
        thread_id: Uuid,
        message_id: Uuid,
    },
    RemoveQueued {
        thread_id: Uuid,
        message_id: Uuid,
    },
    Stop {
        thread_id: Uuid,
    },
    Respond {
        thread_id: Uuid,
        item_id: Uuid,
        option_id: String,
        text: Option<String>,
    },
    Answer {
        thread_id: Uuid,
        item_id: Uuid,
        answers: BTreeMap<String, Vec<String>>,
    },
    DismissQuestion {
        thread_id: Uuid,
        item_id: Uuid,
    },
    NewThread {
        project_id: Option<Uuid>,
    },
    ThreadAction {
        thread_id: Uuid,
        action: ThreadAction,
    },
    UsageLimits,
    Presence(Presence),
    ShowThread {
        thread_id: Uuid,
    },
    /// A request type the protocol defines that this server doesn't carry out.
    Unimplemented(String),
}

/// A phone's message, decoded.
#[derive(Clone, Debug, PartialEq)]
pub struct ClientMessage {
    pub id: String,
    pub request: Request,
}

/// Why a message couldn't be decoded, with its id when one was readable.
#[derive(Clone, Debug, PartialEq)]
pub struct DecodeFailure {
    pub id: Option<String>,
    pub error: RemoteError,
}

fn uuid(value: Option<&Value>) -> Result<Uuid, RemoteError> {
    value
        .and_then(Value::as_str)
        .and_then(|raw| Uuid::parse_str(raw).ok())
        .ok_or_else(RemoteError::bad_request)
}

fn parse<T: serde::de::DeserializeOwned>(value: &Value) -> Result<T, RemoteError> {
    serde_json::from_value(value.clone()).map_err(|_| RemoteError::bad_request())
}

fn integer(value: Option<&Value>) -> Result<Option<i64>, RemoteError> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_i64()
            .map(Some)
            .ok_or_else(RemoteError::bad_request),
    }
}

impl ClientMessage {
    /// Decodes one message as `RemoteClientMessage.init(from:)` does: version
    /// first, then the type, then its body. Unknown types are `unsupported`.
    pub fn decode(data: &[u8]) -> Result<Self, DecodeFailure> {
        let value: Value = serde_json::from_slice(data).map_err(|_| DecodeFailure {
            id: None,
            error: RemoteError::bad_request(),
        })?;
        let id = value["id"].as_str().map(str::to_owned);
        let fail = |error| DecodeFailure {
            id: id.clone(),
            error,
        };
        let version = value["v"]
            .as_i64()
            .ok_or_else(|| fail(RemoteError::bad_request()))?;
        let message_id = id.clone().ok_or_else(|| fail(RemoteError::bad_request()))?;
        if !is_supported(version) {
            return Err(fail(RemoteError::new(
                ErrorCode::Unsupported,
                format!("Unsupported protocol version {version}."),
            )));
        }
        let kind = value["type"]
            .as_str()
            .ok_or_else(|| fail(RemoteError::bad_request()))?;
        let request = Self::request(kind, value.get("body")).map_err(fail)?;
        Ok(Self {
            id: message_id,
            request,
        })
    }

    fn request(kind: &str, body: Option<&Value>) -> Result<Request, RemoteError> {
        // Typed bodies must be present; flattened field bodies may be absent.
        let typed = || -> Result<&Value, RemoteError> {
            body.filter(|b| b.is_object())
                .ok_or_else(RemoteError::bad_request)
        };
        let empty = json!({});
        let fields = match body {
            None | Some(Value::Null) => &empty,
            Some(object @ Value::Object(_)) => object,
            Some(_) => return Err(RemoteError::bad_request()),
        };
        let thread = || uuid(fields.get("threadID"));
        let item = || uuid(fields.get("itemID"));
        Ok(match kind {
            "hello" => Request::Hello(parse(typed()?)?),
            "pair" => Request::Pair(parse(typed()?)?),
            "ping" => Request::Ping,
            "workspace" => Request::Workspace {
                include_archived: match fields.get("includeArchived") {
                    None | Some(Value::Null) => false,
                    Some(value) => value.as_bool().ok_or_else(RemoteError::bad_request)?,
                },
            },
            "openThread" => Request::OpenThread {
                thread_id: thread()?,
                limit: integer(fields.get("limit"))?.unwrap_or(200),
            },
            "closeThread" => Request::CloseThread {
                thread_id: thread()?,
            },
            "loadEarlier" => Request::LoadEarlier {
                thread_id: thread()?,
                before_index: integer(fields.get("beforeIndex"))?
                    .ok_or_else(RemoteError::bad_request)?,
                limit: integer(fields.get("limit"))?.unwrap_or(200),
            },
            "markSeen" => Request::MarkSeen {
                thread_id: thread()?,
            },
            "send" => Request::Send(parse(typed()?)?),
            "steerQueued" | "removeQueued" => {
                let thread_id = thread()?;
                let message_id = uuid(fields.get("messageID"))?;
                if kind == "steerQueued" {
                    Request::SteerQueued {
                        thread_id,
                        message_id,
                    }
                } else {
                    Request::RemoveQueued {
                        thread_id,
                        message_id,
                    }
                }
            }
            "stop" => Request::Stop {
                thread_id: thread()?,
            },
            "respond" => Request::Respond {
                thread_id: thread()?,
                item_id: item()?,
                option_id: fields["optionID"]
                    .as_str()
                    .ok_or_else(RemoteError::bad_request)?
                    .to_owned(),
                text: match fields.get("text") {
                    None | Some(Value::Null) => None,
                    Some(text) => Some(
                        text.as_str()
                            .ok_or_else(RemoteError::bad_request)?
                            .to_owned(),
                    ),
                },
            },
            "answer" => Request::Answer {
                thread_id: thread()?,
                item_id: item()?,
                answers: parse(fields.get("answers").ok_or_else(RemoteError::bad_request)?)?,
            },
            "dismissQuestion" => Request::DismissQuestion {
                thread_id: thread()?,
                item_id: item()?,
            },
            "newThread" => Request::NewThread {
                project_id: match fields.get("projectID") {
                    None | Some(Value::Null) => None,
                    some => Some(uuid(some)?),
                },
            },
            "threadAction" => Request::ThreadAction {
                thread_id: thread()?,
                action: ThreadAction::decode(
                    fields
                        .get("action")
                        .filter(|a| a.is_object())
                        .ok_or_else(RemoteError::bad_request)?,
                )?,
            },
            "usageLimits" => Request::UsageLimits,
            "presence" => Request::Presence(parse(typed()?)?),
            "showThread" => Request::ShowThread {
                thread_id: thread()?,
            },
            other if REQUEST_TYPES.contains(&other) => Request::Unimplemented(other.to_owned()),
            other => return Err(RemoteError::unsupported(other)),
        })
    }
}

// MARK: Server messages

/// `{"v":1,"kind":"response","re":id,"type":kind,"body":…}`; `ok` has no body.
pub fn response(id: &str, kind: &str, body: Option<Value>) -> Value {
    let mut message = json!({"v":VERSION,"kind":"response","re":id,"type":kind});
    if let Some(body) = body {
        message["body"] = body;
    }
    message
}

/// `{"v":1,"kind":"error","re":id,"error":{code,message}}`; `re` only when the id was readable.
pub fn failure(id: Option<&str>, error: &RemoteError) -> Value {
    let mut message = json!({"v":VERSION,"kind":"error","error":error});
    if let Some(id) = id {
        message["re"] = json!(id);
    }
    message
}

/// `{"v":1,"kind":"event","type":kind,"body":…}`; `revoked` has no body.
pub fn event(kind: &str, body: Option<Value>) -> Value {
    let mut message = json!({"v":VERSION,"kind":"event","type":kind});
    if let Some(body) = body {
        message["body"] = body;
    }
    message
}

/// A `{"value": …}` body, as `delivery`, `thread`, `usage`, `threadRemoved` and
/// `clearNotifications` carry theirs.
pub fn value_body(value: impl Serialize) -> Value {
    json!({ "value": value })
}

// MARK: Models

/// The Mac the phone talks to (`RemoteServerInfo`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerInfo {
    #[serde(rename = "serverID")]
    pub server_id: String,
    pub name: String,
    pub app_version: String,
    pub protocol_version: i64,
    pub theme: ThemeInfo,
    pub shows_reasoning: bool,
    pub follow_up_behavior: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notifies: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_typeface: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_message_side: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThemeInfo {
    pub appearance: String,
    #[serde(rename = "darkThemeID")]
    pub dark_theme_id: String,
    #[serde(rename = "lightThemeID")]
    pub light_theme_id: String,
}
impl Default for ThemeInfo {
    fn default() -> Self {
        Self {
            appearance: "system".into(),
            dark_theme_id: "carbon".into(),
            light_theme_id: "carbon-light".into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairResult {
    #[serde(rename = "deviceID")]
    pub device_id: String,
    pub token: String,
    pub server: ServerInfo,
}

/// A phone allowed to connect, as Settings lists it (`RemoteDevice`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Device {
    pub id: String,
    pub name: String,
    /// Milliseconds since 1970.
    pub paired_at: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_seen_at: Option<f64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HostKind {
    /// An IP address on the local network.
    Lan,
    /// The computer's `.local` name.
    LocalName,
    Manual,
    /// A Tailscale address (100.64.0.0/10 or fd7a:115c:a1e0::/48).
    Tailscale,
    /// A Tailscale MagicDNS name.
    TailscaleName,
}

/// Where to reach the computer, as the pairing code lists it.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct HostCandidate {
    pub host: String,
    pub kind: HostKind,
}

/// What the pairing QR code holds (`RemotePairingPayload`): how to reach the
/// computer, the certificate fingerprint to pin and a one-time secret.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PairingPayload {
    /// Seconds since 1970, as the Swift payload encodes its dates.
    #[serde(rename = "e")]
    pub expires_at: f64,
    /// SHA-256 of the certificate (DER), lowercase hex.
    #[serde(rename = "f")]
    pub fingerprint: String,
    #[serde(rename = "h")]
    pub hosts: Vec<HostCandidate>,
    #[serde(rename = "id")]
    pub server_id: String,
    #[serde(rename = "n")]
    pub name: String,
    #[serde(rename = "p")]
    pub port: u16,
    #[serde(rename = "s")]
    pub secret: String,
    #[serde(rename = "v")]
    pub version: i64,
}
impl PairingPayload {
    pub const SCHEME: &'static str = "coincide-remote";

    /// `coincide-remote:pair#<base64url JSON>`, keys sorted as Swift's
    /// `.sortedKeys` writes them (the fields above are declared in that order).
    pub fn encoded(&self) -> String {
        let json = serde_json::to_vec(self).unwrap_or_default();
        format!("{}:pair#{}", Self::SCHEME, super::crypto::base64_url(&json))
    }

    /// Reads a code back, with `RemotePairingPayload.decode`'s checks.
    pub fn decode(string: &str) -> Option<Self> {
        let prefix = format!("{}:pair#", Self::SCHEME);
        let data = super::crypto::from_base64_url(string.trim().strip_prefix(&prefix)?)?;
        let payload: Self = serde_json::from_slice(&data).ok()?;
        (payload.version >= 1 && !payload.secret.is_empty() && payload.fingerprint.len() == 64)
            .then_some(payload)
    }
}

/// Everything the sidebar shows (`RemoteWorkspace`).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Workspace {
    pub projects: Vec<Project>,
    pub threads: Vec<ThreadSummary>,
    pub providers: Vec<Provider>,
    pub sections: Vec<String>,
    pub pinned_order: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    pub id: String,
    pub name: String,
    pub path: String,
    pub is_chats: bool,
    pub scripts: Vec<Script>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_expanded: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Script {
    pub id: String,
    pub name: String,
    pub command: String,
    pub icon: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Provider {
    pub id: String,
    pub name: String,
    pub state: String,
    pub accounts: Vec<Account>,
    pub models: Vec<Model>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub id: String,
    pub name: String,
    pub is_ready: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Model {
    pub id: String,
    pub name: String,
    pub efforts: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_effort: Option<String>,
    pub speeds: Vec<Speed>,
    pub supports_images: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Speed {
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Selection {
    pub provider: String,
    #[serde(rename = "modelID")]
    pub model_id: String,
    pub model_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speed: Option<String>,
    #[serde(rename = "accountID", skip_serializing_if = "Option::is_none")]
    pub account_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account_name: Option<String>,
}

/// A thread as the sidebar lists it (`RemoteThreadSummary`).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadSummary {
    pub id: String,
    #[serde(rename = "projectID")]
    pub project_id: String,
    pub title: String,
    pub created_at: f64,
    pub updated_at: f64,
    pub selection: Selection,
    pub access_mode: String,
    pub interaction_mode: String,
    pub is_pinned: bool,
    pub is_archived: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub snoozed_until: Option<f64>,
    pub is_settled: bool,
    pub is_hidden: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    pub has_worktree: bool,
    pub is_running: bool,
    pub is_starting: bool,
    pub pending_approvals: usize,
    pub pending_questions: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unseen: Option<String>,
    pub queued_messages: usize,
    pub has_draft: bool,
    pub item_count: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub running_since: Option<f64>,
}

/// One transcript entry (`RemoteItem`).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    pub index: usize,
    pub kind: String,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(rename = "modelID", skip_serializing_if = "Option::is_none")]
    pub model_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub approval: Option<Approval>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub questions: Option<QuestionSet>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub answers: Option<BTreeMap<String, Vec<String>>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attachments: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context: Option<Vec<String>>,
    pub steered: bool,
    pub is_clipped: bool,
    pub created_at: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub schedule_name: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Approval {
    pub options: Vec<ApprovalOption>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolution: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text_placeholder: Option<String>,
    pub accepts_text: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub response_text: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ApprovalOption {
    pub id: String,
    pub label: String,
    /// `allowOnce`, `allowAlways`, `deny` or `cancel`.
    pub kind: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct QuestionSet {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub questions: Vec<Question>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Question {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub header: Option<String>,
    pub prompt: String,
    pub options: Vec<QuestionOption>,
    pub allows_multiple_selection: bool,
    pub allows_free_text: bool,
    pub is_secret: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct QuestionOption {
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnState {
    pub is_running: bool,
    pub is_starting: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    pub can_steer: bool,
    pub queued: Vec<QueuedMessage>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueuedMessage {
    pub id: String,
    pub text: String,
    pub image_count: usize,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Transcript {
    pub thread: ThreadSummary,
    pub items: Vec<Item>,
    pub has_earlier: bool,
    pub turn: TurnState,
    /// Files each finished turn changed, by the item that opened the turn.
    pub turn_changes: BTreeMap<String, Vec<Value>>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ItemPage {
    pub items: Vec<Item>,
    pub has_earlier: bool,
}

mod base64_data {
    use super::*;
    pub fn serialize<S: serde::Serializer>(data: &[u8], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&base64::engine::general_purpose::STANDARD.encode(data))
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let raw = String::deserialize(d)?;
        base64::engine::general_purpose::STANDARD
            .decode(raw)
            .map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(value: Value) -> Result<ClientMessage, DecodeFailure> {
        ClientMessage::decode(&serde_json::to_vec(&value).unwrap())
    }

    #[test]
    fn decodes_requests_as_the_swift_decoder_does() {
        let thread = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F";
        let message =
            decode(json!({"v":1,"id":"a","type":"openThread","body":{"threadID":thread}})).unwrap();
        assert_eq!(message.id, "a");
        assert_eq!(
            message.request,
            Request::OpenThread {
                thread_id: Uuid::parse_str(thread).unwrap(),
                limit: 200
            }
        );
        assert_eq!(
            decode(json!({"v":1,"id":"b","type":"workspace"}))
                .unwrap()
                .request,
            Request::Workspace {
                include_archived: false
            }
        );
        let hello = decode(json!({"v":1,"id":"c","type":"hello","body":{"deviceID":"D","token":"T","appVersion":"1.0"}})).unwrap();
        assert!(
            matches!(hello.request, Request::Hello(Hello { ref device_id, .. }) if device_id == "D")
        );
        let action = decode(json!({"v":1,"id":"d","type":"threadAction","body":{"threadID":thread,"action":{"action":"snooze"}}})).unwrap();
        assert!(matches!(
            action.request,
            Request::ThreadAction {
                action: ThreadAction::Snooze(None),
                ..
            }
        ));
        let send = decode(json!({"v":1,"id":"e","type":"send","body":{"threadID":thread,"text":"hi","images":[{"name":"a.png","data":"aGk="}],"delivery":"alternate"}})).unwrap();
        let Request::Send(send) = send.request else {
            panic!("send")
        };
        assert_eq!(send.images[0].data, b"hi");
        assert_eq!(send.delivery, Delivery::Alternate);
    }

    #[test]
    fn failures_match_swift_messages_and_keep_readable_ids() {
        let unknown = decode(json!({"v":1,"id":"x","type":"teleport"})).unwrap_err();
        assert_eq!(unknown.id.as_deref(), Some("x"));
        assert_eq!(unknown.error, RemoteError::unsupported("teleport"));
        assert_eq!(unknown.error.message, "Unsupported request “teleport”.");
        let version = decode(json!({"v":2,"id":"y","type":"ping"})).unwrap_err();
        assert_eq!(version.error.message, "Unsupported protocol version 2.");
        assert_eq!(version.error.code, ErrorCode::Unsupported);
        let missing = decode(json!({"v":1,"id":"z","type":"openThread","body":{}})).unwrap_err();
        assert_eq!(missing.error, RemoteError::bad_request());
        let garbage = ClientMessage::decode(b"not json").unwrap_err();
        assert_eq!(garbage.id, None);
        let no_version = decode(json!({"id":"q","type":"ping"})).unwrap_err();
        assert_eq!(no_version.id.as_deref(), Some("q"));
        assert_eq!(no_version.error.code, ErrorCode::BadRequest);
        // Known types this server doesn't carry out decode, for an `unsupported` answer.
        assert_eq!(
            decode(json!({"v":1,"id":"s","type":"settings"}))
                .unwrap()
                .request,
            Request::Unimplemented("settings".into())
        );
    }

    #[test]
    fn server_messages_have_the_swift_envelope() {
        assert_eq!(
            response("1", "ok", None),
            json!({"v":1,"kind":"response","re":"1","type":"ok"})
        );
        assert_eq!(
            failure(None, &RemoteError::new(ErrorCode::RateLimited, "m")),
            json!({"v":1,"kind":"error","error":{"code":"rateLimited","message":"m"}})
        );
        assert_eq!(
            event("threadRemoved", Some(value_body("T"))),
            json!({"v":1,"kind":"event","type":"threadRemoved","body":{"value":"T"}})
        );
        assert_eq!(
            serde_json::to_value(ErrorCode::PairingFailed).unwrap(),
            json!("pairingFailed")
        );
    }

    #[test]
    fn pairing_payload_round_trips_with_sorted_short_keys() {
        let payload = PairingPayload {
            expires_at: 1_730_000_000.5,
            fingerprint: "ab".repeat(32),
            hosts: vec![HostCandidate {
                host: "192.168.1.2".into(),
                kind: HostKind::Lan,
            }],
            server_id: "S".into(),
            name: "Desk".into(),
            port: DEFAULT_PORT,
            secret: "secret".into(),
            version: 1,
        };
        let encoded = payload.encoded();
        assert!(encoded.starts_with("coincide-remote:pair#"));
        assert!(!encoded.contains('=') && !encoded.contains('+') && !encoded.contains('/'));
        let json =
            super::super::crypto::from_base64_url(encoded.split('#').nth(1).unwrap()).unwrap();
        let text = String::from_utf8(json).unwrap();
        let keys = [
            "\"e\"", "\"f\"", "\"h\"", "\"id\"", "\"n\"", "\"p\"", "\"s\"", "\"v\"",
        ];
        let positions = keys.map(|key| text.find(key).unwrap());
        assert!(positions.windows(2).all(|pair| pair[0] < pair[1]), "{text}");
        assert_eq!(
            PairingPayload::decode(&format!("  {encoded}\n")),
            Some(payload.clone())
        );
        assert_eq!(PairingPayload::decode("coincide-remote:pair#e30"), None);
        let mut short = payload;
        short.fingerprint = "ab".into();
        assert_eq!(PairingPayload::decode(&short.encoded()), None);
    }
}
