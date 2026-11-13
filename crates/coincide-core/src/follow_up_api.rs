//! Native, one-owner follow-up delivery. No JSON route or serialized operation
//! can schedule an interrupt. Crash/Quit loses pending delivery and keeps draft.
use super::*;
use crate::composer_follow_up::{self as choice, Behavior, Dispatch};
fn text_steer_timeout(provider: &str) -> Duration {
    // OpenCode can first read the workspace command catalog (up to 11 s)
    // and then await its HTTP acknowledgement (up to 16 s).
    if provider == "opencode" {
        Duration::from_secs(30)
    } else {
        Duration::from_secs(10)
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NativeFollowUpStatus {
    Pending,
    Delivered {
        dispatch: Dispatch,
        draft_cleared: bool,
    },
    Retained(String),
}
pub struct NativeFollowUpTicket {
    owner: Uuid,
    id: Uuid,
}
/// A captured send is either still waiting for an earlier provider receipt, or
/// has been saved exactly once. A receipt owns any immediate provider action.
pub enum CapturedNativeSend {
    Waiting,
    Saved {
        enabled: bool,
        cleared: bool,
        ticket: Option<NativeFollowUpTicket>,
        error: Option<String>,
    },
}
enum Delivery {
    Steering(String),
    TextSteer {
        provider: String,
        reply: std::sync::mpsc::Receiver<std::result::Result<(), String>>,
        accepted: bool,
        started: Instant,
        timeout: Duration,
        item_id: String,
        context: Value,
    },
    Deferred(agent::WorkerCompletion),
}
struct Operation {
    thread: String,
    source: Value,
    draft_revision: Option<Vec<u8>>,
    prefix: Option<PrefixProof>,
    text: String,
    dispatch: Dispatch,
    delivery: Option<Delivery>,
    status: NativeFollowUpStatus,
    queue: Option<super::queue_dispatch::QueueClaim>,
}
/// Verify the immutable prefix without retaining or limiting a copy of an
/// arbitrarily long conversation. The digest is private to this Engine.
struct PrefixProof {
    len: usize,
    digest: [u8; 32],
}
impl PrefixProof {
    fn capture(items: &[Value], len: usize) -> Result<Self> {
        use sha2::{Digest, Sha256};
        struct Writer<'a>(&'a mut Sha256);
        impl std::io::Write for Writer<'_> {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                use sha2::Digest;
                self.0.update(bytes);
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let prefix = items
            .get(..len)
            .context("Conversation prefix is unavailable")?;
        let mut digest = Sha256::new();
        serde_json::to_writer(Writer(&mut digest), prefix)?;
        Ok(Self {
            len,
            digest: digest.finalize().into(),
        })
    }
    fn matches(&self, items: &[Value]) -> Result<bool> {
        if items.len() < self.len {
            return Ok(false);
        }
        Ok(Self::capture(items, self.len)?.digest == self.digest)
    }
}
pub(super) struct State {
    owner: Uuid,
    operations: HashMap<Uuid, Operation>,
    blocked: HashMap<String, (Value, Option<Vec<u8>>)>,
}
impl Default for State {
    fn default() -> Self {
        Self {
            owner: Uuid::new_v4(),
            operations: HashMap::new(),
            blocked: HashMap::new(),
        }
    }
}
impl State {
    pub(super) fn has_capacity(&self) -> bool {
        self.operations.len() < 32
    }
    pub(super) fn has_pending(&self) -> bool {
        self.operations
            .values()
            .any(|op| op.status == NativeFollowUpStatus::Pending)
    }
    pub(super) fn pending_thread(&self, thread: &str) -> bool {
        self.operations
            .values()
            .any(|op| op.thread == thread && op.status == NativeFollowUpStatus::Pending)
    }
}
use choice::scope;
impl Engine {
    /// Preserve a native send which was waiting for local admission while the
    /// editor moved on. The captured payload owns its own queue entry; it must
    /// never clear or adopt the newer draft, images, or provider selection.
    pub fn queue_captured_native_send(
        &mut self,
        captured: &Value,
        clear_original: bool,
    ) -> Result<(bool, bool)> {
        let (enabled, cleared, _) =
            self.queue_captured_native_send_inner(captured, clear_original, true, None)?;
        Ok((enabled, cleared))
    }
    fn queue_captured_native_send_inner(
        &mut self,
        captured: &Value,
        clear_original: bool,
        notify_goal: bool,
        failure: Option<&str>,
    ) -> Result<(bool, bool, crate::message_queue::Message)> {
        self.require_admissions()?;
        ensure!(!self.shutdown, "Application is closing");
        let id = required(captured, "id")?;
        // This is a native-only captured submission. The user may have moved
        // to another conversation after pressing Send; its original thread and
        // execution context are revalidated below before queueing.
        ensure!(
            !self.unsaved_threads.contains_key(id),
            "Transcript persistence is recovering"
        );
        let current = self.store.thread(id)?;
        ensure!(
            !self.store.is_imported(id)? && current["isArchived"] != true,
            "Restore or fork this conversation first"
        );
        for key in [
            "projectID",
            "projectPath",
            "worktreePath",
            "botID",
            "rustBotContext",
            "accessMode",
            "interactionMode",
        ] {
            ensure!(
                current[key] == captured[key],
                "Conversation context changed; submission retained"
            );
        }
        let provider = text(&captured["selection"], "provider");
        Provider::from_name(&provider)?;
        self.require_provider_enabled(&provider)?;
        let context = captured["draftContext"].clone();
        crate::composer_context::validate(&context)?;
        let images: Vec<crate::attachments::StoredImage> = if captured["rustDraftImages"].is_null()
        {
            Vec::new()
        } else {
            serde_json::from_value(captured["rustDraftImages"].clone())
                .context("Invalid captured images")?
        };
        let data = self.store.data_directory()?;
        let prepared = images
            .iter()
            .map(|image| image.prepare_in(&data))
            .collect::<Result<Vec<_>>>()?;
        agent::validate_images(&Provider::from_name(&provider)?, &prepared)?;
        let existing = crate::message_queue::read(&current)?;
        let can_enable = failure.is_none()
            && captured["selection"] == current["selection"]
            && (self.enabled_queues.contains(id)
                || existing.iter().all(|message| {
                    !matches!(
                        message.state,
                        crate::message_queue::State::Pending
                            | crate::message_queue::State::Dispatching
                    )
                }));
        let mut target = current.clone();
        target["selection"] = captured["selection"].clone();
        let message = crate::message_queue::add_payload(
            &mut target,
            captured["draft"].as_str().unwrap_or(""),
            context,
            images,
        )?;
        target["selection"] = current["selection"].clone();
        if let Some(reason) = failure {
            let row = target["rustMessageQueue"]
                .as_array_mut()
                .and_then(|rows| rows.iter_mut().find(|row| row["id"] == message.id))
                .context("Captured message disappeared before it was saved")?;
            row["state"] = json!("failed");
            row["error"] = json!(reason);
        }
        let cleared = clear_original && current["draft"] == captured["draft"];
        if cleared {
            target["draft"] = json!("");
        }
        if let (Some(submitted), Some(draft_images)) = (
            captured["rustDraftImages"].as_array(),
            target["rustDraftImages"].as_array_mut(),
        ) {
            draft_images.retain(|image| !submitted.contains(image));
        }
        if target["draftContext"] == captured["draftContext"] {
            target.as_object_mut().unwrap().remove("draftContext");
        }
        target["rustQueueError"] = Value::Null;
        self.store.save_native_follow_up_turn(&current, &target)?;
        if can_enable {
            self.enabled_queues.insert(id.into());
        }
        if notify_goal {
            self.sync_goal_queue_waiting(id);
        }
        self.revision += 1;
        Ok((can_enable, cleared, message))
    }
    /// Admit an independent snapshot after an earlier send, preserving the
    /// mode selected when the user pressed Send and the order of older rows.
    pub fn admit_captured_native_send(
        &mut self,
        captured: &Value,
        clear_original: bool,
        behavior: Behavior,
        alternate: bool,
    ) -> Result<CapturedNativeSend> {
        let id = required(captured, "id")?;
        let current = self.store.thread(id)?;
        let provider = text(&captured["selection"], "provider");
        let chosen = if alternate {
            behavior.opposite()
        } else {
            behavior
        };
        let chosen = choice::effective(
            chosen,
            matches!(provider.as_str(), "codex" | "claude" | "opencode"),
        );
        let has_images = captured["rustDraftImages"]
            .as_array()
            .is_some_and(|images| !images.is_empty());
        let has_context = crate::composer_context::has_context(&captured["draftContext"]);
        let command = captured["draft"].as_str().unwrap_or("");
        let goal_control = provider == "codex"
            && !has_images
            && !has_context
            && agent::codex_goals::parse(command).is_some();
        let compact_control = matches!(provider.as_str(), "codex" | "opencode")
            && !has_images
            && !has_context
            && agent::codex_compact_command(command);
        let can_steer = self.runs.get(id).is_some_and(|run| {
            matches!(provider.as_str(), "codex" | "claude" | "opencode")
                && current["interactionMode"]
                    .as_str()
                    .is_none_or(|mode| mode == "build")
                && (provider != "codex" || run.session.can_steer())
                && !(has_images && matches!(provider.as_str(), "claude" | "opencode"))
        });
        let prior = crate::message_queue::read(&current)?;
        let eligible = chosen != Behavior::Queue
            && !compact_control
            && (chosen != Behavior::Steer || can_steer || goal_control)
            && self.active_thread.as_deref() == Some(id)
            && self.runs.contains_key(id)
            && captured["selection"] == current["selection"];
        if eligible && self.native_follow_up.pending_thread(id) {
            return Ok(CapturedNativeSend::Waiting);
        }
        let auto = eligible
            && !prior.iter().any(|message| {
                matches!(
                    message.state,
                    crate::message_queue::State::Pending | crate::message_queue::State::Dispatching
                )
            });
        let (enabled, cleared, message) =
            self.queue_captured_native_send_inner(captured, clear_original, !auto, None)?;
        if !auto {
            return Ok(CapturedNativeSend::Saved {
                enabled,
                cleared,
                ticket: None,
                error: None,
            });
        }
        // From here the snapshot is already durable. Never return Err to a
        // caller that would retry it and create a duplicate queue row.
        let result = (|| {
            let current = self.store.thread(id)?;
            let visible = serde_json::to_value(message)?;
            self.native_send_queued_with_behavior(&current, &visible, Some(chosen))
        })();
        if result.is_err() {
            self.enabled_queues.remove(id);
        }
        self.sync_goal_queue_waiting(id);
        let (ticket, error) = match result {
            Ok(ticket) => (Some(ticket), None),
            Err(error) => (None, Some(error.to_string())),
        };
        Ok(CapturedNativeSend::Saved {
            enabled,
            cleared,
            ticket,
            error,
        })
    }
    /// Preserve a buffered message whose image import failed for manual edit;
    /// an incomplete image payload must never be sent automatically.
    pub fn retain_failed_captured_native_send(&mut self, captured: &Value) -> Result<()> {
        self.queue_captured_native_send_inner(
            captured,
            false,
            true,
            Some("Image import failed; edit this message and attach the image again."),
        )?;
        Ok(())
    }
    /// A failed account/provider change must not send a buffered message to
    /// the previous selection. Keep it available for editing instead.
    pub fn retain_selection_failed_native_send(&mut self, captured: &Value) -> Result<()> {
        self.queue_captured_native_send_inner(
            captured,
            false,
            true,
            Some("Account or provider change failed; review this message before sending."),
        )?;
        Ok(())
    }
    /// Named follow-ups use the selected account's actual private catalog and
    /// policy, just like normal turn admission; never borrow a default proof.
    pub(super) fn validate_native_follow_up_policy(&self, thread: &Value) -> Result<()> {
        let provider = text(&thread["selection"], "provider");
        if let Some(run) = thread["id"].as_str().and_then(|id| self.runs.get(id)) {
            // A follow-up targets a worker whose exact selection was already
            // admitted. Refreshing model metadata must not invalidate that
            // live turn. A queued or interrupted replacement is validated
            // again when the next worker is actually started.
            ensure!(
                run.provider == provider,
                "Stored provider differs from the running turn"
            );
            ensure!(
                run.usage_context
                    .as_ref()
                    .is_some_and(|context| context.matches(thread)),
                "Stored selection or project differs from the running turn"
            );
            return self.require_provider_enabled(&provider);
        }
        let configuration = self.provider_launch_configuration_for_thread(thread)?;
        let _configuration_scope = provider_configuration::enter(configuration);
        self.require_provider_enabled(&text(&thread["selection"], "provider"))?;
        if let Some(profile) = self.codex_login_context(thread)? {
            let binding = crate::model_catalog::NamedBinding::capture(
                profile,
                required(thread, "id")?,
                &self.working_directory(thread)?,
            )?;
            self.model_catalog
                .named_resume_admission(thread, &binding)?;
            let proof = self
                .model_catalog
                .named_model_proof(thread, &binding, None)?;
            crate::composer_policy::Policy::parse_named(
                thread,
                crate::composer_policy::Origin::Ordinary,
                proof.as_ref(),
            )?
            .preflight()
        } else {
            let proof = self.composer_thread_effort_proof(thread)?;
            crate::composer_selection::validate_thread_with_proof(thread, proof.as_ref())
        }
    }
    pub fn choose_native_follow_up(
        &mut self,
        expected: &Value,
        behavior: Behavior,
    ) -> Result<Value> {
        self.require_admissions()?;
        ensure!(!self.shutdown, "Application is closing");
        let id = required(expected, "id")?;
        ensure!(
            self.active_thread.as_deref() == Some(id),
            "Composer is no longer active"
        );
        ensure!(
            !self.unsaved_threads.contains_key(id),
            "Transcript persistence is recovering"
        );
        ensure!(
            behavior != Behavior::Steer
                || matches!(
                    expected["selection"]["provider"].as_str(),
                    Some("codex" | "opencode" | "claude")
                ),
            "This provider does not support native steering yet"
        );
        let thread = self.store.choose_follow_up(expected, behavior)?;
        self.revision += 1;
        Ok(thread)
    }
    /// Actual run readiness, not saved metadata, selects the native send glyph.
    pub fn native_follow_up_dispatch(&self, thread: &Value, alternate: bool) -> Result<Dispatch> {
        let settings = self
            .store
            .document("settings.json")?
            .unwrap_or_else(|| json!({}));
        let run = self.runs.get(required(thread, "id")?);
        let supports = matches!(
            thread["selection"]["provider"].as_str(),
            Some("codex" | "opencode" | "claude")
        );
        let behavior = choice::effective(choice::selected(thread, &settings), supports);
        let ready = run.is_some_and(|run| {
            !run.cancelled
                && run.persistence_error.is_none()
                && thread["interactionMode"]
                    .as_str()
                    .is_none_or(|mode| mode == "build")
                && (matches!(run.provider.as_str(), "opencode" | "claude")
                    || run.session.can_steer())
        });
        let approval = run.is_some_and(|run| {
            run.pending
                .values()
                .any(|frame| frame["method"] != "item/tool/requestUserInput")
        });
        if run.is_some()
            && thread["selection"]["provider"] == "codex"
            && agent::codex_goals::parse(thread["draft"].as_str().unwrap_or("")).is_some()
            && thread["rustDraftImages"]
                .as_array()
                .is_none_or(Vec::is_empty)
            && !crate::composer_context::has_context(&thread["draftContext"])
        {
            return Ok(Dispatch::Steer);
        }
        if run.is_some()
            && matches!(
                thread["selection"]["provider"].as_str(),
                Some("codex" | "opencode")
            )
            && agent::codex_compact_command(thread["draft"].as_str().unwrap_or(""))
            && thread["rustDraftImages"]
                .as_array()
                .is_none_or(Vec::is_empty)
            && !crate::composer_context::has_context(&thread["draftContext"])
        {
            return Ok(Dispatch::Queue);
        }
        Ok(choice::resolve(run.is_some(), ready, alternate, behavior, approval).0)
    }
    pub fn send_native_follow_up(
        &mut self,
        expected: &Value,
        alternate: bool,
    ) -> Result<NativeFollowUpTicket> {
        self.begin_native_follow_up(expected, alternate, &mut None, None)
    }
    fn begin_native_follow_up(
        &mut self,
        expected: &Value,
        alternate: bool,
        queue: &mut Option<super::queue_dispatch::QueueClaim>,
        queued_behavior: Option<Behavior>,
    ) -> Result<NativeFollowUpTicket> {
        self.require_admissions()?;
        ensure!(!self.shutdown, "Application is closing");
        let id = required(expected, "id")?.to_owned();
        ensure!(
            self.active_thread.as_deref() == Some(id.as_str()),
            "Composer is no longer active"
        );
        ensure!(
            self.native_follow_up.operations.len() < 32
                && !self.native_follow_up.pending_thread(&id),
            "Collect the previous follow-up before sending again"
        );
        ensure!(
            !self.unsaved_threads.contains_key(&id),
            "Transcript persistence is recovering"
        );
        let (current, draft_revision) = self.store.thread_with_draft_revision(&id)?;
        ensure!(
            scope(&current) == scope(expected),
            "Composer changed; draft retained"
        );
        self.require_provider_enabled(&text(&current["selection"], "provider"))?;
        ensure!(
            !self.store.is_imported(&id)? && current["isArchived"] != true,
            "Fork or restore this conversation before sending"
        );
        ensure!(
            serde_json::to_vec(&scope(&current))?.len() <= 2 * 1024 * 1024,
            "Composer scope exceeds safe follow-up limit"
        );
        let is_queue = queue.is_some();
        let text = if let Some(claim) = queue.as_ref() {
            claim.validate(self.thread_bulk_owner, &id, claim.text(), &current)?;
            claim.text().to_owned()
        } else {
            required(&current, "draft")?.to_owned()
        };
        ensure!(
            text.len() <= 1024 * 1024
                && (!text.trim().is_empty()
                    || (!is_queue
                        && (crate::composer_context::has_context(&current["draftContext"])
                            || current["rustDraftImages"]
                                .as_array()
                                .is_some_and(|images| !images.is_empty())))
                    || queue
                        .as_ref()
                        .is_some_and(|claim| crate::composer_context::has_context(
                            claim.context()
                        ) || !claim.images().is_empty())),
            "Add text, images or references; text must fit within 1 MiB"
        );
        if !is_queue {
            ensure!(
                self.native_follow_up.blocked.get(&id)
                    != Some(&(scope(&current), draft_revision.clone())),
                "This message was already submitted; edit it before submitting again"
            );
            self.native_follow_up.blocked.remove(&id);
            let store = &self.store;
            self.native_follow_up.blocked.retain(|thread, submitted| {
                store
                    .thread_with_draft_revision(thread)
                    .is_ok_and(|(value, revision)| (scope(&value), revision) == *submitted)
            });
            ensure!(
                self.native_follow_up.blocked.len() < 32,
                "Edit or collect retained follow-up drafts before sending more"
            );
        }
        // Validate and prepare the exact payload before any Stop, denial or
        // transport submission. A saved path never grants arbitrary file IO.
        let context = queue.as_ref().map_or_else(
            || current["draftContext"].clone(),
            |claim| claim.context().clone(),
        );
        crate::composer_context::validate(&context)?;
        let images: Vec<crate::attachments::StoredImage> = if let Some(claim) = queue.as_ref() {
            claim.images().to_vec()
        } else if current["rustDraftImages"].is_null() {
            Vec::new()
        } else {
            serde_json::from_value(current["rustDraftImages"].clone())
                .context("Invalid follow-up images")?
        };
        ensure!(
            images.len() <= 20
                && images
                    .iter()
                    .try_fold(0u64, |total, image| total.checked_add(image.byte_len))
                    .is_some_and(|bytes| bytes <= 20 * 1024 * 1024),
            "Follow-up images exceed safe limits"
        );
        let data = self.store.data_directory()?;
        let prepared = images
            .iter()
            .map(|image| image.prepare_in(&data))
            .collect::<Result<Vec<_>>>()?;
        agent::validate_images(
            &Provider::from_name(&crate::store::text(&current["selection"], "provider"))?,
            &prepared,
        )?;
        let run = self
            .runs
            .get(&id)
            .context("A native follow-up requires a running turn")?;
        ensure!(
            !run.cancelled && run.persistence_error.is_none(),
            "Turn is stopping or persistence is recovering"
        );
        ensure!(
            run.usage_context
                .as_ref()
                .is_some_and(|context| context.matches(&current)),
            "Stored selection or project differs from the running turn"
        );
        if !is_queue {
            crate::composer_context::validate(&current["draftContext"])?;
            ensure!(
                !self.attachment_operations.iter().any(|operation| self
                    .workspace_pending
                    .get(operation)
                    .is_some_and(|(owner, _)| owner == &id)),
                "Wait for image imports to finish before sending a follow-up"
            );
        }
        self.validate_native_follow_up_policy(&current)?;
        let cwd = self.working_directory(&current)?;
        let bot_instructions = self.bot_instructions(&current, &cwd)?;
        let settings = self
            .store
            .document("settings.json")?
            .unwrap_or_else(|| json!({}));
        let supports_steering = matches!(run.provider.as_str(), "codex" | "opencode" | "claude");
        let behavior = choice::effective(choice::selected(&current, &settings), supports_steering);
        let can_steer = supports_steering
            && current["interactionMode"]
                .as_str()
                .is_none_or(|mode| mode == "build")
            && (matches!(run.provider.as_str(), "opencode" | "claude") || run.session.can_steer());
        let approval = run
            .pending
            .values()
            .any(|frame| frame["method"] != "item/tool/requestUserInput");
        let (mut dispatch, _) = if let Some(behavior) = queued_behavior.filter(|_| is_queue) {
            choice::resolve(true, can_steer, false, behavior, approval)
        } else if is_queue {
            (
                if can_steer {
                    Dispatch::Steer
                } else {
                    Dispatch::Interrupt
                },
                true,
            )
        } else {
            choice::resolve(true, can_steer, alternate, behavior, approval)
        };
        let goal_control = run.provider == "codex"
            && images.is_empty()
            && !crate::composer_context::has_context(&context)
            && bot_instructions.is_none()
            && agent::codex_goals::parse(&text).is_some();
        if goal_control {
            // Goal controls target the live provider thread immediately; they
            // neither steal queued messages nor answer unrelated approvals.
            dispatch = Dispatch::Steer;
        }
        if matches!(run.provider.as_str(), "codex" | "opencode")
            && agent::codex_compact_command(&text)
            && images.is_empty()
            && !crate::composer_context::has_context(&context)
        {
            dispatch = Dispatch::Queue;
        }
        // These active-turn channels currently carry text, not image payloads.
        // Preserve images by sending this follow-up after the running turn.
        if dispatch == Dispatch::Steer
            && matches!(run.provider.as_str(), "opencode" | "claude")
            && !images.is_empty()
        {
            dispatch = Dispatch::Queue;
        }
        let worker = run.session.worker_completion();
        let prefix = if dispatch == Dispatch::Interrupt || (dispatch == Dispatch::Queue && is_queue)
        {
            Some(PrefixProof::capture(
                current["items"].as_array().context("Missing transcript")?,
                run.transcript_start,
            )?)
        } else {
            None
        };
        // Validate every denial before replying to any pending request. Never
        // grant an approval, invent a question answer, or use stale UI request IDs.
        let mut denials = Vec::new();
        ensure!(
            run.pending.len() <= 64,
            "Too many pending requests; respond explicitly first"
        );
        for (key, frame) in run
            .pending
            .iter()
            .filter(|_| dispatch != Dispatch::Queue && !goal_control)
        {
            let result = if frame["method"] == "item/tool/requestUserInput" {
                json!({"answers":{}})
            } else {
                let offered = frame["params"]["availableDecisions"].as_array();
                let decision = ["decline", "cancel"]
                    .into_iter()
                    .find(|decision| offered.is_none_or(|values| values.contains(&json!(decision))))
                    .context("Agent offers no safe decline; respond explicitly first")?;
                json!({"decision":decision})
            };
            denials.push((key.clone(), frame["id"].clone(), result));
        }
        for (key, request, result) in denials {
            let run = self
                .runs
                .get_mut(&id)
                .context("Turn stopped before redirect")?;
            run.session.reply(request, result)?;
            run.pending.remove(&key);
            self.notification_events.cancel_request(&id, &key);
        }
        let mut op = Operation {
            thread: id.clone(),
            source: scope(&current),
            draft_revision: draft_revision.clone(),
            prefix,
            text: text.clone(),
            dispatch,
            delivery: None,
            status: NativeFollowUpStatus::Pending,
            queue: queue.take(),
        };
        match dispatch {
            Dispatch::Steer => {
                if goal_control {
                    let reply = self
                        .runs
                        .get(&id)
                        .context("Thread is not running")?
                        .session
                        .begin_steer_text(&text)?;
                    op.delivery = Some(Delivery::TextSteer {
                        provider: "codex".into(),
                        reply,
                        accepted: false,
                        started: Instant::now(),
                        timeout: Duration::from_secs(30),
                        item_id: Uuid::new_v4().to_string(),
                        context,
                    });
                } else if self
                    .runs
                    .get(&id)
                    .is_some_and(|run| matches!(run.provider.as_str(), "opencode" | "claude"))
                {
                    let runtime_text = crate::composer_context::prompt(&text, &context)?;
                    let reply = self
                        .runs
                        .get(&id)
                        .context("Thread is not running")?
                        .session
                        .begin_steer_text(&runtime_text)?;
                    let provider = self
                        .runs
                        .get(&id)
                        .context("Thread is not running")?
                        .provider
                        .clone();
                    op.delivery = Some(Delivery::TextSteer {
                        timeout: text_steer_timeout(&provider),
                        provider,
                        reply,
                        accepted: false,
                        started: Instant::now(),
                        item_id: Uuid::new_v4().to_string(),
                        context,
                    });
                } else {
                    let result = if let Some(claim) = &op.queue {
                        self.steer_owned_queue(&id, claim)?
                    } else {
                        self.steer_native_composer(&current)?
                    };
                    op.delivery =
                        Some(Delivery::Steering(required(&result, "operationId")?.into()));
                }
            }
            Dispatch::Interrupt => {
                self.request_provider_stop(&id)?;
                op.delivery = Some(Delivery::Deferred(worker));
            }
            // A queued Send Now already owns a durable row. An ordinary
            // follow-up that cannot steer yet must first become a durable row,
            // so the user can safely start another draft while the turn runs.
            Dispatch::Queue if is_queue => {
                op.delivery = Some(Delivery::Deferred(worker));
            }
            Dispatch::Queue => {
                let enabled = self.store.queue_native_follow_up(
                    &current,
                    &text,
                    self.enabled_queues.contains(&id),
                )?;
                if enabled {
                    self.enabled_queues.insert(id.clone());
                }
                self.sync_goal_queue_waiting(&id);
                op.status = NativeFollowUpStatus::Delivered {
                    dispatch,
                    draft_cleared: true,
                };
            }
            Dispatch::Send => unreachable!(),
        }
        let ticket = NativeFollowUpTicket {
            owner: self.native_follow_up.owner,
            id: Uuid::new_v4(),
        };
        if !is_queue
            && !matches!(
                op.status,
                NativeFollowUpStatus::Delivered {
                    draft_cleared: true,
                    ..
                }
            )
        {
            self.native_follow_up
                .blocked
                .insert(id, (scope(&current), draft_revision));
        }
        self.native_follow_up.operations.insert(ticket.id, op);
        self.revision += 1;
        Ok(ticket)
    }
    pub fn native_follow_up_status(
        &self,
        ticket: &NativeFollowUpTicket,
    ) -> Result<NativeFollowUpStatus> {
        ensure!(
            ticket.owner == self.native_follow_up.owner,
            "Follow-up belongs to another Engine"
        );
        Ok(self
            .native_follow_up
            .operations
            .get(&ticket.id)
            .context("Unknown follow-up")?
            .status
            .clone())
    }
    pub fn collect_native_follow_up(&mut self, ticket: NativeFollowUpTicket) -> Result<()> {
        ensure!(
            ticket.owner == self.native_follow_up.owner,
            "Follow-up belongs to another Engine"
        );
        ensure!(
            self.native_follow_up
                .operations
                .get(&ticket.id)
                .is_some_and(|op| op.status != NativeFollowUpStatus::Pending),
            "Follow-up still owns pending delivery"
        );
        self.native_follow_up.operations.remove(&ticket.id);
        Ok(())
    }
    pub(super) fn poll_native_follow_ups(&mut self) {
        let mut operations = std::mem::take(&mut self.native_follow_up.operations);
        for op in operations
            .values_mut()
            .filter(|op| op.status == NativeFollowUpStatus::Pending)
        {
            let result = (|| -> Result<Option<bool>> {
                ensure!(
                    !self.admissions_frozen() && !self.shutdown,
                    "Application is closing; draft retained"
                );
                match op.delivery.as_mut().context("Missing follow-up delivery")? {
                    Delivery::Steering(operation) => {
                        let result = self.steer_command(
                            "agent.steer.result",
                            &json!({"threadId":op.thread,"operationId":operation}),
                        )?;
                        match result["status"].as_str() {
                            Some("pending" | "accepted_pending_persistence") => Ok(None),
                            Some("accepted") => {
                                if let Some(claim) = &op.queue {
                                    self.complete_native_queue_steer(claim)?;
                                    Ok(Some(false))
                                } else {
                                    Ok(Some(self.store.clear_native_follow_up_draft(
                                        &op.source,
                                        op.draft_revision.as_deref(),
                                    )?))
                                }
                            }
                            Some("rejected") if op.queue.is_some() => {
                                self.fail_queue_claim(
                                    op.queue.as_ref().unwrap(),
                                    "Queued steering was rejected",
                                )?;
                                bail!(
                                    "Queued steering was rejected; message and separate draft retained"
                                )
                            }
                            _ => bail!(
                                "Steering was rejected or delivery is unknown; draft retained"
                            ),
                        }
                    }
                    Delivery::TextSteer {
                        provider,
                        reply,
                        accepted,
                        started,
                        timeout,
                        item_id,
                        context,
                    } => {
                        if !*accepted {
                            match reply.try_recv() {
                                Ok(Ok(())) => *accepted = true,
                                Ok(Err(error)) => {
                                    if let Some(claim) = &op.queue {
                                        self.fail_queue_claim(
                                            claim,
                                            &format!("{provider} rejected the message: {error}"),
                                        )?;
                                    }
                                    bail!("{provider} rejected the message: {error}")
                                }
                                Err(std::sync::mpsc::TryRecvError::Empty)
                                    if started.elapsed() < *timeout =>
                                {
                                    return Ok(None);
                                }
                                Err(_) => bail!(
                                    "{provider} delivery is unknown; do not resend automatically"
                                ),
                            }
                        }
                        if let Err(error) = self
                            .persist_text_steer(&op.thread, item_id, &op.text, context, provider)
                        {
                            self.schedule_error = Some(format!(
                                "Accepted provider message could not be saved yet: {error}"
                            ));
                            return Ok(None);
                        }
                        if let Some(claim) = &op.queue {
                            self.complete_native_queue_steer(claim)?;
                            Ok(Some(false))
                        } else {
                            Ok(Some(self.store.clear_native_follow_up_draft(
                                &op.source,
                                op.draft_revision.as_deref(),
                            )?))
                        }
                    }
                    Delivery::Deferred(worker) => {
                        match worker.status() {
                            agent::WorkerThreadStatus::Running => return Ok(None),
                            agent::WorkerThreadStatus::Returned => {}
                            _ => bail!("Previous worker did not return cleanly; draft retained"),
                        }
                        if self.runs.contains_key(&op.thread)
                            || self.unsaved_threads.contains_key(&op.thread)
                        {
                            return Ok(None);
                        }
                        let current = self.store.thread(&op.thread)?;
                        if op.queue.is_none() {
                            ensure!(
                                scope(&current) == scope(&op.source),
                                "Composer changed while stopping; draft retained"
                            );
                        }
                        ensure!(
                            op.prefix
                                .as_ref()
                                .context("Missing conversation prefix proof")?
                                .matches(
                                    current["items"].as_array().context("Missing transcript")?
                                )?,
                            "Conversation prefix changed; draft retained"
                        );
                        if let Some(claim) = op.queue.as_ref() {
                            let claim = claim.rebound(self.thread_bulk_owner, &current)?;
                            let origin = SendOrigin::Queued(Box::new(claim));
                            self.send_turn_if_unchanged(
                                &json!({"threadId":op.thread,"text":op.text}),
                                &origin,
                                None,
                                op.dispatch == Dispatch::Interrupt,
                            )?;
                            return Ok(Some(false));
                        }
                        self.send_turn_if_unchanged(
                            &json!({"threadId":op.thread,"text":op.text}),
                            &SendOrigin::Ordinary,
                            Some(&op.source),
                            op.dispatch == Dispatch::Interrupt,
                        )?;
                        Ok(Some(true))
                    }
                }
            })();
            match result {
                Ok(Some(cleared)) => {
                    if cleared {
                        self.native_follow_up.blocked.remove(&op.thread);
                    }
                    op.delivery = None;
                    op.status = NativeFollowUpStatus::Delivered {
                        dispatch: op.dispatch,
                        draft_cleared: cleared,
                    };
                    self.revision += 1;
                }
                Ok(None) => {}
                Err(error) => {
                    if op.queue.is_some() {
                        self.enabled_queues.remove(&op.thread);
                    }
                    op.delivery = None;
                    op.status = NativeFollowUpStatus::Retained(error.to_string());
                    self.revision += 1;
                }
            }
        }
        self.native_follow_up.operations = operations;
    }
}

#[cfg(test)]
#[path = "follow_up_api_tests.rs"]
mod tests;

#[path = "queue_send_now_api.rs"]
mod queue_send_now_api;
