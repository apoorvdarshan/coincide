use anyhow::{Result, bail};
use coincide_core::store::Store;
use std::path::Path;
fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("import") if args.len() == 4 => {
            let mut store = Store::open(Path::new(&args[3]))?;
            println!(
                "{}",
                serde_json::to_string_pretty(&store.import_legacy(Path::new(&args[2]))?)?
            );
        }
        Some("check") if args.len() == 3 => {
            let store = Store::open(Path::new(&args[2]))?;
            println!("{} threads readable", store.summaries("", true)?.len());
        }
        _ => bail!("Usage: coincide-store import SOURCE_DIRECTORY NEW_DATABASE | check DATABASE"),
    }
    Ok(())
}
