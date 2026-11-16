//! Lithos is a model service for OpenCode, not a separate coding agent.
//! Only the selected native key account can authorize its discovery.
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    ffi::OsStr,
    io::Read,
    process::Command,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

const MODELS_URL: &str = "https://api.lithosai.cloud/v1/models";
const MAX_RESPONSE: u64 = 2 * 1024 * 1024;
type Cache = HashMap<[u8; 32], (Instant, Vec<String>)>;
static MODELS: OnceLock<Mutex<Cache>> = OnceLock::new();
type LocalModel = (String, Option<u64>);
type LocalCache = Option<(Instant, Vec<LocalModel>)>;
static LOCAL_MODELS: OnceLock<Mutex<LocalCache>> = OnceLock::new();

fn parse_models(data: &[u8]) -> Result<Vec<String>> {
    ensure!(
        data.len() as u64 <= MAX_RESPONSE,
        "Lithos model list is too large"
    );
    let value: Value = serde_json::from_slice(data).context("Lithos model list is invalid")?;
    let rows = value["data"]
        .as_array()
        .context("Lithos model list is missing")?;
    ensure!(rows.len() <= 4000, "Lithos model list is too large");
    let mut result = Vec::new();
    for id in rows.iter().filter_map(|row| row["id"].as_str()) {
        if crate::composer_selection::validate_model(id).is_ok()
            && !id.chars().any(char::is_whitespace)
            && !result.iter().any(|existing| existing == id)
        {
            result.push(id.to_owned());
            if result.len() == 1000 {
                break;
            }
        }
    }
    Ok(result)
}
fn fetch_models(endpoint: &str, key: &str) -> Result<Vec<String>> {
    let agent = ureq::Agent::config_builder()
        .proxy(None)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_secs(8)))
        .build()
        .new_agent();
    let mut response = agent
        .get(endpoint)
        .header("Authorization", format!("Bearer {key}"))
        .header("Accept", "application/json")
        .call()
        .map_err(|_| anyhow::anyhow!("Lithos model list is unavailable"))?;
    let mut bytes = Vec::new();
    response
        .body_mut()
        .as_reader()
        .take(MAX_RESPONSE + 1)
        .read_to_end(&mut bytes)?;
    parse_models(&bytes)
}
fn cached_models_with(
    key: &str,
    refresh: bool,
    fetch: impl FnOnce() -> Result<Vec<String>>,
) -> Result<Vec<String>> {
    let digest: [u8; 32] = Sha256::digest(key.as_bytes()).into();
    let cache = MODELS.get_or_init(|| Mutex::new(HashMap::new()));
    let previous = cache
        .lock()
        .ok()
        .and_then(|guard| guard.get(&digest).cloned());
    if let Some((when, rows)) = &previous
        && (!refresh || when.elapsed() < Duration::from_secs(300))
    {
        return Ok(rows.clone());
    }
    let models = match fetch() {
        Ok(models) => models,
        Err(_) if previous.is_some() => return Ok(previous.unwrap().1),
        Err(error) => return Err(error),
    };
    if let Ok(mut guard) = cache.lock() {
        if guard.len() >= 64 {
            guard.clear();
        }
        guard.insert(digest, (Instant::now(), models.clone()));
    }
    Ok(models)
}
fn cached_models(key: &str, refresh: bool) -> Result<Vec<String>> {
    cached_models_with(key, refresh, || fetch_models(MODELS_URL, key))
}

fn overlay(existing: Option<&OsStr>, models: &[String]) -> Result<String> {
    let mut config = match existing {
        Some(value) => {
            serde_json::from_str::<Value>(value.to_str().context("OpenCode config is not text")?)
                .context("OpenCode inline config is invalid")?
        }
        None => json!({}),
    };
    ensure!(config.is_object(), "OpenCode inline config is invalid");
    let providers = config
        .as_object_mut()
        .unwrap()
        .entry("providers")
        .or_insert_with(|| json!({}));
    let providers = providers
        .as_object_mut()
        .context("OpenCode inline providers are invalid")?;
    ensure!(
        !providers.contains_key("coincide-lithos"),
        "OpenCode inline config already uses coincide-lithos"
    );
    let rows = models
        .iter()
        .map(|id| {
            (
                id.clone(),
                json!({"name":id,"capabilities":{"input":["text"],"output":["text"]}}),
            )
        })
        .collect::<serde_json::Map<_, _>>();
    providers.insert(
        "coincide-lithos".into(),
        json!({"name":"Lithos AI","env":["LITHOSAI_API_KEY"],
        "package":"@opencode/ai/providers/openai-compatible",
        "settings":{"baseURL":"https://api.lithosai.cloud/v1"},"models":rows}),
    );
    Ok(serde_json::to_string(&config)?)
}
pub(super) fn configure(command: &mut Command, key: &OsStr, refresh: bool) -> Result<()> {
    let key = key.to_str().context("Lithos API key is not text")?;
    ensure!(
        !key.is_empty() && !key.chars().any(char::is_control),
        "Lithos API key is invalid"
    );
    let rows = cached_models(key, refresh)?;
    let existing = command
        .get_envs()
        .find(|(name, _)| *name == "OPENCODE_CONFIG_CONTENT")
        .and_then(|(_, value)| value)
        .map(OsStr::to_owned);
    command.env(
        "OPENCODE_CONFIG_CONTENT",
        overlay(existing.as_deref(), &rows)?,
    );
    Ok(())
}

