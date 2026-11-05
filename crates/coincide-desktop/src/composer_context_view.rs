//! Bounded display projection; never drops or normalizes stored context.
use serde_json::Value;
#[derive(Clone, Debug)]
pub struct Card {
    pub id: Option<String>,
    pub title: String,
    pub preview: String,
}
pub fn cards(raw: &Value) -> Vec<Card> {
    let Some(rows) = raw.as_array() else {
        return Vec::new();
    };
    rows.iter()
        .take(coincide_core::composer_context::MAX_ITEMS)
        .map(|row| {
            let kind = row["kind"].as_str().unwrap_or("Unsupported reference");
            let title = match kind {
                "quote" => "Quoted reply",
                "terminal" => "Terminal excerpt",
                "diff-comment" => "Diff comment",
                "file" => "File path reference only",
                "window-text" => "Window text",
                _ => "Unsupported saved reference",
            }
            .to_owned();
            let preview = ["text", "comment", "path"]
                .into_iter()
                .find_map(|key| row[key].as_str())
                .unwrap_or("Saved data retained")
                .chars()
                .take(160)
                .collect();
            Card {
                id: row["id"]
                    .as_str()
                    .filter(|id| uuid::Uuid::parse_str(id).is_ok())
                    .map(str::to_owned),
                title,
                preview,
            }
        })
        .collect()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn future_context_is_visible_without_interpretation_or_mutation() {
        let raw = serde_json::json!([{"id":uuid::Uuid::nil(),"kind":"future","opaque":[1,2]}]);
        let before = raw.clone();
        let output = cards(&raw);
        assert_eq!(output.len(), 1);
        assert_eq!(output[0].title, "Unsupported saved reference");
        assert_eq!(raw, before);
    }
}
