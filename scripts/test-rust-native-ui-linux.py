#!/usr/bin/env python3
"""Real X11/software-Vulkan smoke. Run under dbus-run-session + xvfb-run.

This proves a rendered native window, keyboard-to-draft persistence, Settings
navigation and a normal Quit/reopen with a private Store. It does not prove
provider execution, all UI parity, Wayland or hardware-GPU rendering.
"""
import argparse
import csv
import io
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
        # Core persistence and a mapped window do not acknowledge presentation
        # of the new widget contents. Observe actual pixels/text under the
        # existing readiness deadline, retaining every stale frame and OCR.
        frame = 0
        def presented_frame():
            nonlocal frame
            observed = artifacts / f"{stage}-frame-{frame:03}.png"
            frame += 1
            command("import", "-window", window, str(observed), env=env)
            with Image.open(observed) as source:
                image = source.convert("RGB")
            assert image.width >= 800 and image.height >= 500, "Native window is too small"
            assert max(ImageStat.Stat(image).stddev) > 8, "Window has no meaningful rendered content"
            ocr_path, segmentation = observed, "11"
            if stage == "command-palette":
                # Preserve the full frame and read its actual centered popup.
                left, right = max(0, image.width // 2 - 360), min(image.width, image.width // 2 + 360)
                crop = image.crop((left, 48, right, min(image.height, 250)))
                ocr_path = observed.with_name(observed.stem + "-ocr-region.png")
                crop.resize((crop.width * 2, crop.height * 2), Image.Resampling.LANCZOS).save(ocr_path)
                segmentation = "6"
            text = command("tesseract", str(ocr_path), "stdout", "--psm", segmentation, env=env)
            observed.with_suffix(".txt").write_text(text)
            if expected:
                assert expected.lower() in text.lower(), f"Expected rendered text {expected!r} in {stage}"
            if stage == "reopened-draft":
                assert "inspector state was not restored" not in text.casefold(), "Restart must recover inspector presentation without a stale restore error"
            observed.replace(path)
            (artifacts / f"{stage}.txt").write_text(text)
            if ocr_path != observed:
                ocr_path.replace(artifacts / f"{stage}-ocr-region.png")
            return image
        return wait_for(f"presented native content for {stage}", presented_frame)

    def click_rendered_word(window, stage, word, *, min_y=0, max_x=200):
        """Target one observed sidebar word; never infer coordinates from layout."""
        # Xvfb has no desktop window manager to focus a newly mapped window
        # when its pixels are clicked. Bind native key focus explicitly to the
        # already-observed owned Settings window before any search typing.
        command("xdotool", "windowfocus", "--sync", window, env=env)
        assert int(command("xdotool", "getwindowfocus", env=env)) == int(window), "Native input focus must belong to the observed Settings window"
        attempt = 0
        def observed_target():
            nonlocal attempt
            name = f"{stage}-target-{attempt:03}"
            attempt += 1
            frame = capture(window, name)
            # The native failure frame showed General correctly, while full-
            # window OCR joined its icon and initial G into 'ceneral'. Read
            # only the actual label strip at higher resolution; exact matching
            # remains mandatory, and the original pixels remain in evidence.
            left = 15 if word == "Search" else 44
            assert left < max_x < frame.width, "Sidebar label crop must fit the observed native window"
            crop = frame.crop((left, 0, max_x, frame.height))
            crop_path = artifacts / f"{name}-labels.png"
            crop.resize((crop.width * 3, crop.height * 3), Image.Resampling.LANCZOS).save(crop_path)
            tsv = command("tesseract", str(crop_path), "stdout", "--psm", "6", "tsv", env=env)
            (artifacts / f"{name}-locator.tsv").write_text(tsv)
            matches = [row for row in csv.DictReader(io.StringIO(tsv), delimiter="\t")
                       if row["text"].strip().casefold() == word.casefold()
                       and int(row["top"]) / 3 >= min_y]
            if len(matches) != 1:
                return None
            row = matches[0]
            return (left + (int(row["left"]) + int(row["width"]) / 2) / 3,
                    (int(row["top"]) + int(row["height"]) / 2) / 3)
        x, y = wait_for(f"one exact rendered sidebar target {word!r}", observed_target)
        command("xdotool", "mousemove", "--window", window, str(round(x)), str(round(y)), "click", "1", env=env)

    def quit_normally(*, guarded=False):
        nonlocal process, log
        assert rpc("app.status")["running"] == [], "Smoke must never start a provider"
        report["quitInputFocusBefore"] = command("xdotool", "getwindowfocus", env=env)
        command("xdotool", "windowfocus", "--sync", window, env=env)
        report["quitInputFocus"] = command("xdotool", "getwindowfocus", env=env)
        assert int(report["quitInputFocus"]) == int(window), "Native Quit input must target the observed main window"
        first = time.monotonic()
        command("xdotool", "key", "--clearmodifiers", "ctrl+q", env=env)
        if guarded:
            time.sleep(0.2)
            assert process.poll() is None, "Hold-to-Quit must refuse the first brief native Ctrl+Q"
            # Normal Quit freezes all Engine JSON admissions. A successful
            # owner-bound request proves this is not merely a slow drain.
            assert rpc("app.status")["running"] == [], "First Quit press must leave ordinary admissions live"
            elapsed = time.monotonic() - first
            assert elapsed < 1.5, "Second native Quit press must remain inside the product double-press interval"
            command("xdotool", "key", "--clearmodifiers", "ctrl+q", env=env)
            report["guardedQuitFirstPressAlive"] = True
            report["guardedQuitSecondPressSeconds"] = elapsed
        try:
            assert process.wait(timeout=25) == 0, "Normal Quit must exit successfully"
        except (subprocess.TimeoutExpired, AssertionError):
            # Read-only failure evidence. Do not issue another Quit key, extend
            # the timeout or let a successful cleanup request erase this failure.
            for key, action in [
                ("quitFailureFocus", lambda: command("xdotool", "getwindowfocus", env=env)),
                ("quitFailureWindows", lambda: command("xdotool", "search", "--all", "--onlyvisible", "--pid", str(process.pid), env=env)),
                ("quitFailureControlStatus", lambda: rpc("app.status")),
            ]:
                try:
                    report[key] = action()
                except (OSError, ValueError, AssertionError, subprocess.SubprocessError) as diagnostic:
                    report[key + "Error"] = str(diagnostic)
            try:
                capture(window, "quit-failure")
            except (OSError, ValueError, AssertionError, subprocess.SubprocessError) as diagnostic:
                report["quitFailureFrameError"] = str(diagnostic)
            raise
        process = None
        log.close()
        log = None

    try:
        vulkan = command("vulkaninfo", "--summary", env=env)
        (artifacts / "software-vulkan.txt").write_text(vulkan)
        assert "llvmpipe" in vulkan.lower() or "lavapipe" in vulkan.lower(), "Software Vulkan was not selected"
        window = start("initial")
        rpc("settings.patch", patch={"holdToQuit": False})
        created_project = rpc("projects.create", path=str(project), name="Native Linux smoke")
        thread = rpc("threads.create", projectId=created_project["id"])
        thread_id = thread["id"]
        rpc("threads.patch", threadId=thread_id, patch={"title": "Native Linux smoke"})
        rpc("threads.open", threadId=thread_id)
        wait_for("active native thread", lambda: rpc("app.status")["activeThread"] == thread_id)
        before = capture(window, "conversation", "Native Linux smoke")
        # Real X11 input into the production textarea; RPC reads only verify it.
        # Locate the production placeholder in the captured native frame, rather
        # than assuming a fixed textarea height. Keep the exact rendered words
        # and bounds as evidence; absent or ambiguous input must fail the smoke.
        tsv = command("tesseract", str(artifacts / "conversation.png"), "stdout",
                      "--psm", "11", "tsv", env=env)
        (artifacts / "composer-locator.tsv").write_text(tsv)
        lines = {}
        for row in csv.DictReader(io.StringIO(tsv), delimiter="\t"):
            if row["text"].strip():
                key = tuple(row[name] for name in ("page_num", "block_num", "par_num", "line_num"))
                lines.setdefault(key, []).append(row)
        inputs = [rows for rows in lines.values()
                  if "write a message" in " ".join(row["text"] for row in rows).lower()]
        assert len(inputs) == 1, "Expected exactly one rendered composer placeholder"
        rows = inputs[0]
        left = min(int(row["left"]) for row in rows)
        top = min(int(row["top"]) for row in rows)
        right = max(int(row["left"]) + int(row["width"]) for row in rows)
        bottom = max(int(row["top"]) + int(row["height"]) for row in rows)
        assert top > before.height // 2, "Composer placeholder must be in the lower native workspace"
        report["composerInputBounds"] = [left, top, right, bottom]
        # Mapping/initial focus predates the asynchronous native thread-open.
        # Xvfb has no window manager: acknowledge the exact owned X focus again
        # at the actual input boundary, rather than inferring it from pixels.
        command("xdotool", "windowfocus", "--sync", window, env=env)
        assert int(command("xdotool", "getwindowfocus", env=env)) == int(window), "Composer input must target the observed owned X11 window"
        command("xdotool", "mousemove", "--window", window,
                str((left + right) // 2), str((top + bottom) // 2), "click", "1", env=env)
        command("import", "-window", window, str(artifacts / "composer-after-click.png"), env=env)
        draft = "Native X11 keyboard draft survives restart"
        command("xdotool", "type", "--clearmodifiers", "--delay", "15", draft, env=env)
        command("import", "-window", window, str(artifacts / "composer-after-type.png"), env=env)
        try:
            wait_for("native keyboard draft saved", lambda: rpc("threads.read", threadId=thread_id).get("draft") == draft)
        except BaseException:
            # This fixture contains synthetic text only. Preserve the actual
            # input/owner outcome before cleanup; never retype or relax the
            # existing exact persistence assertion/deadline on failure.
            try:
                report["composerInputFailure"] = {
                    "focusedWindow": command("xdotool", "getwindowfocus", env=env),
                    "ownedWindow": window,
                    "activeThread": rpc("app.status").get("activeThread"),
                    "expectedThread": thread_id,
                    "savedDraft": rpc("threads.read", threadId=thread_id).get("draft"),
                }
                command("import", "-window", window, str(artifacts / "composer-failure.png"), env=env)
            except Exception as diagnostic_error:
                report["composerFailureEvidenceError"] = type(diagnostic_error).__name__
            raise
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
        # Exercise the real filtered navigation and provider panel, without
        # clicking Check/Install/Login or executing any provider.
        click_rendered_word(settings_window, "settings-search-target", "Search")
        assert int(command("xdotool", "getwindowfocus", env=env)) == int(settings_window), "Search typing must target the owned Settings window"
        command("xdotool", "type", "--clearmodifiers", "Codex", env=env)
        capture(settings_window, "settings-provider-filtered", "Results")
        click_rendered_word(settings_window, "settings-provider-result", "Codex", min_y=80)
        capture(settings_window, "settings-provider-codex", "Executable")
        click_rendered_word(settings_window, "settings-return-general", "General")
        capture(settings_window, "settings-general-returned", "General")
        report["checks"].append("native Settings search opened Codex provider page and returned to General without provider actions")
        # Visit the remaining actual Settings routes for screenshot review. A
        # matching sidebar label alone is insufficient: the native window title
        # must acknowledge navigation, then real body text must be rendered.
        # These are presentation checks; do not click permission, login,
        # microphone/device-refresh, install, capture or credential operations.
        pages = [
            ("Models", "Models", "Favorite"),
            ("Usage", "Usage", "Usage"),
            ("Instructions", "Instructions", "Global"),
            ("Archive", "Archive", "archived"),
            ("Keyboard", "Keyboard", "shortcuts"),
            ("Voice", "Voice", "Engine"),
            ("Browser", "Browser", "Browser profiles"),
            ("Computer Use", "Computer", "Computer Use"),
            ("Appshots", "Appshots", "Permissions"),
            ("Historical images", "Historical", "Historical images"),
            ("About", "About", "Help"),
            ("Claude Code", "Claude", "Executable"),
            ("Cursor", "Cursor", "Executable"),
            ("Grok Build", "Grok", "Executable"),
            ("OpenCode", "OpenCode", "Executable"),
            ("Antigravity", "Antigravity", "Executable"),
        ]
        report["settingsScreens"] = []
        for index, (title, word, body_text) in enumerate(pages):
            stage = f"settings-screen-{index:02}"
            click_rendered_word(settings_window, stage + "-search", "Search")
            command("xdotool", "type", "--clearmodifiers", title, env=env)
            capture(settings_window, stage + "-filtered", "Results")
            click_rendered_word(settings_window, stage + "-result", word, min_y=80)
            wait_for(f"native Settings title {title}", lambda title=title: command("xdotool", "getwindowname", settings_window, env=env).strip() == title)
            provider_page = title in {"Claude Code", "Cursor", "Grok Build", "OpenCode", "Antigravity"}
            # These routes only load saved local configuration. Wait for that
            # real retained child completion before recording enabled controls;
            # never click Check/Sign In or execute a provider for this check.
            capture(settings_window, stage, "Saved settings loaded" if provider_page else body_text)
            report["settingsScreens"].append({"title": title, "artifact": stage + ".png", "nativeTitleVerified": True, "savedConfigurationLoaded": provider_page})
        click_rendered_word(settings_window, "settings-all-pages-return-general", "General")
        wait_for("native General title after all pages", lambda: command("xdotool", "getwindowname", settings_window, env=env).strip() == "General")
        capture(settings_window, "settings-all-pages-general", "Appearance")
        report["checks"].append("native Settings title, rendered body and screenshots verified for 16 additional routes; no feature actions were invoked")
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
        newer = rpc("threads.create", projectId=created_project["id"])
        rpc("threads.patch", threadId=newer["id"], patch={"title": "Newer unselected Linux conversation"})
        rpc("threads.open", threadId=thread_id)
        wait_for("older selected conversation before Quit", lambda: rpc("app.status")["activeThread"] == thread_id)
        capture(window, "older-selected-before-quit", "keyboard draft")
        quit_normally()
        window = start("restart")
        rpc("settings.patch", patch={"holdToQuit": True})
        wait_for("last selected older conversation restored automatically", lambda: rpc("app.status")["activeThread"] == thread_id)
        assert rpc("threads.read", threadId=thread_id)["draft"] == draft
        capture(window, "reopened-draft", "keyboard draft")
        report["persistedDraftVerified"] = rpc("threads.read", threadId=thread_id)["draft"] == draft
        report["checks"].append("normal Quit/reopen automatically restored older selected conversation and rendered its unsent native draft")
        quit_normally(guarded=True)
        report["checks"].append("native Hold-to-Quit refused first brief Ctrl+Q and accepted the second within 1.5 seconds, with ordinary zero-exit drain")
        report["passed"] = True
    except BaseException as error:
        report["passed"] = False
        report["error"] = str(error)
        raise
    finally:
        drained = process is None or process.poll() is not None
        if process is not None and process.poll() is None:
            try:
                report["failureCleanupQuitReply"] = rpc("app.quit")  # Failure cleanup only; cannot turn failed UI input into PASS.
                process.wait(timeout=25)
                drained = True
            except (OSError, ValueError, AssertionError, subprocess.TimeoutExpired) as cleanup_error:
                report["failureCleanupQuitError"] = str(cleanup_error)
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
