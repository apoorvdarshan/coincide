//! Native Send now operates on one exact visible queued entry, independently
//! of its unrelated composer. There is deliberately no JSON dispatch route.
use super::*;
impl Engine {
    pub fn native_send_queued_now(
        &mut self,
        expected: &Value,
        visible: &Value,
    ) -> Result<NativeFollowUpTicket> {
        self.require_admissions()?;
        let id = required(expected, "id")?.to_owned();
        let mut claim = Some(self.claim_native_queue_now(expected, visible)?);
        let current = self.store.thread(&id)?;
        if self.runs.contains_key(&id) {
            let result = self.begin_native_follow_up(&current, false, &mut claim);
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
                source: scope(&current),
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
