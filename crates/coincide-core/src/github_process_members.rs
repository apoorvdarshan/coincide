//! Process-owned receipts survive every cleanup attempt, including native errors.
use super::process_custody::{self, Membership, OpenFailure};
use std::collections::HashSet;

pub(super) struct Members<H> {
    pub held: Vec<(u32, H)>,
    pub unopened: HashSet<u32>,
    pub unverified: HashSet<u32>,
    pub unobserved: bool,
}
impl<H> Default for Members<H> {
    fn default() -> Self {
        Self {
            held: Vec::new(),
            unopened: HashSet::new(),
            unverified: HashSet::new(),
            unobserved: false,
        }
    }
}
impl<H> Members<H> {
    pub fn snapshot_failed(&mut self) {
        self.unobserved = true;
    }
    pub fn pending(&self, mut listed: Vec<u32>) -> Vec<u32> {
        listed.extend(self.unopened.iter().copied());
        listed.extend(self.unverified.iter().copied());
        let mut seen = HashSet::new();
        listed.retain(|id| seen.insert(*id));
        listed
    }
    pub fn open_failed(&mut self, id: u32, error: u32) {
        match process_custody::open_failure(id, error) {
            OpenFailure::Gone => {
                self.unopened.remove(&id);
            }
            OpenFailure::Unconfirmed => {
                self.unopened.insert(id);
            }
        }
    }
    pub fn opened(&mut self, id: u32, handle: H) -> usize {
        self.held.push((id, handle));
        self.unopened.remove(&id);
        self.unverified.insert(id);
        self.held.len() - 1
    }
    pub fn signaled(&mut self, index: usize) {
        self.unverified.remove(&self.held[index].0);
    }
    pub fn queried(&mut self, index: usize, success: bool, ours: bool) {
        let id = self.held[index].0;
        match process_custody::membership(success, ours) {
            Membership::Ours => {
                self.unverified.remove(&id);
            }
            Membership::Replaced => {
                self.held.remove(index);
                self.unverified.remove(&id);
            }
            Membership::Unconfirmed => {
                self.unverified.insert(id);
            }
        }
    }
    /// This only admits the actual handle waits; it is not a release receipt.
    pub fn may_wait_for_release(&self, active: u32) -> bool {
        process_custody::may_finish(
            active,
            self.unopened.len(),
            self.unverified.len(),
            self.unobserved,
        )
    }
}

/// Assignment is attempted only after child + Job are in one owner. A failed
/// assignment must retain that owner through every unconfirmed cleanup attempt.
pub(super) fn assign_or_retain<O>(
    mut owner: O,
    assign: impl FnOnce(&mut O) -> bool,
    mut drained: impl FnMut(&mut O) -> bool,
) -> Option<O> {
    if assign(&mut owner) {
        return Some(owner);
    }
    while !drained(&mut owner) {
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    struct Handle(Arc<AtomicUsize>);
    impl Drop for Handle {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }
    #[test]
    fn failed_assignment_and_wait_error_keep_the_same_child_and_job_owned() {
        let released = Arc::new(AtomicUsize::new(0));
        let owner = (Handle(released.clone()), Handle(released.clone()));
        let mut cleanup_attempts = 0;
        let result = assign_or_retain(
            owner,
            |_| false,
            |owner| {
                assert_eq!(
                    released.load(Ordering::SeqCst),
                    0,
                    "assignment failure cannot release either owner"
                );
                assert!(Arc::ptr_eq(&owner.0.0, &owner.1.0));
                cleanup_attempts += 1;
                cleanup_attempts > 1 // First owned-child wait reports an unconfirmed native error.
            },
        );
        assert!(result.is_none());
        assert_eq!(cleanup_attempts, 2);
        assert_eq!(
            released.load(Ordering::SeqCst),
            2,
            "release follows the verified retry only"
        );
    }
    #[test]
    fn lookup_and_membership_errors_retain_owner_across_empty_snapshots() {
        let released = Arc::new(AtomicUsize::new(0));
        let mut members = Members::default();
        members.open_failed(42, 5); // Access denied does not prove disappearance.
        assert_eq!(members.pending(Vec::new()), vec![42]);
        assert!(!members.may_wait_for_release(0));
        let index = members.opened(42, Handle(released.clone()));
        members.queried(index, false, false);
        assert_eq!(released.load(Ordering::SeqCst), 0);
        assert_eq!(members.pending(Vec::new()), vec![42]);
        assert!(!members.may_wait_for_release(0));
        members.signaled(index); // Only the native handle's signal supplies this receipt.
        assert!(members.may_wait_for_release(0));
        assert_eq!(
            released.load(Ordering::SeqCst),
            0,
            "handle remains owned through final waits"
        );
        drop(members);
        assert_eq!(released.load(Ordering::SeqCst), 1);
    }
    #[test]
    fn failed_snapshot_is_not_erased_by_later_empty_accounting_or_gone_pid() {
        let mut members = Members::<()>::default();
        members.open_failed(42, 8);
        members.snapshot_failed();
        members.open_failed(42, 87);
        assert!(members.pending(Vec::new()).is_empty());
        assert!(!members.may_wait_for_release(0));
    }
    #[test]
    fn successful_membership_receipt_is_distinct_from_unknown_and_live_accounting() {
        let mut members = Members::default();
        let index = members.opened(42, ());
        members.queried(index, true, true);
        assert!(!members.may_wait_for_release(1));
        assert!(members.may_wait_for_release(0));
        assert_eq!(members.held.len(), 1, "actual handle wait remains required");
        let other = members.opened(43, ());
        members.queried(other, true, false);
        assert_eq!(
            members.held.len(),
            1,
            "a confirmed different Job owner is a reused PID"
        );
    }
}
