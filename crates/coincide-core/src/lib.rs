//! Portable Coincide state. No UI or Apple framework dependencies.
pub mod store;

pub mod agent;
pub mod api;
pub mod attachments;
pub mod browser_protocol;
pub mod control;
pub mod provider_catalog;
pub mod provider_preferences;
pub use api::project_defaults;
pub use api::provider_configuration;
pub mod schedule_service;
pub mod scheduling;
pub mod terminal;
pub mod workspace;
pub mod workspace_diff;

pub mod inspector_preferences;
pub mod message_queue;
pub mod palette_search;
pub mod schedule_presentation;
pub mod thread_history;

pub mod cli_session_discovery;
pub mod cli_session_import;
pub mod credentials;
pub mod dictation;
pub mod local_usage;
pub mod organization;
pub mod passkeys;
pub mod platform_host;
pub mod remote;
pub mod turn_checkpoints;
pub mod usage_history;
pub mod usage_limits;
pub mod usage_presentation;
pub mod usage_pricing;
pub mod usage_report;
pub mod workspace_git;
pub mod workspace_github;

pub mod github_api;
pub mod github_checkout;

pub mod bot_runtime;

pub mod github_write;

pub mod updater;

pub mod legacy_media;

pub mod composer_follow_up;
pub mod composer_selection;

pub mod legacy_media_service;

pub mod model_catalog;

pub mod github_threads;

pub mod updater_install;

#[cfg(feature = "preview-updater-helper")]
pub mod updater_helper;

pub mod computer_use;
pub mod computer_use_bridge;

pub mod legacy_media_recovery;

pub mod composer_context;

pub mod composer_policy;

pub mod composer_suggestions;

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

pub mod appshots;

pub mod reply_selection;

pub mod voice;

/// Bounded native-WebView screenshot data; this module grants no browser authority.
pub mod browser_screenshot;