fn parse_local_models(bytes: &[u8]) -> Result<Vec<LocalModel>> {
    ensure!(
        bytes.len() as u64 <= MAX_RESPONSE,
        "Local model list is too large"
    );
    let data: Value = serde_json::from_slice(bytes)?;
    let rows = data["data"]
        .as_array()
        .context("Local model list is missing")?;
    ensure!(rows.len() <= 4000, "Local model list is too large");
    let mut found = Vec::new();
    for row in rows {
        if row["owned_by"] != "lithos-metal" {
            continue;
        }
        let Some(id) = row["id"].as_str() else {
            continue;
        };
        if crate::composer_selection::validate_model(id).is_err()
            || id.chars().any(char::is_whitespace)
            || found.iter().any(|(existing, _)| existing == id)
        {
            continue;
        }
        let limit = row["context_window"]
            .as_u64()
            .filter(|limit| *limit > 0 && *limit <= 1_000_000_000);
        found.push((id.to_owned(), limit));
        if found.len() == 1000 {
            break;
        }
    }
    Ok(found)
}
fn fetch_local_models(endpoint: &str) -> Result<Vec<LocalModel>> {
    let agent = ureq::Agent::config_builder()
        .proxy(None)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_millis(500)))
        .build()
        .new_agent();
    let mut response = agent
        .get(endpoint)
        .header("Accept", "application/json")
        .call()?;
    let mut bytes = Vec::new();
    response
        .body_mut()
        .as_reader()
        .take(MAX_RESPONSE + 1)
        .read_to_end(&mut bytes)?;
    parse_local_models(&bytes)
}
fn cached_local_models() -> Vec<LocalModel> {
    let cache = LOCAL_MODELS.get_or_init(|| Mutex::new(None));
    let previous = cache.lock().ok().and_then(|guard| guard.clone());
    if let Some((when, rows)) = &previous
        && when.elapsed() < Duration::from_secs(15)
    {
        return rows.clone();
    }
    let rows = fetch_local_models("http://127.0.0.1:8000/v1/models")
        .unwrap_or_else(|_| previous.map(|(_, rows)| rows).unwrap_or_default());
    if let Ok(mut guard) = cache.lock() {
        *guard = Some((Instant::now(), rows.clone()));
    }
    rows
}
fn local_overlay(existing: Option<&OsStr>, models: &[LocalModel]) -> Result<String> {
    let mut config = match existing {
        Some(value) => {
            serde_json::from_str::<Value>(value.to_str().context("OpenCode config is not text")?)?
        }
        None => json!({}),
    };
    let root = config
        .as_object_mut()
        .context("OpenCode inline config is invalid")?;
    let providers = root
        .entry("providers")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .context("OpenCode inline providers are invalid")?;
    ensure!(
        !providers.contains_key("coincide-lithos-local"),
        "OpenCode inline config already uses coincide-lithos-local"
    );
    let rows = models
        .iter()
        .map(|(id, context)| {
            let mut model =
                json!({"name":id,"capabilities":{"tools":true,"input":["text"],"output":["text"]}});
            if let Some(context) = context {
                model["limit"] = json!({"context":context});
            }
            (id.clone(), model)
        })
        .collect::<serde_json::Map<_, _>>();
    providers.insert(
        "coincide-lithos-local".into(),
        json!({"name":"Lithos Local",
        "package":"@opencode/ai/providers/openai-compatible",
        "settings":{"baseURL":"http://127.0.0.1:8000/v1"},"models":rows}),
    );
    Ok(serde_json::to_string(&config)?)
}
pub(super) fn configure_local(command: &mut Command) -> Result<()> {
    let models = cached_local_models();
    if models.is_empty() {
        return Ok(());
    }
    let explicit = command
        .get_envs()
        .find(|(name, _)| *name == "OPENCODE_CONFIG_CONTENT")
        .map(|(_, value)| value.map(OsStr::to_owned));
    // A named account clears the parent environment. Do not reintroduce an
    // inline configuration belonging to a different account.
    let existing = explicit.unwrap_or_else(|| {
        if crate::provider_configuration::native_account_profile("opencode") {
            None
        } else {
            std::env::var_os("OPENCODE_CONFIG_CONTENT")
        }
    });
    command.env(
        "OPENCODE_CONFIG_CONTENT",
        local_overlay(existing.as_deref(), &models)?,
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn discovered_models_are_validated_and_existing_config_is_preserved() {
        let rows = parse_models(br#"{"data":[{"id":"deepseek/flash"},{"id":"deepseek/flash"},{"id":"bad name"},{"id":"future/model"}]}"#).unwrap();
        assert_eq!(rows, ["deepseek/flash", "future/model"]);
        let config: Value = serde_json::from_str(
            &overlay(
                Some(OsStr::new(
                    r#"{"providers":{"other":{"name":"Existing"}},"theme":"dark"}"#,
                )),
                &rows,
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(config["providers"]["other"]["name"], "Existing");
        assert_eq!(config["theme"], "dark");
        assert_eq!(
            config["providers"]["coincide-lithos"]["models"]["future/model"]["name"],
            "future/model"
        );
        assert!(!config.to_string().contains("Bearer "));
    }
    #[test]
    fn temporary_refresh_failure_retains_only_the_same_accounts_last_models() {
        let key = "synthetic-model-cache-account-a";
        assert_eq!(
            cached_models_with(key, true, || Ok(vec!["fixture/model".into()])).unwrap(),
            ["fixture/model"]
        );
        let digest: [u8; 32] = Sha256::digest(key.as_bytes()).into();
        MODELS
            .get()
            .unwrap()
            .lock()
            .unwrap()
            .get_mut(&digest)
            .unwrap()
            .0 = Instant::now() - Duration::from_secs(301);
        assert_eq!(
            cached_models_with(key, false, || panic!("send should use the cached models")).unwrap(),
            ["fixture/model"]
        );
        assert_eq!(
            cached_models_with(key, true, || Err(anyhow::anyhow!("offline"))).unwrap(),
            ["fixture/model"]
        );
        assert!(
            cached_models_with("synthetic-model-cache-account-b", true, || Err(
                anyhow::anyhow!("offline")
            ))
            .is_err()
        );
    }
    #[test]
    fn model_discovery_sends_the_key_only_in_an_authorization_header() {
        use std::{
            io::{Read, Write},
            net::TcpListener,
            thread,
        };
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut connection, _) = listener.accept().unwrap();
            connection
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut request = [0u8; 4096];
            let len = connection.read(&mut request).unwrap();
            let request = String::from_utf8_lossy(&request[..len]);
            assert!(request.starts_with("GET /v1/models HTTP/1.1"));
            assert!(
                request
                    .to_ascii_lowercase()
                    .contains("authorization: bearer synthetic-key")
            );
            let body = r#"{"data":[{"id":"vendor/model"}]}"#;
            write!(connection, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).unwrap();
        });
        let rows = fetch_models(&format!("http://{address}/v1/models"), "synthetic-key").unwrap();
        assert_eq!(rows, ["vendor/model"]);
        server.join().unwrap();
    }
    #[test]
    fn local_discovery_includes_only_lithos_metal_and_preserves_inline_config() {
        let rows = parse_local_models(br#"{"data":[{"id":"fixture/model","owned_by":"lithos-metal","context_window":32768},{"id":"unrelated","owned_by":"vllm"}]}"#).unwrap();
        assert_eq!(rows, [("fixture/model".to_string(), Some(32768))]);
        let config: Value = serde_json::from_str(
            &local_overlay(Some(OsStr::new(r#"{"providers":{"other":{}}}"#)), &rows).unwrap(),
        )
        .unwrap();
        assert!(config["providers"]["other"].is_object());
        let local = &config["providers"]["coincide-lithos-local"]["models"]["fixture/model"];
        assert_eq!(local["limit"]["context"], 32768);
        assert_eq!(local["capabilities"]["tools"], true);
        assert!(
            parse_local_models(br#"{"data":[{"id":"not-lithos","owned_by":"vllm"}]}"#)
                .unwrap()
                .is_empty()
        );
    }
}
