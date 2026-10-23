"""Signal/EOF lifecycle coverage without launching a provider, account or GUI."""
import ast
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import unittest


class RemoteProviderLifecycleTests(unittest.TestCase):
    def exercise(self, ordering):
        source = Path(__file__).resolve().parents[2] / "Tests/CoincideCoreTests/Fixtures/remote_environment_provider.py"
        tree = ast.parse(source.read_text())
        functions = "\n\n".join(ast.unparse(node) for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name in ("record_exit", "terminated"))
        # Execute the fixture's actual lifecycle functions. Only its output sink
        # is controlled: pause precisely before publication so EOF/SIGTERM can
        # overlap without relying on scheduler timing or sleep/retry loops.
        code = """import json,signal,sys
exit_recorded=False
def record(kind, **fields):
    print(json.dumps(dict(stage='inside-record', termBlocked=signal.SIGTERM in signal.pthread_sigmask(signal.SIG_BLOCK,set()))), flush=True)
    sys.stdin.buffer.read(1)
    print(json.dumps(dict(kind=kind, **fields)), flush=True)
""" + functions + """
signal.signal(signal.SIGTERM,terminated)
if sys.argv[1]=='eof-first':
    record_exit('stdin-eof')
else:
    print(json.dumps(dict(stage='ready')),flush=True)
    try:
        signal.pause()
    finally:
        record_exit('stdin-eof')
"""
        child = subprocess.Popen([sys.executable, "-I", "-S", "-c", code, ordering],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            def next_stage():
                ready, _, _ = select.select([child.stdout], [], [], 3)
                self.assertTrue(ready, "The controlled lifecycle stage was not reached")
                return json.loads(child.stdout.readline())

            if ordering == "term-first":
                self.assertEqual(next_stage(), dict(stage="ready"))
                os.kill(child.pid, signal.SIGTERM)
            entered = next_stage()
            self.assertEqual(entered["stage"], "inside-record")
            os.kill(child.pid, signal.SIGTERM)
            if not entered["termBlocked"]:
                # The former flag-before-write bug exits here, before the sink
                # is released, deterministically losing its exit evidence.
                child.wait(timeout=3)
            child.stdin.close()
            child.stdin = None
            output, errors = child.communicate(timeout=3)
            self.assertEqual(child.returncode, 0)
            self.assertEqual(errors, b"")
            rows = [json.loads(line) for line in output.splitlines()]
            expected_reason = "stdin-eof" if ordering == "eof-first" else "owned-signal"
            self.assertEqual(rows, [dict(kind="exit", reason=expected_reason)])
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=3)
            for stream in [child.stdin, child.stdout, child.stderr]:
                if stream is not None:
                    stream.close()

    def test_eof_publication_survives_term_before_its_exit_row_is_written(self):
        self.exercise("eof-first")

    def test_term_publication_is_recorded_once_when_eof_and_another_term_arrive(self):
        self.exercise("term-first")


if __name__ == "__main__":
    unittest.main()
