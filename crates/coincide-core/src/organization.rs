//! Lossless, bounded views over captured Swift organization documents.
//! Callers supply bytes (for example `Store::original`); this module never discovers,
//! writes, or activates instruction files or provider sessions.
use anyhow::{Result, bail, ensure};
use serde_json::Value;
use std::collections::HashSet;
use uuid::Uuid;

pub const DOCUMENT_LIMIT: usize = 16_000_000;
pub const RECORD_LIMIT: usize = 10_000;

#[derive(Clone, Debug)]
pub struct Records {
    original: Vec<u8>,
    records: Vec<Value>,
}
impl Records {
    /// An array of objects with unique UUID identities; invalid input is all-or-nothing.
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        ensure!(
            bytes.len() <= DOCUMENT_LIMIT,
            "organization document too large"
        );
        let records: Vec<Value> = serde_json::from_slice(bytes)?;
        ensure!(
            records.len() <= RECORD_LIMIT,
            "too many organization records"
        );
        let mut ids = HashSet::new();
        for record in &records {
            ensure!(record.is_object(), "record must be an object");
            let id = record
                .get("id")
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow::anyhow!("record missing id"))?;
            ensure!(ids.insert(Uuid::parse_str(id)?), "duplicate record id");
        }
        Ok(Self {
            original: bytes.to_vec(),
            records,
        })
    }
    pub fn original(&self) -> &[u8] {
        &self.original
    }
    pub fn records(&self) -> &[Value] {
        &self.records
    }
    /// Editing a bot preserves all unknown fields. No execution permissions are inferred.
    pub fn rename_bot(&mut self, id: Uuid, name: &str) -> Result<()> {
        let name = name.trim();
        ensure!(
            !name.is_empty() && name.chars().count() <= 200,
            "invalid bot name"
        );
        let Some(record) = self
            .records
            .iter_mut()
            .find(|r| r["id"].as_str().and_then(|s| Uuid::parse_str(s).ok()) == Some(id))
        else {
            bail!("bot not found")
        };
        record["name"] = Value::String(name.to_owned());
        Ok(())
    }
    pub fn working_bytes(&self) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(&self.records)?)
    }
}

/// A captured instruction is display-only. Global and linked files are never edited.
#[derive(Clone, Debug)]
pub struct InstructionSnapshot {
    bytes: Vec<u8>,
}
impl InstructionSnapshot {
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        ensure!(bytes.len() <= 1_048_576, "instruction too large");
        std::str::from_utf8(bytes)?;
        Ok(Self {
            bytes: bytes.to_vec(),
        })
    }
    pub fn original(&self) -> &[u8] {
        &self.bytes
    }
    pub fn text(&self) -> &str {
        std::str::from_utf8(&self.bytes).expect("validated UTF-8")
    }
}
