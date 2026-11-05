//! Portable host policy. No registration, process launch, power mutation or data writes.
//! Native adapters must report verified capabilities; a plan is not a running host.
pub mod notifications;
pub mod power;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Registration {
    NotRegistered,
    Enabled,
    RequiresApproval,
    NotFound,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fallback {
    TurnedOff,
    DevelopmentBuild,
    UnsignedBuild,
    NeedsApproval,
    Unsupported,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostPlan {
    Connect,
    RegisterThenConnect,
    RunInApp(Fallback),
}

/// Mirrors AgentHostPlan.decide. `supported` means a native adapter exists, not
/// merely that this OS can run background processes. Preview callers pass false.
pub fn host_plan(
    enabled: bool,
    development: bool,
    opt_in: bool,
    signed_team: Option<&str>,
    supported: bool,
    status: Registration,
) -> HostPlan {
    if !enabled {
        return HostPlan::RunInApp(Fallback::TurnedOff);
    }
    if development && !opt_in {
        return HostPlan::RunInApp(Fallback::DevelopmentBuild);
    }
    if !supported {
        return HostPlan::RunInApp(Fallback::Unsupported);
    }
    if signed_team.is_none_or(|s| s.trim().is_empty()) {
        return HostPlan::RunInApp(Fallback::UnsignedBuild);
    }
    match status {
        Registration::Enabled => HostPlan::Connect,
        Registration::NotRegistered | Registration::NotFound => HostPlan::RegisterThenConnect,
        // Never override the user's OS-level background-service decision.
        Registration::RequiresApproval => HostPlan::RunInApp(Fallback::NeedsApproval),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn registration_respects_user_and_capability() {
        assert_eq!(
            host_plan(
                true,
                false,
                false,
                Some("TEAM"),
                false,
                Registration::Enabled
            ),
            HostPlan::RunInApp(Fallback::Unsupported)
        );
        assert_eq!(
            host_plan(
                true,
                false,
                false,
                Some("TEAM"),
                true,
                Registration::RequiresApproval
            ),
            HostPlan::RunInApp(Fallback::NeedsApproval)
        );
        assert_eq!(
            host_plan(
                true,
                false,
                false,
                Some("TEAM"),
                true,
                Registration::NotFound
            ),
            HostPlan::RegisterThenConnect
        );
        assert_eq!(
            host_plan(true, true, false, Some("TEAM"), true, Registration::Enabled),
            HostPlan::RunInApp(Fallback::DevelopmentBuild)
        );
        assert_eq!(
            host_plan(true, false, false, None, true, Registration::Enabled),
            HostPlan::RunInApp(Fallback::UnsignedBuild)
        );
    }
}
