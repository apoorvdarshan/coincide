//! The persisted composer choice is preference, never provider authority.
use serde_json::Value;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Behavior {
    Steer,
    Queue,
    Interrupt,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dispatch {
    Send,
    Steer,
    Queue,
    Interrupt,
}
impl Behavior {
    pub fn parse(value: &Value) -> Option<Self> {
        match value.as_str()? {
            "steer" => Some(Self::Steer),
            "queue" => Some(Self::Queue),
            "interrupt" => Some(Self::Interrupt),
            _ => None,
        }
    }
    pub fn key(self) -> &'static str {
        match self {
            Self::Steer => "steer",
            Self::Queue => "queue",
            Self::Interrupt => "interrupt",
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Steer => "Steer",
            Self::Queue => "Queue",
            Self::Interrupt => "Interrupt",
        }
    }
    pub fn opposite(self) -> Self {
        match self {
            Self::Steer => Self::Queue,
            Self::Queue => Self::Steer,
            Self::Interrupt => Self::Queue,
        }
    }
}
pub fn selected(thread: &Value, settings: &Value) -> Behavior {
    Behavior::parse(&thread["followUpBehavior"])
        .or_else(|| Behavior::parse(&settings["existingThreadsFollowUpBehavior"]))
        .or_else(|| Behavior::parse(&settings["followUpBehavior"]))
        .unwrap_or(Behavior::Steer)
}
pub fn effective(behavior: Behavior, supports_steering: bool) -> Behavior {
    if behavior == Behavior::Steer && !supports_steering {
        Behavior::Queue
    } else {
        behavior
    }
}
pub fn resolve(
    running: bool,
    can_steer: bool,
    alternate: bool,
    behavior: Behavior,
    approval_shown: bool,
) -> (Dispatch, bool) {
    if !running {
        return (Dispatch::Send, false);
    }
    let behavior = if approval_shown {
        Behavior::Steer
    } else {
        behavior
    };
    let chosen = if alternate {
        behavior.opposite()
    } else {
        behavior
    };
    (
        match chosen {
            Behavior::Steer if can_steer => Dispatch::Steer,
            Behavior::Steer | Behavior::Queue => Dispatch::Queue,
            Behavior::Interrupt => Dispatch::Interrupt,
        },
        chosen == Behavior::Steer,
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn swift_dispatch_truth_table_preserves_approval_and_alternate_priority() {
        for behavior in [Behavior::Steer, Behavior::Queue, Behavior::Interrupt] {
            for alternate in [false, true] {
                assert_eq!(
                    resolve(false, true, alternate, behavior, true),
                    (Dispatch::Send, false)
                );
                assert_eq!(
                    resolve(true, true, alternate, behavior, true),
                    if alternate {
                        (Dispatch::Queue, false)
                    } else {
                        (Dispatch::Steer, true)
                    }
                );
            }
        }
        assert_eq!(
            resolve(true, false, false, Behavior::Steer, false),
            (Dispatch::Queue, true)
        );
        assert_eq!(
            resolve(true, true, true, Behavior::Queue, false),
            (Dispatch::Steer, true)
        );
        assert_eq!(
            resolve(true, true, true, Behavior::Interrupt, false),
            (Dispatch::Queue, false)
        );
        assert_eq!(effective(Behavior::Steer, false), Behavior::Queue);
    }
}

pub(crate) fn scope(thread: &Value) -> Value {
    Value::Object(
        [
            "id",
            "draft",
            "selection",
            "accessMode",
            "interactionMode",
            "projectID",
            "projectPath",
            "worktreePath",
            "botID",
            "rustBotContext",
            "rustDraftImages",
            "draftContext",
        ]
        .into_iter()
        .filter_map(|key| thread.get(key).map(|value| (key.into(), value.clone())))
        .collect(),
    )
}
