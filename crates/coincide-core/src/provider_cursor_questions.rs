//! Cursor questions return option IDs; free text must use the protocol's skip reason.
use super::*;
use std::collections::HashSet;
pub(super) struct Questions {
    fields: Vec<Field>,
    pub normalized: Value,
}
struct Field {
    id: String,
    prompt: String,
    multiple: bool,
    options: Vec<(String, String)>,
}
impl Questions {
    pub fn parse(params: &Value) -> Result<Self> {
        let raw = params["questions"]
            .as_array()
            .context("Cursor questions are missing")?;
        ensure!(
            !raw.is_empty() && raw.len() <= 20,
            "Cursor question count is unsupported"
        );
        let mut fields = Vec::new();
        let mut normalized = Vec::new();
        let mut identifiers = HashSet::new();
        for value in raw {
            let id = value["id"]
                .as_str()
                .filter(|id| !id.is_empty())
                .context("Cursor question ID is missing")?;
            ensure!(
                identifiers.insert(id.to_owned()),
                "Cursor repeated a question ID"
            );
            let prompt = value["prompt"]
                .as_str()
                .filter(|v| !v.is_empty())
                .or_else(|| params["title"].as_str())
                .unwrap_or(id);
            let mut labels = HashSet::new();
            let mut ids = HashSet::new();
            let mut options = Vec::new();
            for option in value["options"].as_array().into_iter().flatten() {
                let id = option["id"]
                    .as_str()
                    .filter(|v| !v.is_empty())
                    .context("Cursor option ID is missing")?;
                ensure!(ids.insert(id.to_owned()), "Cursor repeated an option ID");
                let mut label = option["label"]
                    .as_str()
                    .filter(|v| !v.is_empty())
                    .unwrap_or(id)
                    .to_owned();
                if !labels.insert(label.clone()) {
                    label = format!("{label} ({id})");
                    ensure!(
                        labels.insert(label.clone()),
                        "Cursor options have ambiguous labels"
                    );
                }
                options.push((id.to_owned(), label));
            }
            let multiple = value["allowMultiple"] == true;
            normalized.push(json!({"id":id,"question":prompt,"multiSelect":multiple,"allowsFreeText":options.is_empty(),"options":options.iter().map(|(_,label)|json!({"label":label})).collect::<Vec<_>>()}));
            fields.push(Field {
                id: id.into(),
                prompt: prompt.into(),
                multiple,
                options,
            });
        }
        Ok(Self {
            fields,
            normalized: json!({"questions":normalized}),
        })
    }
    pub fn answer(&self, reply: &Value) -> Result<Value> {
        if reply["decision"] == "cancel" {
            return Ok(json!({"outcome":{"outcome":"cancelled"}}));
        }
        let replies = reply["answers"]
            .as_object()
            .context("Cursor answers are missing")?;
        let mut selections = Vec::new();
        let mut words = Vec::new();
        let mut typed = false;
        for field in &self.fields {
            let values = replies
                .get(&field.id)
                .and_then(|v| v["answers"].as_array())
                .context("Every Cursor question requires an answer")?;
            let values = values
                .iter()
                .map(|v| {
                    v.as_str()
                        .map(str::trim)
                        .filter(|v| !v.is_empty())
                        .context("Cursor answers must contain text")
                })
                .collect::<Result<Vec<_>>>()?;
            ensure!(
                !values.is_empty(),
                "Every Cursor question requires an answer"
            );
            let mut chosen = Vec::new();
            for value in &values {
                if let Some((id, _)) = field
                    .options
                    .iter()
                    .find(|(id, label)| id == *value || label == *value)
                {
                    if !chosen.contains(id) {
                        chosen.push(id.clone());
                    }
                } else {
                    typed = true;
                }
            }
            ensure!(
                field.multiple || chosen.len() <= 1,
                "Cursor question allows one selected option"
            );
            if !chosen.is_empty() {
                selections.push(json!({"questionId":field.id,"selectedOptionIds":chosen}));
            }
            words.push(format!("{}: {}", field.prompt, values.join(", ")));
        }
        Ok(if typed {
            json!({"outcome":{"outcome":"skipped","reason":format!("The user replied in their own words:\n{}",words.join("\n"))}})
        } else {
            json!({"outcome":{"outcome":"answered","answers":selections}})
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn option_ids_and_typed_text_follow_cursor_protocol() {
        let questions=Questions::parse(&json!({"questions":[{"id":"q","prompt":"Choose","options":[{"id":"a","label":"First"}]}]})).unwrap();
        assert_eq!(
            questions
                .answer(&json!({"answers":{"q":{"answers":["First"]}}}))
                .unwrap(),
            json!({"outcome":{"outcome":"answered","answers":[{"questionId":"q","selectedOptionIds":["a"]}]}})
        );
        let typed = questions
            .answer(&json!({"answers":{"q":{"answers":["my own answer"]}}}))
            .unwrap();
        assert_eq!(typed["outcome"]["outcome"], "skipped");
        assert!(
            typed["outcome"]["reason"]
                .as_str()
                .unwrap()
                .contains("my own answer")
        );
        assert_eq!(
            questions.answer(&json!({"decision":"cancel"})).unwrap()["outcome"]["outcome"],
            "cancelled"
        );
    }
}
