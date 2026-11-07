//! Swift's `BotStarter` and `AppStore.addStarterBotsIfNeeded`: the bot
//! Coincide offers the first time it runs with bots, on the user's default
//! agent or the first one installed when that one is not. Each is an ordinary
//! bot once added; deleted starters do not come back.
use super::*;

/// The starter lineup this version offers (`BotStarter.lineup`).
pub const LINEUP: u64 = 2;

/// Brulee's standing instructions (`BotStarter.everydayHelper`).
const EVERYDAY_HELPER: &str = "You are a cheerful everyday helper. Answer quick questions, explain things plainly, do small tasks on this Mac (convert a file, rename a batch of photos, work out a command) and suggest a better bot or a project thread when a job grows big. Prefer short answers with the key point first.";

/// The bot each starter makes, as Swift encodes `BotStarter.makeBot`: the
/// character's name, look and default personality, on `selection`. Starters
/// that change files would ask first; Brulee uses the default access.
fn starter_bots(selection: &Value, access_mode: &Value, created_at: f64) -> Vec<Value> {
    vec![json!({
        "id": Uuid::new_v4().to_string().to_uppercase(),
        "name": "Brulee",
        "avatar": {"shape": "brulee", "tint": "rose"},
        "persona": EVERYDAY_HELPER,
        "personality": {"preset": "cheerful", "custom": ""},
        "selection": selection,
        "accessMode": access_mode,
        "interactionMode": "build",
        "createdAt": created_at,
        "starterID": "brulee",
    })]
}

/// `ProviderRegistry.usableSelection(preferring:)`: the default selection when
/// its agent is installed, else the first installed agent's default model.
/// Rust discovery knows installation only, not sign-in or model lists.
fn usable_selection(default: &Value, discovery: &Value) -> Value {
    let installed = discovery["providers"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|entry| entry["state"] == "found")
        .filter_map(|entry| entry["provider"].as_str())
        .collect::<Vec<_>>();
    if default["provider"]
        .as_str()
        .is_some_and(|provider| installed.contains(&provider))
    {
        return default.clone();
    }
    installed
        .first()
        .map(|provider| json!({"provider": provider, "modelID": "default"}))
        .unwrap_or_else(|| default.clone())
}

