//! Native Send now operates on one exact visible queued entry, independently
//! of its unrelated composer. There is deliberately no JSON dispatch route.
use super::*;
impl Engine {
    pub fn native_send_queued_now(
        &mut self,
        expected: &Value,
        visible: &Value,
    ) -> Result<NativeFollowUpTicket> {
        let behavior = visible["codexQuestionSession"]
            .is_string()
            .then_some(Behavior::Steer);
        self.native_send_queued_with_behavior(expected, visible, behavior)
    }
    pub fn native_interrupt_and_send_queued(
        &mut self,
        expected: &Value,
        visible: &Value,
    ) -> Result<NativeFollowUpTicket> {
        ensure!(
            visible["codexQuestionSession"].is_null(),
            "A provider answer must stay in its current turn"
        );
        self.native_send_queued_with_behavior(expected, visible, Some(Behavior::Interrupt))
    }

    pub fn native_stop_unaccepted_queued_turn(
        &mut self,
        thread: &str,
        message: &str,
    ) -> Result<()> {
        self.require_admissions()?;
        ensure!(
            self.runs
                .get(thread)
                .and_then(|run| run.queue_claim.as_deref())
                == Some(message),
            "This message is no longer waiting for a new turn to accept it"
        );
        self.request_provider_stop(thread)
    }

    pub(in crate::api) fn native_send_queued_with_behavior(
        &mut self,
        expected: &Value,
        visible: &Value,
        behavior: Option<Behavior>,
    ) -> Result<NativeFollowUpTicket> {
        self.require_admissions()?;
        let id = required(expected, "id")?.to_owned();
        if visible["codexQuestionSession"].is_string() {
            ensure!(
                self.runs.get(&id).is_none_or(|run| run.pending.is_empty()),
                "Respond to the pending provider request before sending the answer"
            );
        }
        let mut claim = Some(self.claim_native_queue_now(expected, visible)?);
        let source = claim.as_ref().unwrap().captured_scope();
        if self.runs.contains_key(&id) {
            let result = self.begin_native_follow_up(&source, false, &mut claim, behavior);
            if result.is_err() {
                if let Some(claim) = claim.as_ref() {
                    self.fail_queue_claim(claim, "Send now admission was refused")?;
                }
                self.enabled_queues.remove(&id);
            }
            return result;
        }
        let claim = claim.take().unwrap();
        let origin = SendOrigin::Queued(Box::new(claim));
        let text = visible["text"]
            .as_str()
            .context("Queued text is missing")?
            .to_owned();
        let result =
            self.send_turn_if_unchanged(&json!({"threadId":id,"text":text}), &origin, None, false);
        if let Err(error) = result {
            if let SendOrigin::Queued(claim) = &origin {
                self.fail_queue_claim(claim, &error.to_string())?;
            }
            self.enabled_queues.remove(&id);
            return Err(error);
        }
        let ticket = NativeFollowUpTicket {
            owner: self.native_follow_up.owner,
            id: Uuid::new_v4(),
        };
        self.native_follow_up.operations.insert(
            ticket.id,
            Operation {
                thread: id,
                source,
                draft_revision: None,
                prefix: None,
                text,
                dispatch: Dispatch::Send,
                delivery: None,
                status: NativeFollowUpStatus::Delivered {
                    dispatch: Dispatch::Send,
                    draft_cleared: false,
                },
                queue: None,
            },
        );
        Ok(ticket)
    }
}
