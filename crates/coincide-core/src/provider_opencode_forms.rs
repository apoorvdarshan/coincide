//! OpenCode Form.Info fields translated without flattening typed answers.
use super::*;
use std::collections::HashSet;

pub(super) struct Form {
    fields: Vec<Field>,
    pub questions: Vec<Value>,
}
struct Field {
    key: String,
    kind: String,
    options: Vec<(String, String, Option<String>)>,
    custom: bool,
}
impl Form {
    pub fn parse(value: &Value) -> Result<Self> {
        let fields = value["fields"]
            .as_array()
            .context("OpenCode form has no fields")?;
        ensure!(
            !fields.is_empty() && fields.len() <= 20,
            "OpenCode form has an unsupported field count"
        );
        let mut parsed = Vec::new();
        let mut questions = Vec::new();
        let mut seen = HashSet::new();
        for field in fields {
            let key = field["key"]
                .as_str()
                .filter(|v| !v.is_empty())
                .context("OpenCode form field has no key")?;
            ensure!(seen.insert(key.to_owned()), "OpenCode form repeats a key");
            ensure!(
                field["hidden"] != true && field["when"].as_array().is_none_or(Vec::is_empty),
                "OpenCode conditional or hidden forms are unsupported"
            );
            let kind = field["type"]
                .as_str()
                .context("OpenCode form field has no type")?;
            ensure!(
                matches!(
                    kind,
                    "string" | "multiselect" | "boolean" | "number" | "integer"
                ),
                "OpenCode form field type is unsupported"
            );
            let mut options = Vec::new();
            for option in field["options"].as_array().into_iter().flatten() {
                let value = option["value"]
                    .as_str()
                    .context("OpenCode choice has no string value")?;
                let label = option["label"]
                    .as_str()
                    .filter(|v| !v.is_empty())
                    .unwrap_or(value);
                ensure!(
                    !options.iter().any(|(old, _, _)| old == label),
                    "OpenCode form has ambiguous option labels"
                );
                let description = option["description"]
                    .as_str()
                    .filter(|v| !v.trim().is_empty())
                    .map(str::to_owned);
                options.push((label.to_owned(), value.to_owned(), description));
            }
            if kind == "boolean" {
                options = vec![
                    ("Yes".into(), "true".into(), None),
                    ("No".into(), "false".into(), None),
                ];
            }
            let custom = field["custom"] == true || options.is_empty();
            let mut option_rows = Vec::new();
            for (label, _, description) in &options {
                let mut row = json!({"label":label});
                if let Some(description) = description {
                    row["description"] = json!(description);
                }
                option_rows.push(row);
            }
            let mut question = json!({"id":key,"question":field["description"].as_str().or_else(||field["title"].as_str()).unwrap_or(key),
                "options":option_rows,"multiSelect":kind=="multiselect","allowsFreeText":custom});
            if let Some(header) = field["title"].as_str().filter(|v| !v.trim().is_empty()) {
                question["header"] = json!(header);
            }
            questions.push(question);
            parsed.push(Field {
                key: key.into(),
                kind: kind.into(),
                options,
                custom,
            });
        }
        Ok(Self {
            fields: parsed,
            questions,
        })
    }
    pub fn answer(&self, reply: &Value) -> Result<Value> {
        let answers = reply["answers"]
            .as_object()
            .context("OpenCode answers are missing")?;
        let mut result = serde_json::Map::new();
        for field in &self.fields {
            let values = answers
                .get(&field.key)
                .and_then(|v| v["answers"].as_array())
                .context("Every OpenCode question requires an answer")?;
            let values = values
                .iter()
                .map(|v| {
                    let text = v
                        .as_str()
                        .map(str::trim)
                        .filter(|v| !v.is_empty())
                        .context("OpenCode answer must contain text")?;
                    if let Some((_, value, _)) =
                        field.options.iter().find(|(label, _, _)| label == text)
                    {
                        return Ok(value.clone());
                    }
                    ensure!(
                        field.custom || field.options.iter().any(|(_, value, _)| value == text),
                        "Choose one of the OpenCode question options"
                    );
                    Ok(text.to_owned())
                })
                .collect::<Result<Vec<_>>>()?;
            ensure!(
                !values.is_empty(),
                "Every OpenCode question requires an answer"
            );
            ensure!(
                field.kind == "multiselect" || values.len() == 1,
                "OpenCode question accepts one answer"
            );
            let value = match field.kind.as_str() {
                "multiselect" => json!(values),
                "boolean" => match values[0].as_str() {
                    "true" => json!(true),
                    "false" => json!(false),
                    _ => bail!("OpenCode requires a boolean answer"),
                },
                "integer" => json!(
                    values[0]
                        .parse::<i64>()
                        .context("OpenCode requires an integer answer")?
                ),
                "number" => {
                    let number = values[0]
                        .parse::<f64>()
                        .context("OpenCode requires a number")?;
                    ensure!(number.is_finite(), "OpenCode requires a finite number");
                    json!(number)
                }
                _ => json!(values[0]),
            };
            result.insert(field.key.clone(), value);
        }
        Ok(json!({"answer":result}))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_choice_values_and_typed_form_answers() {
        let form=Form::parse(&json!({"fields":[{"key":"choice","type":"string","options":[{"label":"Friendly","value":"actual"}]},{"key":"flag","type":"boolean"},{"key":"count","type":"integer"}]})).unwrap();
        let reply = json!({"answers":{"choice":{"answers":["Friendly"]},"flag":{"answers":["Yes"]},"count":{"answers":["42"]}}});
        assert_eq!(
            form.answer(&reply).unwrap(),
            json!({"answer":{"choice":"actual","flag":true,"count":42}})
        );
        let mut invalid = reply.clone();
        invalid["answers"]["count"]["answers"] = json!(["3.5"]);
        assert!(form.answer(&invalid).is_err());
        invalid = reply;
        invalid["answers"]["choice"]["answers"] = json!(["arbitrary"]);
        assert!(form.answer(&invalid).is_err());
    }
    #[test]
    fn choice_descriptions_and_titles_reach_the_question_banner() {
        let form = Form::parse(&json!({"fields":[{"key":"color","title":"Color choice","description":"Which color?","type":"string","options":[{"label":"Red","value":"red","description":"Choose red."}]}]})).unwrap();
        assert_eq!(form.questions[0]["header"], "Color choice");
        assert_eq!(form.questions[0]["question"], "Which color?");
        assert_eq!(
            form.questions[0]["options"][0]["description"],
            "Choose red."
        );
    }

    #[test]
    fn unsupported_forms_are_never_guessed() {
        for field in [
            json!({"key":"a","type":"string","hidden":true}),
            json!({"key":"a","type":"url"}),
            json!({"key":"a","type":"string","when":[{}]}),
        ] {
            assert!(Form::parse(&json!({"fields":[field]})).is_err());
        }
    }
}
