//! Source-backed OpenCode 2 catalog reads. No session, prompt, turn or auth
//! operation is sent. The existing Server/Runtime retain all process/I/O joins.
use super::*;
fn text(value: &Value) -> Option<String> {
    value
        .as_str()
        .filter(|text| !text.is_empty() && text.len() <= 512 && !text.chars().any(char::is_control))
        .map(str::to_owned)
}
struct Entry {
    id: String,
    name: String,
    provider: String,
    family: Option<String>,
    released: Option<f64>,
    deprecated: bool,
    context_window: Option<u64>,
    efforts: Vec<String>,
    default_effort: Option<String>,
    supports_images: Option<bool>,
}
const EFFORT_RANK: [&str; 7] = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];
/// Reasoning variants in increasing effort order, as OpenCode 2 reports them.
fn ordered_efforts(model: &Value) -> Vec<String> {
    let mut unique = Vec::<String>::new();
    for variant in model["variants"].as_array().into_iter().flatten().take(64) {
        if let Some(id) = text(&variant["id"])
            && !unique.contains(&id)
        {
            unique.push(id);
        }
    }
    let mut known = unique
        .iter()
        .filter(|effort| EFFORT_RANK.contains(&effort.as_str()))
        .cloned()
        .collect::<Vec<_>>();
    known.sort_by_key(|effort| {
        EFFORT_RANK
            .iter()
            .position(|rank| rank == effort)
            .unwrap_or(EFFORT_RANK.len())
    });
    known.extend(
        unique
            .into_iter()
            .filter(|effort| !EFFORT_RANK.contains(&effort.as_str())),
    );
    known
}
/// The reasoning variant OpenCode 2 selects for a model when none is chosen.
fn default_effort(provider: &str, efforts: &[String]) -> Option<String> {
    if efforts.len() == 1 {
        return efforts.first().cloned();
    }
    let find = |wanted: &str| {
        efforts
            .iter()
            .find(|effort| effort.as_str() == wanted)
            .cloned()
    };
    if provider == "anthropic" || provider.starts_with("google") {
        return find("high");
    }
    if provider == "openai" || provider == "opencode" {
        return find("medium").or_else(|| find("high"));
    }
    None
}
fn context_window(model: &Value) -> Option<u64> {
    model["limit"]["input"]
        .as_u64()
        .filter(|window| *window > 0)
        .or_else(|| model["limit"]["context"].as_u64().filter(|window| *window > 0))
}
fn supports_images(model: &Value) -> Option<bool> {
    model["capabilities"]["input"]
        .as_array()
        .map(|inputs| inputs.iter().any(|input| input == "image"))
}
fn rows(models: &Value, providers: &Value) -> Vec<Value> {
    let names = providers["data"]
        .as_array()
        .into_iter()
        .flatten()
        .take(256)
        .filter_map(|provider| Some((text(&provider["id"])?, text(&provider["name"])?)))
        .collect::<HashMap<_, _>>();
    let mut entries = Vec::<Entry>::new();
    for model in models["data"].as_array().into_iter().flatten().take(4000) {
        if model["enabled"] == false {
            continue;
        }
        let (Some(provider), Some(id)) = (text(&model["providerID"]), text(&model["id"])) else {
            continue;
        };
        let slug = format!("{provider}/{id}");
        if crate::composer_selection::validate_model(&slug).is_err()
            || entries.iter().any(|entry| entry.id == slug)
        {
            continue;
        }
        let name = text(&model["name"]).unwrap_or(id);
        let efforts = ordered_efforts(model);
        entries.push(Entry {
            id: slug,
            name,
            provider: provider.clone(),
            family: text(&model["family"]),
            released: model["time"]["released"].as_f64(),
            deprecated: model["status"] == "deprecated",
            context_window: context_window(model),
            default_effort: default_effort(&provider, &efforts),
            efforts,
            supports_images: supports_images(model),
        });
        if entries.len() == 1000 {
            break;
        }
    }
    let mut newest = HashMap::<(String, String), f64>::new();
    let mut shared = HashMap::<String, HashSet<String>>::new();
    for Entry {
        name,
        provider,
        family,
        released,
        deprecated,
        ..
    } in &entries
    {
        shared
            .entry(name.clone())
            .or_default()
            .insert(provider.clone());
        if !deprecated && let (Some(family), Some(released)) = (family, released) {
            newest
                .entry((provider.clone(), family.clone()))
                .and_modify(|latest| *latest = latest.max(*released))
                .or_insert(*released);
        }
    }
    let mut result = entries
        .into_iter()
        .map(
            |Entry {
                 id,
                 name,
                 provider,
                 family,
                 released,
                 deprecated,
                 context_window,
                 efforts,
                 default_effort,
                 supports_images,
             }| {
                let retired = deprecated
                    || family
                        .and_then(|family| newest.get(&(provider.clone(), family)).copied())
                        .zip(released)
                        .is_some_and(|(latest, released)| released < latest);
                let label = if shared
                    .get(&name)
                    .is_some_and(|providers| providers.len() > 1)
                {
                    let provider = names
                        .get(&provider)
                        .map(|name| name.rsplit(" / ").next().unwrap_or(name))
                        .unwrap_or(&provider);
                    format!("{name} ({provider})")
                } else {
                    name
                };
                (retired, label.clone(), json!({"id":id,"displayName":label,
                    "contextWindow":context_window,"reportedEfforts":efforts,
                    "reportedDefaultEffort":default_effort,"reportedSpeeds":[],
                    "supportsImages":supports_images}))
            },
        )
        .collect::<Vec<_>>();
    result.sort_by(|left, right| {
        (left.0, left.1.to_lowercase()).cmp(&(right.0, right.1.to_lowercase()))
    });
    result.into_iter().map(|(_, _, row)| row).collect()
}
fn integrations(value: &Value) -> Option<String> {
    let mut names = value["data"]
        .as_array()
        .into_iter()
        .flatten()
        .take(256)
        .filter_map(|integration| {
            let id = text(&integration["id"])?;
            if id.starts_with("mcp_")
                || !integration["connections"]
                    .as_array()
                    .is_some_and(|connections| !connections.is_empty())
            {
                return None;
            }
            text(&integration["name"]).or(Some(id))
        })
        .collect::<Vec<_>>();
    names.sort_by_key(|name| name.to_lowercase());
    names.dedup();
    (!names.is_empty()).then(|| names.join(", "))
}
fn gather(
    mut request: impl FnMut(&'static str) -> Result<Value>,
    mut pause: impl FnMut(),
    allowed: &impl Fn() -> bool,
) -> Result<(Vec<Value>, Option<String>)> {
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut latest = Value::Null;
    let mut previous = None;
    let mut settle = None;
    loop {
        ensure!(allowed(), "OpenCode metadata check cancelled");
        match request("/api/model") {
            Ok(models) => {
                let print = rows(&models, &Value::Null);
                if !print.is_empty() {
                    let matched = previous.as_ref() == Some(&print);
                    previous = Some(print);
                    latest = models;
                    settle.get_or_insert_with(|| Instant::now() + Duration::from_secs(5));
                    if matched {
                        break;
                    }
                }
            }
            Err(_) if latest.is_null() && Instant::now() < deadline => {}
            Err(error) if latest.is_null() => return Err(error),
            Err(_) => break,
        }
        if Instant::now() >= deadline || settle.is_some_and(|deadline| Instant::now() >= deadline) {
            break;
        }
        pause();
    }
    ensure!(allowed(), "OpenCode metadata check cancelled");
    let providers = request("/api/provider").unwrap_or(Value::Null);
    ensure!(allowed(), "OpenCode metadata check cancelled");
    let connected = request("/api/integration").unwrap_or(Value::Null);
    Ok((rows(&latest, &providers), integrations(&connected)))
}
pub(super) fn read(
    executable: &std::path::Path,
    allowed: &impl Fn() -> bool,
) -> Result<(Vec<Value>, Option<String>)> {
    let cwd = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .context("OpenCode metadata home unavailable")?
        .canonicalize()?;
    let directory = cwd
        .to_str()
        .context("OpenCode metadata directory is not text")?
        .to_owned();
    let launch = Launch {
        executable: executable.to_path_buf(),
        cwd,
        session: None,
        prompt: String::new(),
        model: None,
        variant: None,
    };
    let (_control, commands) = mpsc::channel();
    let (events, _messages) = mpsc::channel();
    let mut runtime = Runtime {
        cancelled: Some(allowed),
        commands,
        queued: VecDeque::new(),
        events: &events,
        aborted_requests: Vec::new(),
        owned_workers: Vec::new(),
        #[cfg(test)]
        request_join_entered: None,
    };
    let server = Server::start(&launch, &mut runtime)?;
    gather(
        |path| runtime.catalog(&server.http, path, &directory),
        || thread::sleep(Duration::from_millis(250)),
        allowed,
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn owned_catalog_reads_exclude_disabled_models_mcp_accounts_and_credential_fields() {
        let models = json!({"data":[{"providerID":"openai","id":"older","name":"Same","family":"family","time":{"released":1},"limit":{"input":200000},"variants":[{"id":"high"},{"id":"low"}],"capabilities":{"input":["text","image"]}},{"providerID":"openai","id":"newer","name":"Same","family":"family","time":{"released":2}},{"providerID":"anthropic","id":"current","name":"Same"},{"providerID":"openai","id":"disabled","enabled":false},{"providerID":"openai","id":"newer","name":"Duplicate"}]});
        let providers = json!({"data":[{"id":"openai","name":"Default / OpenAI"},{"id":"anthropic","name":"Anthropic"}]});
        let integrations = json!({"data":[{"id":"mcp_private","name":"Private tool","connections":[{}]},{"id":"empty","connections":[]},{"id":"openai","name":"OpenAI","connections":[{"apiKey":"synthetic-private-value"}]}]});
        let mut paths = Vec::new();
        let (rows, connected) = gather(
            |path| {
                paths.push(path);
                Ok(match path {
                    "/api/model" => models.clone(),
                    "/api/provider" => providers.clone(),
                    "/api/integration" => integrations.clone(),
                    _ => panic!("unexpected mutating request"),
                })
            },
            || {},
            &|| true,
        )
        .unwrap();
        assert_eq!(connected.as_deref(), Some("OpenAI"));
        assert_eq!(
            rows.iter()
                .map(|row| row["id"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["anthropic/current", "openai/newer", "openai/older"]
        );
        let older = rows
            .iter()
            .find(|row| row["id"] == "openai/older")
            .unwrap();
        assert_eq!(older["contextWindow"], json!(200000));
        assert_eq!(older["reportedEfforts"], json!(["low", "high"]));
        assert_eq!(older["reportedDefaultEffort"], json!("high"));
        assert_eq!(older["supportsImages"], json!(true));
        assert!(
            rows.iter()
                .all(|row| row["displayName"].as_str().unwrap().contains('('))
        );
        assert!(
            !serde_json::to_string(&rows)
                .unwrap()
                .contains("synthetic-private-value")
        );
        assert_eq!(paths.len(), 4);
        assert!(
            paths
                .iter()
                .all(|path| !path.contains("session") && !path.contains("prompt"))
        );
    }
    #[test]
    fn cancelled_metadata_admits_no_http_work() {
        assert!(gather(|_| panic!("cancelled check sent HTTP"), || {}, &|| false).is_err());
    }
}
