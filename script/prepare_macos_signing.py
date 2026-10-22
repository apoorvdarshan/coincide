#!/usr/bin/env python3
"""Prepare minimal macOS signing inputs without logging profile or device data."""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
import plistlib
import re
import selectors
import stat
import subprocess
import sys
import time


class SigningError(ValueError):
    pass


def run_bounded(arguments, input_data=b"", maximum_bytes=1_048_576, timeout=10):
    """Drain only this command's pipes; retain no stderr or unbounded output."""
    process = None
    selector = selectors.DefaultSelector()
    try:
        process = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        os.set_blocking(process.stdout.fileno(), False)
        selector.register(process.stdout, selectors.EVENT_READ, "read")
        if input_data:
            os.set_blocking(process.stdin.fileno(), False)
            selector.register(process.stdin, selectors.EVENT_WRITE, "write")
        else:
            process.stdin.close()
        result = bytearray()
        offset = 0
        deadline = time.monotonic() + timeout
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SigningError("A required local signing check timed out.")
            for key, _ in selector.select(min(remaining, 0.1)):
                try:
                    if key.data == "read":
                        chunk = os.read(key.fd, 65_536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            key.fileobj.close()
                        else:
                            if len(result) + len(chunk) > maximum_bytes:
                                raise SigningError("A required local signing check exceeded its output limit.")
                            result.extend(chunk)
                    else:
                        offset += os.write(key.fd, memoryview(input_data)[offset:offset + 65_536])
                        if offset == len(input_data):
                            selector.unregister(key.fileobj)
                            key.fileobj.close()
                except BlockingIOError:
                    continue
        remaining = deadline - time.monotonic()
        if remaining <= 0 or process.wait(timeout=remaining) != 0:
            raise SigningError("A required local signing check did not succeed.")
        return bytes(result)
    except SigningError:
        raise
    except (OSError, subprocess.SubprocessError):
        raise SigningError("A required local signing check is unavailable.") from None
    finally:
        selector.close()
        if process is not None:
            for handle in (process.stdin, process.stdout):
                if handle is not None and not handle.closed:
                    handle.close()
            if process.poll() is None:
                try:
                    process.terminate()
                    try:
                        process.wait(timeout=1)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=1)
                except (OSError, subprocess.SubprocessError):
                    pass


def selected_identity(identity, listing=None, runner=run_bounded):
    if listing is None:
        listing = runner(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
    if isinstance(listing, bytes):
        try:
            listing = listing.decode("utf-8")
        except UnicodeError:
            raise SigningError("The selected signing identity could not be verified.") from None
    matches = []
    for line in listing.splitlines():
        match = re.fullmatch(r'\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"\r\n]+)"\s*', line)
        if match and (identity.upper() == match[1].upper() or identity == match[2]):
            matches.append(match[1].upper())
    if len(matches) != 1:
        raise SigningError("Choose one available signing identity authorized by the profile.")
    return matches[0]


def host_device_udid(metadata=None, runner=run_bounded):
    if metadata is None:
        raw = runner(["/usr/sbin/system_profiler", "SPHardwareDataType", "-json"])
        try:
            metadata = json.loads(raw)
        except (ValueError, UnicodeError):
            raise SigningError("The current Mac's provisioning identity is unavailable.") from None
    items = metadata.get("SPHardwareDataType") if isinstance(metadata, dict) else None
    if not isinstance(items, list) or len(items) != 1 or not isinstance(items[0], dict):
        raise SigningError("The current Mac's provisioning identity is unavailable.")
    # Apple Silicon's provisioning identifier can differ from platform_UUID.
    value = items[0].get("provisioning_UDID")
    if not valid_device(value):
        raise SigningError("The current Mac's provisioning identity is unavailable.")
    return value


def valid_device(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9A-Fa-f-]{8,128}", value) is not None


def validate_profile(profile, bundle_id, identity_sha1, device_udid, now=None):
    """Return concrete least-privilege claims, not the profile's whole allowlist."""
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    if not isinstance(profile, dict) or re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id) is None:
        raise SigningError("The application or provisioning profile is invalid.")
    if profile.get("Platform") != ["OSX"]:
        raise SigningError("The provisioning profile must authorize this macOS application.")
    expiry = profile.get("ExpirationDate")
    created = profile.get("CreationDate")
    if not isinstance(expiry, datetime) or expiry.replace(tzinfo=expiry.tzinfo or timezone.utc) <= now:
        raise SigningError("The provisioning profile is expired or has no valid expiry.")
    if created is not None and (not isinstance(created, datetime) or created.replace(tzinfo=created.tzinfo or timezone.utc) > now + timedelta(minutes=5)):
        raise SigningError("The provisioning profile is not yet valid.")
    teams, prefixes = profile.get("TeamIdentifier"), profile.get("ApplicationIdentifierPrefix")
    if (not isinstance(teams, list) or len(teams) != 1 or not isinstance(teams[0], str)
            or re.fullmatch(r"[A-Z0-9]{10}", teams[0]) is None
            or not isinstance(prefixes, list) or not 1 <= len(prefixes) <= 8
            or any(not isinstance(x, str) or re.fullmatch(r"[A-Z0-9]{10}", x) is None for x in prefixes)):
        raise SigningError("The provisioning profile has invalid app or team ownership.")
    allowed = profile.get("Entitlements")
    if not isinstance(allowed, dict):
        raise SigningError("The provisioning profile does not authorize an app identifier.")
    app_id = allowed.get("com.apple.application-identifier")
    if not isinstance(app_id, str) or "." not in app_id:
        raise SigningError("The provisioning profile does not authorize an app identifier.")
    prefix, pattern = app_id.split(".", 1)
    if prefix not in prefixes or not (pattern == bundle_id or pattern == "*" or
            (pattern.endswith(".*") and pattern.count("*") == 1 and bundle_id.startswith(pattern[:-1]))):
        raise SigningError("The provisioning profile does not authorize this bundle identifier.")
    team = allowed.get("com.apple.developer.team-identifier")
    if team is not None and team != teams[0]:
        raise SigningError("The provisioning profile has inconsistent team ownership.")
    certificates = profile.get("DeveloperCertificates")
    if (re.fullmatch(r"[0-9A-Fa-f]{40}", identity_sha1) is None or not isinstance(certificates, list)
            or not 1 <= len(certificates) <= 32
            or any(not isinstance(x, bytes) or not 1 <= len(x) <= 65_536 for x in certificates)
            or not any(hashlib.sha1(x).hexdigest().upper() == identity_sha1.upper() for x in certificates)):
        raise SigningError("The selected signing certificate is not authorized by the profile.")
    devices = profile.get("ProvisionedDevices")
    if (profile.get("ProvisionsAllDevices", False) is not False or not valid_device(device_udid)
            or not isinstance(devices, list) or not 1 <= len(devices) <= 10_000
            or any(not valid_device(x) for x in devices)
            or device_udid.upper() not in {x.upper() for x in devices}):
        raise SigningError("The provisioning profile does not authorize this exact Mac.")
    claims = {"com.apple.application-identifier": prefix + "." + bundle_id}
    if team is not None:
        claims["com.apple.developer.team-identifier"] = team
    return claims


