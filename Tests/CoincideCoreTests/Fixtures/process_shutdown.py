"""Task-owned termination gate; never reads a project or launches children."""
import os
from pathlib import Path
import signal
import sys
import time

root = Path(sys.argv[1])

def terminate(_signal, _frame):
    (root / "terminating").write_text("ready")
    while not (root / "release").exists():
        time.sleep(0.005)
    sys.exit(0)

signal.signal(signal.SIGTERM, terminate)
(root / "pid").write_text(str(os.getpid()))
while True:
    signal.pause()
