//! Read-only Codex account/model observation through the existing owned child.
//! No thread/start, turn/start, login, tool or session request is sent.
use super::*;
use std::path::Path;
pub(crate) struct Snapshot {
    pub version: Option<String>,
    pub account: Value,
    pub models: Vec<Value>,
    pub models_read: bool,
}
trait Rpc {
    fn call(&mut self, method: &'static str, params: Value) -> Result<Value>;
    fn initialized(&mut self) -> Result<()>;
}
struct Wire<'a> {
    transport: CatalogTransport,
    allowed: &'a dyn Fn() -> bool,
    deadline: Instant,
    sequence: u64,
    frames: usize,
    bytes: usize,
}
impl Wire<'_> {
    fn check(&self) -> Result<()> {
        ensure!(
            (self.allowed)() && Instant::now() < self.deadline,
            "Codex account check cancelled or timed out"
        );
        Ok(())
    }
    fn write(&mut self, frame: Value) -> Result<()> {
        self.check()?;
        self.transport.write(frame)?;
        while !self.transport.flushed()? {
            self.check()?;
            std::thread::sleep(Duration::from_millis(2));
        }
        Ok(())
    }
}
impl Rpc for Wire<'_> {
    fn initialized(&mut self) -> Result<()> {
        self.write(json!({"method":"initialized"}))
    }
    fn call(&mut self, method: &'static str, params: Value) -> Result<Value> {
        ensure!(
            matches!(
                method,
                "initialize" | "account/read" | "model/list" | "skills/list"
            ),
            "Unsupported metadata request"
        );
        self.sequence += 1;
        let id = self.sequence;
        self.write(request(id, method, params))?;
        loop {
            self.check()?;
            let Some(frame) = self.transport.next()? else {
                continue;
            };
            self.frames += 1;
            self.bytes = self.bytes.saturating_add(serde_json::to_vec(&frame)?.len());
            ensure!(
                self.frames <= 256 && self.bytes <= 8 * 1024 * 1024,
                "Codex account metadata exceeded its bound"
            );
            if let Some(result) = response(&frame, id)? {
                return Ok(result);
            }
        }
    }
}
/// Read the provider's enabled skills without starting a conversation or turn.
pub(crate) fn skills(
    executable: &Path,
    cwd: &Path,
    profile: Option<&crate::codex_login_profiles::LaunchContext>,
    allowed: &impl Fn() -> bool,
) -> Result<Vec<crate::composer_suggestions::ProviderCommand>> {
    ensure!(allowed(), "Skill discovery cancelled");
    if let Some(profile) = profile {
        profile.validate()?;
    }
    let launch = Launch {
        executable: executable.into(),
        cwd: cwd.into(),
        session: None,
        prompt: String::new(),
        model: None,
        variant: None,
        full_access: false,
    };
    let args = profile.map_or_else(|| vec!["app-server".into()], |profile| profile.arguments());
    let transport = CatalogTransport::spawn(&launch, &args, &[], &[], profile)?;
    let mut wire = Wire {
        transport,
        allowed,
        deadline: Instant::now() + Duration::from_secs(30),
        sequence: 0,
        frames: 0,
        bytes: 0,
    };
    wire.call("initialize", json!({"clientInfo":{"name":"coincide","title":"Coincide","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":true}}))?;
    wire.initialized()?;
    let result = wire.call("skills/list", json!({"cwds":[cwd],"forceReload":true}))?;
    ensure!(allowed(), "Skill discovery cancelled");
    if let Some(profile) = profile {
        profile.validate()?;
    }
    let mut commands = crate::composer_suggestions::ProviderCommand::from_codex(&result, cwd);
    // App-server exposes this built-in as a session control rather than in
    // skills/list. User and plugin skills still come from the live response.
    commands.push(crate::composer_suggestions::ProviderCommand {
        name: "compact".into(),
        description: Some("Compact the current Codex conversation".into()),
        argument_hint: None,
        aliases: Vec::new(),
        kind: crate::composer_suggestions::CommandKind::Command,
        is_built_in: true,
        is_slash_command: true,
    });
    Ok(commands)
}
fn response(frame: &Value, id: u64) -> Result<Option<Value>> {
    if frame.get("method").is_some() {
        ensure!(
            frame.get("id").is_none(),
            "Codex requested an unsupported action during metadata discovery"
        );
        return Ok(None);
    }
    ensure!(
        frame["id"].as_u64() == Some(id),
        "Codex metadata response identity differs"
    );
    ensure!(
        frame.get("error").is_none(),
        "Codex refused its account or model metadata request"
    );
    frame
        .get("result")
        .filter(|result| result.is_object())
        .cloned()
        .map(Some)
        .context("Codex metadata result is invalid")
}
pub(crate) fn check(
    executable: &Path,
    profile: Option<&crate::codex_login_profiles::LaunchContext>,
    allowed: &impl Fn() -> bool,
) -> Result<Snapshot> {
    ensure!(allowed(), "Codex account check cancelled");
    let launch = Launch {
        executable: executable.into(),
        cwd: profile.map_or_else(std::env::temp_dir, |profile| profile.home().into()),
        session: None,
        prompt: String::new(),
        model: None,
        variant: None,
        full_access: false,
    };
    let args = profile.map_or_else(|| vec!["app-server".into()], |profile| profile.arguments());
    let transport = CatalogTransport::spawn(&launch, &args, &[], &[], profile)?;
    let mut wire = Wire {
        transport,
        allowed,
        deadline: Instant::now() + Duration::from_secs(30),
        sequence: 0,
        frames: 0,
        bytes: 0,
    };
    let result = observe(&mut wire, allowed);
    // Wire owns actual process/pipe cleanup through Transport::drop on every
    // return path. A result is not delivered until the child has been reaped.
    drop(wire);
    result
}
fn observe(rpc: &mut impl Rpc, allowed: &impl Fn() -> bool) -> Result<Snapshot> {
    ensure!(allowed(), "Codex account check cancelled");
    let initialize = rpc.call("initialize", json!({"clientInfo":{"name":"coincide","title":"Coincide","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":true}}))?;
    rpc.initialized()?;
    ensure!(allowed(), "Codex account check cancelled");
    let account = rpc.call("account/read", json!({}))?;
    let version = initialize["userAgent"]
        .as_str()
        .filter(|value| value.len() <= 512 && !value.chars().any(char::is_control))
        .map(str::to_owned);
    let mut result = Snapshot {
        version,
        account,
        models: Vec::new(),
        models_read: false,
    };
    if result.account["account"].is_object() || result.account["requiresOpenaiAuth"] == false {
        // Model failures do not manufacture a signed-in state or ready catalog.
        if let Ok(models) = models(rpc, allowed) {
            result.models = models;
            result.models_read = true;
        }
    }
    ensure!(allowed(), "Codex account check cancelled");
    Ok(result)
}
fn models(rpc: &mut impl Rpc, allowed: &impl Fn() -> bool) -> Result<Vec<Value>> {
    let mut models = Vec::new();
    let mut ids = std::collections::HashSet::new();
    let mut cursors = std::collections::HashSet::new();
    let mut cursor = None;
    for _ in 0..16 {
        ensure!(allowed(), "Codex account check cancelled");
        let params = cursor
            .as_ref()
            .map_or_else(|| json!({}), |cursor| json!({"cursor":cursor}));
        let page = rpc.call("model/list", params)?;
        let data = page["data"]
            .as_array()
            .context("Codex model metadata is missing")?;
        ensure!(data.len() <= 1000, "Codex model page exceeds its bound");
        for row in data {
            let id = row["id"]
                .as_str()
                .context("Codex model identity is missing")?;
            crate::composer_selection::validate_model(id)?;
            ensure!(
                models.len() < 1000,
                "Codex model metadata exceeds its bound"
            );
            if ids.insert(id.to_owned()) {
                let name = row["displayName"]
                    .as_str()
                    .filter(|name| name.len() <= 512 && !name.chars().any(char::is_control))
                    .unwrap_or(id);
                models.push(json!({"id":id,"displayName":name}));
            }
        }
        ensure!(
            page["nextCursor"].is_null() || page["nextCursor"].is_string(),
            "Codex model cursor has an invalid type"
        );
        let Some(next) = page["nextCursor"].as_str() else {
            return Ok(models);
        };
        ensure!(
            !next.is_empty() && next.len() <= 1024 && cursors.insert(next.to_owned()),
            "Codex model cursor is repeated or invalid"
        );
        cursor = Some(next.to_owned());
    }
    anyhow::bail!("Codex model metadata exceeds sixteen pages")
}
#[cfg(test)]
mod tests {
    use super::*;
    struct Fake {
        replies: std::collections::VecDeque<Value>,
        methods: Vec<&'static str>,
    }
    impl Rpc for Fake {
        fn call(&mut self, method: &'static str, _: Value) -> Result<Value> {
            self.methods.push(method);
            self.replies
                .pop_front()
                .context("Unexpected synthetic request")
        }
        fn initialized(&mut self) -> Result<()> {
            self.methods.push("initialized");
            Ok(())
        }
    }
    #[test]
    fn metadata_wire_rejects_tool_requests_wrong_ids_and_raw_error_details() {
        assert!(
            response(
                &json!({"id":1,"method":"item/tool/call","params":{"name":"synthetic"}}),
                1
            )
            .is_err()
        );
        assert!(response(&json!({"id":2,"result":{}}), 1).is_err());
        let error = response(
            &json!({"id":1,"error":{"message":"synthetic-sensitive-diagnostic"}}),
            1,
        )
        .unwrap_err();
        assert!(!error.to_string().contains("synthetic-sensitive-diagnostic"));
        assert!(
            response(&json!({"method":"account/updated","params":{}}), 1)
                .unwrap()
                .is_none()
        );
    }
    #[test]
    fn fixed_read_only_sequence_preserves_model_order_without_runtime_grants() {
        let mut fake=Fake {methods:vec![],replies:vec![json!({"userAgent":"codex_cli_rs/0.100.0"}),json!({"requiresOpenaiAuth":true,"account":{"type":"chatgpt","email":"synthetic@example.invalid"}}),json!({"data":[{"id":"model-z","displayName":"Last alphabetically","supportedReasoningEfforts":["invented"]}],"nextCursor":"page-two"}),json!({"data":[{"id":"model-a"},{"id":"model-z"}],"nextCursor":null})].into()};
        let result = observe(&mut fake, &|| true).unwrap();
        assert_eq!(
            fake.methods,
            vec![
                "initialize",
                "initialized",
                "account/read",
                "model/list",
                "model/list"
            ]
        );
        assert!(result.models_read);
        assert_eq!(
            result
                .models
                .iter()
                .map(|row| row["id"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["model-z", "model-a"]
        );
        assert!(result.models[0].get("supportedReasoningEfforts").is_none());
        assert_eq!(result.account["account"]["type"], "chatgpt");
    }
    #[test]
    fn signed_out_and_bad_catalog_never_become_ready_models() {
        let mut fake = Fake {
            methods: vec![],
            replies: vec![json!({}), json!({"requiresOpenaiAuth":true,"account":null})].into(),
        };
        let result = observe(&mut fake, &|| true).unwrap();
        assert!(!result.models_read && result.models.is_empty());
        assert!(!fake.methods.contains(&"model/list"));
        let mut fake = Fake {
            methods: vec![],
            replies: vec![
                json!({}),
                json!({"requiresOpenaiAuth":true,"account":{"type":"chatgpt"}}),
                json!({"data":[],"nextCursor":"repeat"}),
                json!({"data":[],"nextCursor":"repeat"}),
            ]
            .into(),
        };
        let result = observe(&mut fake, &|| true).unwrap();
        assert!(!result.models_read && result.models.is_empty());
        let mut fake = Fake {
            methods: vec![],
            replies: vec![].into(),
        };
        assert!(observe(&mut fake, &|| false).is_err());
        assert!(fake.methods.is_empty());
    }
}
