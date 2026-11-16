//! Bounded display projection; never drops or normalizes stored context.
use serde_json::Value;
#[derive(Clone, Debug)]
pub struct Card {
    pub id: Option<String>,
    pub title: String,
    pub preview: String,
    pub is_file: bool,
    pub is_directory: bool,
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
            let title = super::context_details::details(row)
                .map(|details| details.title)
                .unwrap_or(title);
            let preview = super::context_details::preview(row);
            Card {
                id: row["id"]
                    .as_str()
                    .filter(|id| uuid::Uuid::parse_str(id).is_ok())
                    .map(str::to_owned),
                title,
                preview,
                is_file: kind == "file",
                is_directory: kind == "file" && row["isDirectory"] == true,
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
    #[::core::prelude::v1::test]
    fn selected_file_and_folder_cards_keep_their_names_and_metadata() {
        let raw = serde_json::json!([
            {"id":uuid::Uuid::new_v4(),"kind":"file","path":"/tmp/notes.txt","isDirectory":false,"sizeBytes":22,"previewText":"First line"},
            {"id":uuid::Uuid::new_v4(),"kind":"file","path":"/tmp/project","isDirectory":true}
        ]);
        let output = cards(&raw);
        assert_eq!(output.len(), 2);
        assert_eq!(output[0].title, "notes.txt");
        assert!(output[0].is_file && !output[0].is_directory);
        assert_eq!(output[0].preview, "TXT · 22 B · First line");
        assert_eq!(output[1].title, "project");
        assert!(output[1].is_file && output[1].is_directory);
    }
}
