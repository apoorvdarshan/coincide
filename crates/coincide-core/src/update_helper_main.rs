//! Explicit, feature-gated binary entry. Never place this file under src/bin.
fn main() -> anyhow::Result<()> {
    coincide_core::updater_helper::native_main()
}
