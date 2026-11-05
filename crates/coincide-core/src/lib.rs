//! Portable Coincide state. No UI or Apple framework dependencies.
pub mod store;

pub mod agent;
pub mod api;
pub mod attachments;
pub mod browser_protocol;
pub mod control;
pub mod provider_catalog;
pub mod schedule_service;
pub mod scheduling;
pub mod terminal;
pub mod workspace;

pub mod message_queue;
pub mod thread_history;

pub mod cli_session_import;
pub mod organization;
pub mod usage_history;
pub mod credentials;
pub mod dictation;
pub mod platform_host;
pub mod remote;
pub mod workspace_git;
pub mod workspace_github;
