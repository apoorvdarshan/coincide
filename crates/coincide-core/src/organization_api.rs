//! Bounded bot editing in the Rust Store overlay. Captured bots.json originals
//! and instruction files are never written; bot persona is the only editable
//! instruction source here. Runtime bot activation is not connected by this API.
use super::*;
use crate::organization::{DOCUMENT_LIMIT, RECORD_LIMIT};
use sha2::{Digest, Sha256};

pub(super) const METHODS: &[&str] = &["bots.list", "bots.read", "bots.save", "bots.patch"];
const DOCUMENT: &str = "bots.json";
struct Snapshot {
    source: Option<Value>,
    document: Value,
    baseline: String,
    origin: &'static str,
}
fn validate(document: &Value) -> Result<Vec<u8>> {
    ensure!(
        document.is_object(),
        "Bots document must be an object envelope"
    );
    let bots = document["bots"]
        .as_array()
        .context("Bots envelope is missing its bots array")?;
    ensure!(bots.len() <= RECORD_LIMIT, "Too many bots");
    let mut ids = HashSet::new();
    for bot in bots {
        ensure!(bot.is_object(), "Bot must be an object");
        let id = Uuid::parse_str(required(bot, "id")?).context("Invalid bot UUID")?;
        ensure!(ids.insert(id), "Duplicate bot UUID");
    }
    let bytes = serde_json::to_vec(document)?;
    ensure!(
        bytes.len() <= DOCUMENT_LIMIT,
        "Bots document exceeds size limit"
    );
    Ok(bytes)
}
fn load(store: &Store) -> Result<Snapshot> {
    let local = store.local_document(DOCUMENT)?;
    let (source, origin) = if let Some(local) = local {
        (Some(local), "local")
    } else if let Some(bytes) = store.original(DOCUMENT)? {
        ensure!(
            bytes.len() <= DOCUMENT_LIMIT,
            "Bots document exceeds size limit"
        );
        (
            Some(serde_json::from_slice(&bytes).context("Captured bots document is invalid")?),
            "imported",
        )
    } else {
        (None, "empty")
    };
    let document = source
        .clone()
        .unwrap_or(json!({"addedStarters":false,"bots":[],"starterLineup":1}));
    let baseline = crate::digest_hex::lower_hex(Sha256::digest(validate(&document)?));
    Ok(Snapshot {
        source,
        document,
        baseline,
        origin,
    })
}
fn response(snapshot: &Snapshot, bot: Option<&Value>) -> Value {
    let mut result = json!({"baseline":snapshot.baseline,"origin":snapshot.origin,"instructionsScope":"bot-local","executionConnected":false});
    if let Some(bot) = bot {
        result["bot"] = bot.clone();
    } else {
        result["bots"] = snapshot.document["bots"].clone();
    }
    result
}
fn id(params: &Value) -> Result<Uuid> {
    Uuid::parse_str(required(params, "botId")?).context("Invalid bot UUID")
}
fn index(document: &Value, id: Uuid) -> Result<usize> {
    document["bots"]
        .as_array()
        .context("Invalid bots envelope")?
        .iter()
        .position(|bot| bot["id"].as_str().and_then(|id| Uuid::parse_str(id).ok()) == Some(id))
        .context("Bot not found")
}
fn patch(value: &Value) -> Result<serde_json::Map<String, Value>> {
    let patch = value.as_object().context("Bot patch must be an object")?;
    ensure!(
        !patch.is_empty()
            && patch
                .keys()
                .all(|key| matches!(key.as_str(), "name" | "persona")),
        "Only bot name and persona can be edited"
    );
    let mut validated = patch.clone();
    if let Some(name) = patch.get("name") {
        let name = name.as_str().context("Bot name must be text")?.trim();
        ensure!(
            !name.is_empty() && name.chars().count() <= 200 && !name.chars().any(char::is_control),
            "Bot name must contain 1–200 characters without control characters"
        );
        validated.insert("name".into(), json!(name));
    }
    if let Some(persona) = patch.get("persona") {
        let persona = persona.as_str().context("Bot instructions must be text")?;
        ensure!(
            persona.chars().count() <= 20_000 && !persona.contains('\0'),
            "Bot instructions must contain at most 20,000 characters and no NUL"
        );
    }
    Ok(validated)
}
impl Engine {
    pub(super) fn organization_command(&mut self, method: &str, params: &Value) -> Result<Value> {
        ensure!(METHODS.contains(&method), "Unknown bot method");
        let object = params.as_object().context("Bot params must be an object")?;
        let allowed: &[&str] = match method {
            "bots.list" => &[],
            "bots.read" => &["botId"],
            _ => &["botId", "baseline", "patch"],
        };
        ensure!(
            object.keys().all(|key| allowed.contains(&key.as_str())),
            "Unknown bot parameter"
        );
        let mut snapshot = load(&self.store)?;
        if method == "bots.list" {
            return Ok(response(&snapshot, None));
        }
        if method == "bots.read" {
            let index = index(&snapshot.document, id(params)?)?;
            return Ok(response(&snapshot, Some(&snapshot.document["bots"][index])));
        }
        let baseline = required(params, "baseline")?;
        ensure!(
            baseline.len() == 64 && baseline.bytes().all(|byte| byte.is_ascii_hexdigit()),
            "Invalid bot baseline"
        );
        ensure!(
            baseline == snapshot.baseline,
            "Bot document changed; reload before saving"
        );
        let patch = patch(&params["patch"])?;
        let position = if object.contains_key("botId") || method == "bots.patch" {
            index(&snapshot.document, id(params)?)?
        } else {
            ensure!(patch.contains_key("name"), "A new bot needs a name");
            let bots = snapshot.document["bots"].as_array_mut().unwrap();
            ensure!(bots.len() < RECORD_LIMIT, "Too many bots");
            bots.push(json!({"id":Uuid::new_v4().to_string().to_uppercase(),"name":"Bot","persona":"",
                "selection":{"provider":"codex","modelID":"default"},"accessMode":"approval","interactionMode":"build","createdAt":swift_timestamp()}));
            bots.len() - 1
        };
        let bot = snapshot.document["bots"][position].as_object_mut().unwrap();
        for (key, value) in patch {
            bot.insert(key, value);
        }
        let baseline = crate::digest_hex::lower_hex(Sha256::digest(validate(&snapshot.document)?));
        // Store repeats the comparison inside an IMMEDIATE transaction, covering
        // another Store/Engine connection changing the document after this read.
        self.store
            .save_bots_document_if_unchanged(snapshot.source.as_ref(), &snapshot.document)?;
        self.revision += 1;
        snapshot.baseline = baseline;
        snapshot.origin = "local";
        Ok(response(
            &snapshot,
            Some(&snapshot.document["bots"][position]),
        ))
    }
}