impl Engine {
    /// Adds the starter bots the first time it is called after provider
    /// discovery. Later calls do nothing, so starters the user deleted stay
    /// deleted. `None` while discovery is still running; otherwise whether
    /// it added them. Bots saved under an earlier lineup keep their record;
    /// Swift's one-time lineup migration is not repeated here.
    pub fn add_starter_bots_if_needed(&mut self) -> Result<Option<bool>> {
        self.require_admissions()?;
        let Some(discovery) = self.provider_discovery.clone() else {
            return Ok(None);
        };
        let source = match self.store.local_document("bots.json")? {
            Some(local) => Some(local),
            None => self
                .store
                .original("bots.json")?
                .map(|bytes| serde_json::from_slice::<Value>(&bytes))
                .transpose()
                .context("Captured bots document is invalid")?,
        };
        let mut document = source.clone().unwrap_or_else(
            || json!({"addedStarters": false, "bots": [], "starterLineup": LINEUP}),
        );
        if document["addedStarters"] == true {
            return Ok(Some(false));
        }
        let settings = self
            .store
            .document("settings.json")?
            .unwrap_or_else(|| json!({}));
        let default = settings
            .get("defaultSelection")
            .filter(|value| value.is_object())
            .cloned()
            .unwrap_or_else(|| json!({"provider": "claude", "modelID": "default"}));
        let access = settings
            .get("defaultAccessMode")
            .filter(|value| value.is_string())
            .cloned()
            .unwrap_or_else(|| json!("fullAccess"));
        let selection = usable_selection(&default, &discovery);
        let bots = document["bots"]
            .as_array_mut()
            .context("Invalid bots envelope")?;
        // A bot the user already has keeps its place; starters go after it.
        let existing = bots
            .iter()
            .filter_map(|bot| bot["starterID"].as_str().map(str::to_owned))
            .collect::<HashSet<_>>();
        let now = crate::store::swift_timestamp();
        for (offset, bot) in starter_bots(&selection, &access, now)
            .into_iter()
            .enumerate()
        {
            if !existing.contains(bot["starterID"].as_str().unwrap_or_default()) {
                let mut bot = bot;
                bot["createdAt"] = json!(now + offset as f64 / 1000.0);
                bots.push(bot);
            }
        }
        document["addedStarters"] = json!(true);
        self.store
            .save_bots_document_if_unchanged(source.as_ref(), &document)?;
        self.revision += 1;
        Ok(Some(true))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture(PathBuf);
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn engine() -> (Fixture, Engine) {
        let dir = std::env::temp_dir().join(format!("coincide-starters-{}", Uuid::new_v4()));
        let store = Store::open(&dir.join("data.sqlite")).unwrap();
        (Fixture(dir), Engine::fixture(store))
    }
    fn discovered(engine: &mut Engine, installed: &[&str]) {
        engine.provider_discovery = Some(json!({"providers": installed
            .iter()
            .map(|provider| json!({"provider": provider, "state": "found"}))
            .chain([json!({"provider": "grok", "state": "not_found"})])
            .collect::<Vec<_>>()}));
    }

    #[test]
    fn brulee_is_added_once_after_discovery_on_the_default_agent() {
        let (_fixture, mut engine) = engine();
        assert_eq!(engine.add_starter_bots_if_needed().unwrap(), None);
        assert!(engine.store.document("bots.json").unwrap().is_none());
        engine
            .store
            .save_document(
                "settings.json",
                &json!({"defaultSelection":{"provider":"codex","modelID":"gpt-5"},"defaultAccessMode":"approval"}),
            )
            .unwrap();
        discovered(&mut engine, &["claude", "codex"]);
        let revision = engine.revision;
        assert_eq!(engine.add_starter_bots_if_needed().unwrap(), Some(true));
        assert!(engine.revision > revision);
        let document = engine.store.document("bots.json").unwrap().unwrap();
        assert_eq!(document["addedStarters"], true);
        assert_eq!(document["starterLineup"], LINEUP);
        let bots = document["bots"].as_array().unwrap();
        assert_eq!(bots.len(), 1);
        let bot = &bots[0];
        assert_eq!(bot["name"], "Brulee");
        assert_eq!(bot["starterID"], "brulee");
        assert_eq!(bot["avatar"], json!({"shape":"brulee","tint":"rose"}));
        assert_eq!(bot["personality"], json!({"preset":"cheerful","custom":""}));
        assert_eq!(bot["persona"], EVERYDAY_HELPER);
        assert_eq!(
            bot["selection"],
            json!({"provider":"codex","modelID":"gpt-5"})
        );
        assert_eq!(bot["accessMode"], "approval");
        assert_eq!(bot["interactionMode"], "build");
        assert!(Uuid::parse_str(bot["id"].as_str().unwrap()).is_ok());
        assert!(bot.get("folder").is_none());
        // A deleted starter stays deleted.
        let mut emptied = document.clone();
        emptied["bots"] = json!([]);
        engine
            .store
            .save_bots_document_if_unchanged(Some(&document), &emptied)
            .unwrap();
        assert_eq!(engine.add_starter_bots_if_needed().unwrap(), Some(false));
        assert_eq!(
            engine.store.document("bots.json").unwrap().unwrap(),
            emptied
        );
    }

    #[test]
    fn an_uninstalled_default_falls_back_to_the_first_installed_agent() {
        let default = json!({"provider":"claude","modelID":"opus"});
        let discovery = |installed: &[&str]| json!({"providers": installed.iter().map(|p| json!({"provider":p,"state":"found"})).collect::<Vec<_>>()});
        assert_eq!(
            usable_selection(&default, &discovery(&["codex", "cursor"])),
            json!({"provider":"codex","modelID":"default"})
        );
        assert_eq!(usable_selection(&default, &discovery(&["claude"])), default);
        assert_eq!(usable_selection(&default, &discovery(&[])), default);
    }

    #[test]
    fn existing_bots_and_unknown_fields_are_kept_and_settings_defaults_apply() {
        let (_fixture, mut engine) = engine();
        let mine =
            json!({"id":"9E2F3A6C-1111-4B6E-8F00-000000000001","name":"Mine","future":{"keep":1}});
        engine
            .store
            .save_document(
                "bots.json",
                &json!({"addedStarters":false,"bots":[mine],"starterLineup":2,"future":true}),
            )
            .unwrap();
        discovered(&mut engine, &[]);
        assert_eq!(engine.add_starter_bots_if_needed().unwrap(), Some(true));
        let document = engine.store.document("bots.json").unwrap().unwrap();
        assert_eq!(document["future"], true);
        assert_eq!(document["bots"][0], mine);
        let starter = &document["bots"][1];
        assert_eq!(
            starter["selection"],
            json!({"provider":"claude","modelID":"default"})
        );
        assert_eq!(starter["accessMode"], "fullAccess");
        // A starter the user already has is not added twice.
        let mut again = document.clone();
        again["addedStarters"] = json!(false);
        engine
            .store
            .save_bots_document_if_unchanged(Some(&document), &again)
            .unwrap();
        assert_eq!(engine.add_starter_bots_if_needed().unwrap(), Some(true));
        let after = engine.store.document("bots.json").unwrap().unwrap();
        assert_eq!(after["bots"].as_array().unwrap().len(), 2);
    }
}