def read_profile(path):
    descriptor = None
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or not 0 < info.st_size <= 4_194_304:
            raise SigningError("The provisioning profile must be an owned regular file within the size limit.")
        result = bytearray()
        while True:
            chunk = os.read(descriptor, min(65_536, 4_194_305 - len(result)))
            if not chunk:
                break
            result.extend(chunk)
            if len(result) > 4_194_304:
                raise SigningError("The provisioning profile exceeds its size limit.")
        after = os.fstat(descriptor)
        if len(result) != info.st_size or (info.st_size, info.st_mtime_ns, info.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise SigningError("The provisioning profile changed while it was read.")
        return bytes(result)
    except OSError:
        raise SigningError("The provisioning profile could not be read safely.") from None
    finally:
        if descriptor is not None:
            os.close(descriptor)


def write_private(path, data):
    descriptor = None
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = None
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except OSError:
        raise SigningError("Private signing inputs could not be written safely.") from None
    finally:
        if descriptor is not None:
            os.close(descriptor)


def prepare(profile_path, bundle_id, identity, output_entitlements, output_profile, device_udid=None, runner=run_bounded, now=None):
    encoded = read_profile(profile_path)
    try:
        decoded = plistlib.loads(runner(["/usr/bin/security", "cms", "-D"], input_data=encoded, maximum_bytes=8_388_608))
    except SigningError:
        raise
    except Exception:
        raise SigningError("The provisioning profile could not be decoded safely.") from None
    fingerprint = selected_identity(identity, runner=runner)
    device = device_udid if device_udid is not None else host_device_udid(runner=runner)
    claims = validate_profile(decoded, bundle_id, fingerprint, device, now=now)
    write_private(output_entitlements, plistlib.dumps(claims, fmt=plistlib.FMT_XML, sort_keys=True))
    write_private(output_profile, encoded)


def main():
    parser = argparse.ArgumentParser()
    for field in ("profile", "bundle-id", "identity", "output-entitlements", "output-profile"):
        parser.add_argument("--" + field, required=True)
    parser.add_argument("--device-udid")
    arguments = parser.parse_args()
    prepare(arguments.profile, arguments.bundle_id, arguments.identity, arguments.output_entitlements,
            arguments.output_profile, arguments.device_udid)


if __name__ == "__main__":
    try:
        main()
    except SigningError as error:
        print("Mac signing preparation failed: " + str(error), file=sys.stderr)
        sys.exit(1)