#[cfg(test)]
#[path = "organization_api_tests.rs"]
mod tests;

/// Native drag reorder changes only the order of the validated bot envelope.
/// It never edits bot records or grants runtime/provider authority.
impl Engine {
    pub fn reorder_native_bots(&mut self, ids: &[String], baseline: &str) -> Result<Value> {
        self.require_admissions()?;
        let mut snapshot = load(&self.store)?;
        ensure!(
            snapshot.baseline == baseline,
            "Bots changed; refresh before reordering"
        );
        let bots = snapshot.document["bots"]
            .as_array()
            .context("Invalid bot list")?;
        ensure!(
            ids.len() == bots.len() && ids.len() <= RECORD_LIMIT,
            "Bot order must include every saved bot"
        );
        let mut seen = HashSet::new();
        let mut ordered = Vec::with_capacity(ids.len());
        for id in ids {
            let identity = Uuid::parse_str(id)?;
            ensure!(seen.insert(identity), "Duplicate bot in reorder");
            let bot = bots
                .iter()
                .find(|bot| {
                    bot["id"].as_str().and_then(|id| Uuid::parse_str(id).ok()) == Some(identity)
                })
                .context("Reorder contains an unknown bot")?;
            ordered.push(bot.clone());
        }
        snapshot.document["bots"] = json!(ordered);
        validate(&snapshot.document)?;
        self.store
            .save_bots_document_if_unchanged(snapshot.source.as_ref(), &snapshot.document)?;
        self.revision += 1;
        let saved = load(&self.store)?;
        Ok(response(&saved, None))
    }
}
