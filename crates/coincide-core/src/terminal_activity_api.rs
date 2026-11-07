//! What still runs in the app's terminals, for Quit's confirmation.
use super::*;

impl Engine {
    /// Terminals whose foreground is a command rather than the shell
    /// (Swift `TerminalSessionManager.busySessionCount`).
    pub fn busy_terminal_count(&self) -> usize {
        self.terminals
            .values()
            .filter(|(_, terminal)| terminal.is_busy())
            .count()
    }
}
