#!/usr/bin/env python3
"""Opt-in fresh-runner SDK test; never uses a developer's OS credential store."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def run_fixture(binary: Path, root: Path) -> int:
    # Keep toolchain/build credentials out of the actual SDK test child.
    allowed = ["PATH", "SystemRoot", "WINDIR", "SYSTEMDRIVE", "COMSPEC", "LANG",
               "DBUS_SESSION_BUS_ADDRESS", "GNOME_KEYRING_CONTROL"]
    env = {key: os.environ[key] for key in allowed if key in os.environ}
    for key in ["HOME", "USERPROFILE", "TMPDIR", "TMP", "TEMP", "XDG_CONFIG_HOME",
                "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR", "APPDATA", "LOCALAPPDATA"]:
        path = root / key.lower()
        path.mkdir(mode=0o700, exist_ok=True)
        env[key] = str(path)
    env.update(GITHUB_ACTIONS="true", COINCIDE_NATIVE_SECRET_STORE_CI="owned-synthetic-entry-v1",
               COINCIDE_NATIVE_SECRET_STORE_FIXTURE=str(root))
    daemon = None
    log = None
    try:
        if sys.platform.startswith("linux"):
            # A private dbus-run-session is already owned by this driver. GNOME
            # --foreground + --unlock reads the synthetic password from stdin;
            # it neither adopts nor modifies a desktop/user keyring daemon.
            control = root / "owned-keyring-control"
            control.mkdir(mode=0o700)
            env["GNOME_KEYRING_CONTROL"] = str(control)
            log = (root / "owned-daemon.log").open("wb")
            daemon = subprocess.Popen(["gnome-keyring-daemon", "--foreground", "--unlock",
                                       "--components=secrets", f"--control-directory={control}"],
                                      env=env, stdin=subprocess.PIPE, stdout=log, stderr=log,
                                      start_new_session=True)
            daemon.stdin.write(b"coincide-synthetic-runner-keyring\n")
            daemon.stdin.close()
            deadline = time.monotonic() + 15
            while True:
                if daemon.poll() is not None:
                    raise RuntimeError("Owned synthetic Secret Service exited before readiness")
                probe = subprocess.run(["gdbus", "call", "--session", "--dest", "org.freedesktop.DBus",
                                        "--object-path", "/org/freedesktop/DBus", "--method",
                                        "org.freedesktop.DBus.NameHasOwner", "org.freedesktop.secrets"],
                                       env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=2)
                if probe.returncode == 0 and probe.stdout.strip() == b"(true,)":
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError("Owned synthetic Secret Service did not become ready")
                time.sleep(0.05)
        result = subprocess.run([str(binary), "--ignored", "--exact",
                                 "exact_owned_synthetic_entry_round_trip_and_confirmed_removal",
                                 "--nocapture", "--test-threads=1"], env=env, cwd=root,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=45)
        print(result.stdout, end="")
        if result.returncode != 0 or "1 passed; 0 failed; 0 ignored;" not in result.stdout:
            raise RuntimeError("Actual native SDK round trip was not confirmed")
        return 0
    finally:
        if daemon is not None:
            # Only this Popen's freshly created process group is targeted.
            if daemon.poll() is None:
                os.killpg(daemon.pid, signal.SIGTERM)
                try:
                    daemon.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(daemon.pid, signal.SIGKILL)
                    daemon.wait(timeout=5)
            else:
                daemon.wait()
        if log is not None:
            log.close()


def main() -> int:
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("This driver is restricted to fresh hosted runners")
    if len(sys.argv) == 4 and sys.argv[1] == "--inside-private-bus":
        return run_fixture(Path(sys.argv[2]), Path(sys.argv[3]))
    build = subprocess.run(["cargo", "test", "-p", "coincide-core", "--locked", "--test",
                            "native_account_secret_store", "--no-run", "--message-format=json"],
                           stdout=subprocess.PIPE, text=True, check=True)
    binaries = []
    for line in build.stdout.splitlines():
        message = json.loads(line)
        if message.get("reason") == "compiler-artifact" and message.get("target", {}).get("name") == "native_account_secret_store" and message.get("executable"):
            binaries.append(Path(message["executable"]).resolve())
    if len(binaries) != 1:
        raise RuntimeError("Expected exactly one compiled native SDK fixture executable")
    root = Path(tempfile.mkdtemp(prefix="coincide-native-secret-store-", dir=os.environ["RUNNER_TEMP"]))
    try:
        if sys.platform.startswith("linux"):
            # Do not inherit a host Secret Service or reuse a desktop bus.
            env = os.environ.copy()
            env.pop("DBUS_SESSION_BUS_ADDRESS", None)
            subprocess.run(["dbus-run-session", "--", sys.executable, str(Path(__file__).resolve()),
                            "--inside-private-bus", str(binaries[0]), str(root)],
                           env=env, check=True, timeout=90)
        else:
            run_fixture(binaries[0], root)
    except BaseException:
        print(f"Failed synthetic fixture retained at {root}", file=sys.stderr)
        raise
    else:
        shutil.rmtree(root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
