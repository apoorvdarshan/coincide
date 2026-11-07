//! Internal test host for the exact production native adapter modules.
//! It has no binary, UI toolkit, copied adapter, or independent authority.
#![cfg(windows)]

#[cfg(test)]
#[path = "../../coincide-desktop/src/computer_use.rs"]
mod computer_use;
