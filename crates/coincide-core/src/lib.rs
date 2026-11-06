//! Portable Coincide state. No UI or Apple framework dependencies.
pub mod store;

pub mod agent;
pub mod api;
pub mod attachments;
pub mod browser_protocol;
pub mod control;
pub mod provider_catalog;
pub mod provider_preferences;
pub use api::provider_configuration;
pub use api::project_defaults;
pub mod schedule_service;
pub mod scheduling;
pub mod terminal;
pub mod workspace;

pub mod message_queue;
pub mod thread_history;

pub mod cli_session_import;
pub mod credentials;
pub mod dictation;
pub mod local_usage;
pub mod organization;
pub mod platform_host;
pub mod remote;
pub mod usage_history;
pub mod workspace_git;
pub mod workspace_github;

pub mod github_api;

pub mod bot_runtime;

pub mod github_write;

pub mod updater;

pub mod legacy_media;

pub mod composer_selection;

pub mod legacy_media_service;

pub mod model_catalog;

pub mod github_threads;

pub mod updater_install;

#[cfg(feature = "preview-updater-helper")]
pub mod updater_helper;

pub mod computer_use;

pub mod legacy_media_recovery;

pub mod composer_context;

pub mod composer_policy;

pub mod browser_bookmarks;
pub mod browser_history;

pub mod firefox_cookie_import;

pub(crate) mod codex_login_profiles;

mod digest_hex;

mod named_profile_resume;
mod private_fs;

pub mod native_file;
pub mod native_instruction_profiles;
pub mod native_ui_edits;
