//! Portable interpretation of native process lookup outcomes. A disappearing
//! member and an unconfirmed native query are deliberately different states.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum OpenFailure {
    Gone,
    Unconfirmed,
}
pub(crate) fn open_failure(pid: u32, error: u32) -> OpenFailure {
    // Fixed valid access rights and inherit=false are used by the native call.
    // PID zero is special (System Idle), never evidence of disappearance.
    if pid != 0 && error == 87 {
        OpenFailure::Gone
    } else {
        OpenFailure::Unconfirmed
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Membership {
    Ours,
    Replaced,
    Unconfirmed,
}
pub(crate) fn membership(success: bool, ours: bool) -> Membership {
    if !success {
        Membership::Unconfirmed
    } else if ours {
        Membership::Ours
    } else {
        Membership::Replaced
    }
}
pub(crate) fn may_finish(
    active: u32,
    unopened: usize,
    unverified: usize,
    unobserved: bool,
) -> bool {
    active == 0 && unopened == 0 && unverified == 0 && !unobserved
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_a_proven_disappeared_nonzero_pid_may_be_skipped() {
        assert_eq!(open_failure(42, 87), OpenFailure::Gone);
        for error in [0, 5, 6, 8, 14, 31, 1450] {
            assert_eq!(open_failure(42, error), OpenFailure::Unconfirmed);
        }
        assert_eq!(open_failure(0, 87), OpenFailure::Unconfirmed);
    }
    #[test]
    fn membership_query_failure_is_not_a_negative_membership_receipt() {
        assert_eq!(membership(false, false), Membership::Unconfirmed);
        assert_eq!(membership(false, true), Membership::Unconfirmed);
        assert_eq!(membership(true, true), Membership::Ours);
        assert_eq!(membership(true, false), Membership::Replaced);
    }
    #[test]
    fn empty_job_count_does_not_clear_unconfirmed_native_custody() {
        assert!(may_finish(0, 0, 0, false));
        assert!(!may_finish(1, 0, 0, false));
        assert!(!may_finish(0, 1, 0, false));
        assert!(!may_finish(0, 0, 1, false));
        assert!(!may_finish(0, 0, 0, true));
    }
}
