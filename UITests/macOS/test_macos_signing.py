"""Offline signing validation: synthetic public certificate bytes and device IDs only."""
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("prepare_macos_signing", Path(__file__).resolve().parents[2] / "script/prepare_macos_signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class MacSigningTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2030, 1, 2, tzinfo=timezone.utc)
        self.team = "ABCD123456"
        self.bundle = "com.example.Coincide"
        self.device = "00000000-0000000000000001"
        self.certificate = b"synthetic public signing certificate; no private key"
        self.fingerprint = hashlib.sha1(self.certificate).hexdigest().upper()
        self.profile = {
            "Platform": ["OSX"], "CreationDate": self.now.replace(tzinfo=None),
            "ExpirationDate": (self.now + timedelta(days=1)).replace(tzinfo=None),
            "TeamIdentifier": [self.team], "ApplicationIdentifierPrefix": [self.team],
            "DeveloperCertificates": [self.certificate], "ProvisionedDevices": [self.device],
            "Entitlements": {
                "com.apple.application-identifier": self.team + "." + self.bundle,
                "com.apple.developer.team-identifier": self.team,
                "keychain-access-groups": [self.team + ".*"],
                "com.apple.security.app-sandbox": True,
                "com.apple.security.application-groups": ["group.example.unrelated"],
                "com.apple.developer.icloud-services": ["CloudDocuments"],
            },
        }

    def validate(self, profile=None, **overrides):
        arguments = dict(bundle_id=self.bundle, identity_sha1=self.fingerprint, device_udid=self.device, now=self.now)
        arguments.update(overrides)
        return signing.validate_profile(self.profile if profile is None else profile, **arguments)

    def test_only_app_identifier_and_profile_authorized_team_are_claimed(self):
        self.assertEqual(self.validate(), {
            "com.apple.application-identifier": self.team + "." + self.bundle,
            "com.apple.developer.team-identifier": self.team,
        })
        without_team_entitlement = copy.deepcopy(self.profile)
        del without_team_entitlement["Entitlements"]["com.apple.developer.team-identifier"]
        self.assertEqual(self.validate(without_team_entitlement), {"com.apple.application-identifier": self.team + "." + self.bundle})

    def test_wildcard_is_expanded_to_exact_bundle_and_legacy_prefix_is_not_guessed_from_team(self):
        wildcard = copy.deepcopy(self.profile)
        wildcard["Entitlements"]["com.apple.application-identifier"] = self.team + ".com.example.*"
        self.assertEqual(self.validate(wildcard)["com.apple.application-identifier"], self.team + "." + self.bundle)
        legacy = copy.deepcopy(self.profile)
        legacy["ApplicationIdentifierPrefix"] = ["LEGACY1234"]
        legacy["Entitlements"]["com.apple.application-identifier"] = "LEGACY1234." + self.bundle
        claims = self.validate(legacy)
        self.assertEqual(claims["com.apple.application-identifier"], "LEGACY1234." + self.bundle)
        self.assertEqual(claims["com.apple.developer.team-identifier"], self.team)

    def test_wrong_platform_expiry_owner_certificate_or_device_never_produces_claims(self):
        variants = []
        def variant(key, value):
            profile = copy.deepcopy(self.profile); profile[key] = value; variants.append(profile)
        variant("Platform", ["iOS"])
        variant("Platform", ["OSX", "iOS"])
        variant("ExpirationDate", self.now.replace(tzinfo=None))
        variant("ExpirationDate", None)
        variant("CreationDate", (self.now + timedelta(hours=1)).replace(tzinfo=None))
        variant("TeamIdentifier", [self.team, "OTHER12345"])
        variant("ApplicationIdentifierPrefix", ["OTHER12345"])
        variant("DeveloperCertificates", [b"different synthetic public certificate"])
        variant("ProvisionedDevices", ["00000000-0000000000000002"])
        variant("ProvisionedDevices", None)
        variant("ProvisionsAllDevices", True)
        for key, value in [("com.apple.application-identifier", self.team + ".com.other.App"),
                           ("com.apple.application-identifier", self.team + ".com.*.Coincide"),
                           ("com.apple.developer.team-identifier", "OTHER12345")]:
            profile = copy.deepcopy(self.profile); profile["Entitlements"][key] = value; variants.append(profile)
        for index, profile in enumerate(variants):
            with self.subTest(case=index), self.assertRaises(signing.SigningError):
                self.validate(profile)
        with self.assertRaises(signing.SigningError):
            self.validate(device_udid=self.device + "\n")

    def test_exact_native_provisioning_udid_is_required_instead_of_hardware_uuid(self):
        metadata = {"SPHardwareDataType": [{"provisioning_UDID": self.device, "platform_UUID": "11111111-1111-1111-1111-111111111111"}]}
        self.assertEqual(signing.host_device_udid(metadata), self.device)
        for bad in [{"SPHardwareDataType": [{"platform_UUID": self.device}]},
                    {"SPHardwareDataType": metadata["SPHardwareDataType"] * 2},
                    {"SPHardwareDataType": [{"provisioning_UDID": self.device + "\n"}]}]:
            with self.assertRaises(signing.SigningError):
                signing.host_device_udid(bad)

    def test_selected_valid_identity_is_exact_and_certificate_must_match_profile(self):
        name = "Apple Development: Synthetic Test Identity"
        listing = '  1) ' + self.fingerprint + ' "' + name + '"\n     1 valid identities found\n'
        self.assertEqual(signing.selected_identity(self.fingerprint.lower(), listing), self.fingerprint)
        self.assertEqual(signing.selected_identity(name, listing), self.fingerprint)
        for selected, output in [("-", listing), ("Synthetic", listing), (name, listing + listing), ("F" * 40, listing)]:
            with self.assertRaises(signing.SigningError):
                signing.selected_identity(selected, output)

    def test_prepare_keeps_validated_profile_bytes_private_even_if_source_changes(self):
        with tempfile.TemporaryDirectory(prefix="coincide-signing-unit-") as directory:
            root = Path(directory)
            source, claims, output = root / "source.profile", root / "claims.plist", root / "embedded.profile"
            original = b"synthetic CMS input; decoded through injected local command"
            source.write_bytes(original)
            calls = []
            def runner(arguments, input_data=b"", maximum_bytes=1_048_576):
                calls.append(tuple(arguments))
                if arguments == ["/usr/bin/security", "cms", "-D"]:
                    self.assertEqual(input_data, original)
                    source.write_bytes(b"replacement source must never be embedded")
                    return plistlib.dumps(self.profile)
                if arguments == ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]:
                    return ('1) ' + self.fingerprint + ' "Apple Development: Synthetic"\n').encode()
                if arguments == ["/usr/sbin/system_profiler", "SPHardwareDataType", "-json"]:
                    return json.dumps({"SPHardwareDataType": [{"provisioning_UDID": self.device}]}).encode()
                self.fail("Unexpected local command")
            signing.prepare(source, self.bundle, self.fingerprint, claims, output, runner=runner, now=self.now)
            self.assertEqual(output.read_bytes(), original)
            self.assertEqual(plistlib.loads(claims.read_bytes()), self.validate())
            self.assertEqual(stat.S_IMODE(claims.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(len(calls), 3)

    def test_input_fifo_symlink_and_existing_or_redirected_output_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="coincide-signing-files-") as directory:
            root = Path(directory)
            regular, linked, fifo, output = (root / name for name in ("regular", "linked", "fifo", "output"))
            regular.write_bytes(b"preserved")
            linked.symlink_to(regular)
            os.mkfifo(fifo)
            for invalid in (linked, fifo):
                with self.assertRaises(signing.SigningError):
                    signing.read_profile(invalid)
            output.symlink_to(regular)
            for invalid in (regular, output):
                with self.assertRaises(signing.SigningError):
                    signing.write_private(invalid, b"must not overwrite")
            self.assertEqual(regular.read_bytes(), b"preserved")

    def test_local_command_output_and_runtime_are_bounded_without_retaining_stderr(self):
        self.assertEqual(signing.run_bounded([sys.executable, "-c", "print('metadata')"]), b"metadata\n")
        for arguments, options in [([sys.executable, "-c", "print('x' * 10000)"], dict(maximum_bytes=128)),
                                   ([sys.executable, "-c", "import time; time.sleep(5)"], dict(timeout=0.05)),
                                   ([sys.executable, "-c", "import sys; sys.stderr.write('not retained'); sys.exit(1)"], {})]:
            with self.assertRaises(signing.SigningError) as observed:
                signing.run_bounded(arguments, **options)
            self.assertNotIn("not retained", str(observed.exception))

    def test_packaging_keeps_optional_lane_and_does_not_grant_helper_or_copy_unrelated_entitlements(self):
        path = Path(__file__).resolve().parents[2] / "script/build_and_run.sh"
        script = path.read_text()
        self.assertIn('PROFILE_PATH="${COINCIDE_PROVISIONING_PROFILE:-}"', script)
        self.assertIn('DEFAULT_PROFILE="$HOME/Library/Application Support/Coincide/Signing/development.provisionprofile"', script)
        self.assertIn('trap cleanup_signing EXIT', script)
        self.assertIn('mktemp -d /private/tmp/coincide-signing.XXXXXX', script)
        self.assertIn('install -m 600 "$SIGNING_TEMP/embedded.provisionprofile" "$APP_BUNDLE/Contents/embedded.provisionprofile"', script)
        self.assertIn('codesign --force --sign "${SIGN_IDENTITY:--}" "$APP_BUNDLE/Contents/Helpers/CoincideScriptHelper"', script)
        self.assertIn('codesign --force --sign "${SIGN_IDENTITY:--}" "$APP_BUNDLE"', script)
        self.assertNotIn('--entitlements "$SIGNING_TEMP/entitlements.plist" "$APP_BUNDLE/Contents/Helpers', script)


if __name__ == "__main__":
    unittest.main()
