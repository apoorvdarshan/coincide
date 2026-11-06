#!/usr/bin/env python3
"""Real X11/software-Vulkan smoke. Run under dbus-run-session + xvfb-run.

This proves a rendered native window, keyboard-to-draft persistence, Settings
navigation and a normal Quit/reopen with a private Store. It does not prove
provider execution, all UI parity, Wayland or hardware-GPU rendering.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

from PIL import Image, ImageStat


def command(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True,
                          timeout=20, **kwargs).stdout.strip()


def wait_for(description, condition, timeout=25):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            value = condition()
            if value:
                return value
        except (OSError, ValueError, AssertionError, subprocess.CalledProcessError) as error:
            last = error
        time.sleep(0.15)
    raise AssertionError(f"Timed out: {description}; last error: {last}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    artifacts = args.artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    assert os.environ.get("DISPLAY"), "A real Xvfb X11 display is required"
    icds = sorted(Path("/usr/share/vulkan/icd.d").glob("*lvp*.json"))
    assert len(icds) == 1, f"Expected one Mesa lavapipe software ICD, found {len(icds)}"
    # Keep AF_UNIX paths short, independent of the runner workspace path.
    fixture = Path(tempfile.mkdtemp(prefix="coincide-ui-"))
    fixture.chmod(0o700)
    home, data, project = [fixture / name for name in ("home", "data", "project")]
    for directory in (home, data, project):
        directory.mkdir(mode=0o700)
    env = {key: os.environ[key] for key in
           ("DISPLAY", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR")
           if key in os.environ}
    env.update(PATH="/usr/bin:/bin", HOME=str(home), XDG_CONFIG_HOME=str(home / "config"),
               XDG_CACHE_HOME=str(home / "cache"), LANG="C.UTF-8", GDK_BACKEND="x11",
               COINCIDE_RUST_DATA_DIR=str(data), LIBGL_ALWAYS_SOFTWARE="1",
               VK_ICD_FILENAMES=str(icds[0]), GPUI_X11_SCALE_FACTOR="1")
    for provider in ("CODEX", "CLAUDE", "CURSOR", "GROK", "OPENCODE", "ANTIGRAVITY"):
        env[f"COINCIDE_{provider}_EXECUTABLE"] = str(fixture / "never-execute" / provider)
    report = {"scope": "Linux X11 native smoke; software Vulkan; no providers",
              "binarySha256": hashlib.file_digest(binary.open("rb"), "sha256").hexdigest(),
              "checks": []}
    process = None
    log = None

    def rpc(method, **params):
        with socket.socket(socket.AF_UNIX) as stream:
            stream.settimeout(5)
            stream.connect(str(data / "control.sock"))
            stream.sendall(json.dumps({"id": 1, "method": method, "params": params}).encode() + b"\n")
            response = stream.makefile("rb").readline(4 * 1024 * 1024 + 1)
        value = json.loads(response)
        assert "error" not in value, f"{method}: {value.get('error')}"
        return value["result"]

    def start(stage):
        nonlocal process, log
        log = (artifacts / f"{stage}-app.log").open("w")
        process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT)
        wait_for("live application control", lambda: process.poll() is None and rpc("app.status"))
        window = wait_for("visible Coincide X11 window", lambda: command(
            "xdotool", "search", "--all", "--onlyvisible", "--pid", str(process.pid),
            "--name", "^Coincide Rust Preview$", env=env).splitlines()[0])
        command("xdotool", "windowfocus", "--sync", window, env=env)
        return window

    def capture(window, stage, expected=None):
        path = artifacts / f"{stage}.png"
        command("import", "-window", window, str(path), env=env)
        with Image.open(path) as source:
            image = source.convert("RGB")
        assert image.width >= 800 and image.height >= 500, "Native window is too small"
        assert max(ImageStat.Stat(image).stddev) > 8, "Window has no meaningful rendered content"
        ocr_path, segmentation = path, "11"
        if stage == "command-palette":
            # The captured palette is visibly correct, but sparse whole-window
            # segmentation split its small text into unrelated character blobs.
            # Keep the full native image; OCR only its actual centered popup at
            # a readable scale and retain that derived diagnostic separately.
            left, right = max(0, image.width // 2 - 360), min(image.width, image.width // 2 + 360)
            crop = image.crop((left, 48, right, min(image.height, 250)))
            ocr_path = artifacts / f"{stage}-ocr-region.png"
            crop.resize((crop.width * 2, crop.height * 2), Image.Resampling.LANCZOS).save(ocr_path)
            segmentation = "6"
        text = command("tesseract", str(ocr_path), "stdout", "--psm", segmentation, env=env)
        (artifacts / f"{stage}.txt").write_text(text)
        if expected:
            assert expected.lower() in text.lower(), f"Expected rendered text {expected!r} in {stage}"
        return image

    def quit_normally():
        nonlocal process, log
        assert rpc("app.status")["running"] == [], "Smoke must never start a provider"
        command("xdotool", "key", "--clearmodifiers", "ctrl+q", env=env)
        assert process.wait(timeout=25) == 0, "Normal Quit must exit successfully"
        process = None
        log.close()
        log = None

    try:
        vulkan = command("vulkaninfo", "--summary", env=env)
        (artifacts / "software-vulkan.txt").write_text(vulkan)
        assert "llvmpipe" in vulkan.lower() or "lavapipe" in vulkan.lower(), "Software Vulkan was not selected"
        window = start("initial")
        created_project = rpc("projects.create", path=str(project), name="Native Linux smoke")
        thread = rpc("threads.create", projectId=created_project["id"])
        thread_id = thread["id"]
        rpc("threads.patch", threadId=thread_id, patch={"title": "Native Linux smoke"})
        rpc("threads.open", threadId=thread_id)
        wait_for("active native thread", lambda: rpc("app.status")["activeThread"] == thread_id)
        time.sleep(0.8)  # Allow the native UI timer to consume the open request.
        before = capture(window, "conversation", "Native Linux smoke")
        # Real X11 input into the production textarea; RPC reads only verify it.
        command("xdotool", "mousemove", "--window", window,
                str(before.width // 2), str(before.height - 115), "click", "1", env=env)
        draft = "Native X11 keyboard draft survives restart"
        command("xdotool", "type", "--clearmodifiers", "--delay", "15", draft, env=env)
        wait_for("native keyboard draft saved", lambda: rpc("threads.read", threadId=thread_id).get("draft") == draft)
        capture(window, "typed-draft", "keyboard draft")
        report["checks"].append("visible rendered native window and X11 keyboard draft persisted")
        command("xdotool", "key", "--clearmodifiers", "ctrl+k", env=env)
        command("xdotool", "type", "--clearmodifiers", "Open settings", env=env)
        time.sleep(0.5)
        capture(window, "command-palette", "Open settings")
        command("xdotool", "key", "Return", env=env)
        time.sleep(0.6)
        settings_window = wait_for("separate Settings window", lambda: command(
            "xdotool", "search", "--all", "--onlyvisible", "--pid", str(process.pid),
            "--name", "^General$", env=env).splitlines()[0])
        assert settings_window != window, "Settings must leave the conversation in its own window"
        capture(settings_window, "settings", "General")
        assert rpc("threads.read", threadId=thread_id)["draft"] == draft
        command("xdotool", "windowfocus", "--sync", window, env=env)
        command("xdotool", "key", "--clearmodifiers", "ctrl+comma", env=env)
        time.sleep(0.5)
        matches = command("xdotool", "search", "--all", "--onlyvisible", "--pid", str(process.pid),
                          "--name", "^General$", env=env).splitlines()
        assert matches == [settings_window], "Opening Settings again must reuse its existing window"
        command("xdotool", "windowfocus", "--sync", settings_window, env=env)
        command("xdotool", "key", "--clearmodifiers", "ctrl+w", env=env)
        def settings_closed():
            result = subprocess.run(["xdotool", "search", "--all", "--onlyvisible", "--pid", str(process.pid),
                                     "--name", "^General$"], capture_output=True, text=True, env=env)
            return result.returncode == 1 and not result.stdout.strip()
        wait_for("Settings closed independently", settings_closed)
        assert process.poll() is None and rpc("threads.read", threadId=thread_id)["draft"] == draft
        command("xdotool", "windowfocus", "--sync", window, env=env)
        capture(window, "conversation-after-settings", "keyboard draft")
        report["checks"].append("real keyboard palette opened separate Settings; reuse and close preserved main draft")
        quit_normally()
        window = start("restart")
        assert rpc("threads.read", threadId=thread_id)["draft"] == draft
        rpc("threads.open", threadId=thread_id)
        time.sleep(0.8)
        capture(window, "reopened-draft", "keyboard draft")
        report["persistedDraftVerified"] = rpc("threads.read", threadId=thread_id)["draft"] == draft
        report["checks"].append("normal Quit/reopen preserved and rendered the unsent native draft")
        quit_normally()
        report["passed"] = True
    except BaseException as error:
        report["passed"] = False
        report["error"] = str(error)
        raise
    finally:
        drained = process is None or process.poll() is not None
        if process is not None and process.poll() is None:
            try:
                rpc("app.quit")  # Failure cleanup only; cannot turn failed UI input into PASS.
                process.wait(timeout=25)
                drained = True
            except (OSError, ValueError, AssertionError, subprocess.TimeoutExpired):
                report["ownerPending"] = True
                report["fixtureRetained"] = True
        if log is not None:
            log.close()
        # Never upload the private Store or authority keys. A failed owner keeps
        # its synthetic fixture until the runner ends; never erase beneath it.
        (artifacts / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        if drained:
            shutil.rmtree(fixture)
    print(json.dumps(report))


if __name__ == "__main__":
    main()
