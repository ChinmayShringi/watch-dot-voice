"""Tests for exact, public launcher-art replacements without relaxing private-art rules."""
import json
import sys
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import branding_assets
import check_app
import feature_patch
import test_feature_patch


def png_chunk(kind, data):
    return len(data).to_bytes(4, "big") + kind + data + zlib.crc32(kind + data).to_bytes(4, "big")


def icon_png(width=1024, height=1024):
    header = width.to_bytes(4, "big") + height.to_bytes(4, "big") + bytes([8, 2, 0, 0, 0])
    pixels = (b"\0" + b"\x11\x22\x33" * width) * height
    return (feature_patch.PNG_SIGNATURE + png_chunk(b"IHDR", header)
            + png_chunk(b"IDAT", zlib.compress(pixels)) + png_chunk(b"IEND", b""))


def manifest(original, replacement):
    return {"schema": 1,
            "provenance": {"description": "Original synthetic test artwork", "license": "CC0-1.0"},
            "replacements": [{"file": rel, "upstream_sha256": feature_patch.sha256(original),
                              "sha256": feature_patch.sha256(replacement)}
                             for rel in sorted(branding_assets.ICON_PATHS)]}


class BrandingSchemaTests(unittest.TestCase):
    def test_exact_approved_paths_and_provenance_required(self):
        data = manifest(b"original", icon_png())
        self.assertEqual(set(branding_assets.validate(data)), branding_assets.ICON_PATHS)
        bad = [
            {**data, "schema": True},
            {**data, "extra": "not allowed"},
            {**data, "provenance": {"description": "", "license": "CC0-1.0"}},
            {**data, "replacements": data["replacements"][:2]},
            {**data, "replacements": [data["replacements"][0]] * 3},
        ]
        for field, value in (("file", "WatchDotApp/Assets.xcassets/AvatarAtlas.imageset/AvatarAtlas.png"),
                             ("file", "../Icon.png"), ("sha256", "bad"), ("upstream_sha256", None)):
            bad.append({**data, "replacements": [{**data["replacements"][0], field: value},
                                                *data["replacements"][1:]]})
        for invalid in bad:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                branding_assets.validate(invalid)

    def test_source_target_and_dimensions_are_checked(self):
        source, target = b"original", icon_png()
        entry = manifest(source, target)["replacements"][0]
        branding_assets.verify(entry, source, target)
        for original, replacement, expected in ((b"wrong", target, "upstream SHA256"),
                                                 (source, target + b"tamper", "replacement SHA256")):
            with self.subTest(expected=expected), self.assertRaisesRegex(ValueError, expected):
                branding_assets.verify(entry, original, replacement)
        for target in (b"not PNG", icon_png(512, 512)):
            entry = manifest(source, target)["replacements"][0]
            with self.assertRaisesRegex(ValueError, "1024x1024 PNG"):
                branding_assets.verify(entry, source, target)


    def test_metadata_trailing_bytes_crc_and_malformed_chunks_are_rejected(self):
        clean = icon_png()
        branding_assets.validate_png(clean)
        email = b"private@example.invalid"
        bad = [clean + email, clean[:-1], clean[:20],
               clean[:33] + png_chunk(b"tEXt", b"Comment\0" + email) + clean[33:],
               clean[:33] + png_chunk(b"eXIf", email) + clean[33:],
               clean[:33] + png_chunk(b"iTXt", email) + clean[33:],
               clean[:33] + png_chunk(b"zTXt", zlib.compress(email)) + clean[33:],
               clean[:29] + bytes([clean[29] ^ 1]) + clean[30:],
               clean[:33] + b"\xff\xff\xff\xff" + clean[37:],
               clean[:33] + clean[:33] + clean[33:]]
        for data in bad:
            with self.subTest(length=len(data)), self.assertRaises(ValueError):
                branding_assets.verify(manifest(b"original", data)["replacements"][0], b"original", data)


    def test_idat_payloads_are_bounded_and_cannot_hide_extra_streams(self):
        clean = icon_png()
        end = 33 + 12 + int.from_bytes(clean[33:37], "big")
        compressed = clean[41:end - 4]
        for payload in (compressed + b"private@example.invalid", compressed + zlib.compress(b"hidden"),
                        compressed[:-1], zlib.compress(b"x" * (1024 * 3073 + 1))):
            bad = clean[:33] + png_chunk(b"IDAT", payload) + png_chunk(b"IEND", b"")
            with self.assertRaises(ValueError):
                branding_assets.validate_png(bad)


class BrandingIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_feature_patch.FeaturePatchTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.make_feature()
        self.root = self.fixture.root
        self.target = icon_png()
        rel = sorted(branding_assets.ICON_PATHS)[0]
        original = (self.root / "app" / rel).read_bytes()
        self.data = manifest(original, self.target)
        for rel in branding_assets.ICON_PATHS:
            self.fixture.write(rel, self.target)
        self.save_manifest(self.data)

    def save_manifest(self, data):
        path = self.root / branding_assets.MANIFEST_REL
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data))

    def test_record_and_checker_accept_pinned_icons_and_reject_drift(self):
        self.fixture.record()
        self.fixture.assert_check(True)
        rel = sorted(branding_assets.ICON_PATHS)[0]
        self.fixture.write(rel, self.target + b"changed")
        self.fixture.assert_check(False, "branding replacement SHA256 mismatch")
        code, out = self.fixture.run_main(test_feature_patch.record_feature)
        self.assertEqual(code, 1, out)
        self.assertIn("nothing written", out)

    def test_wrong_upstream_hash_and_manifest_symlink_fail(self):
        entries = [{**e, "upstream_sha256": "a" * 64} for e in self.data["replacements"]]
        self.save_manifest({**self.data, "replacements": entries})
        self.fixture.assert_check(False, "branding upstream SHA256 mismatch")
        path = self.root / branding_assets.MANIFEST_REL
        saved = path.with_name("saved.json")
        path.rename(saved)
        path.symlink_to(saved)
        self.fixture.assert_check(False, "symlink")

    def test_display_name_allowed_only_in_existing_app_target_configurations(self):
        source = (self.root / "app" / check_app.PBXPROJ).read_text()
        base = check_app.parse_pbxproj(source)["objects"]
        targets = check_app.targets_by_name(base)
        configs = {cfg for name in check_app.EXPECTED_IDS
                   for cfg in base[targets[name]["buildConfigurationList"]]["buildConfigurations"]}
        self.assertEqual(len(configs), 6)
        current = {key: {**obj, "buildSettings": {**obj["buildSettings"],
                     "INFOPLIST_KEY_CFBundleDisplayName": "New Brand"}} if key in configs else obj
                   for key, obj in base.items()}
        self.assertEqual(check_app.feature_delta_errors(base, current, []), [])
        project_cfg = next(key for key, obj in base.items()
                           if obj.get("isa") == "XCBuildConfiguration" and key not in configs)
        changed = {**current, project_cfg: {**base[project_cfg], "buildSettings": {
            **base[project_cfg]["buildSettings"], "INFOPLIST_KEY_CFBundleDisplayName": "New Brand"}}}
        self.assertTrue(check_app.feature_delta_errors(base, changed, []))
        key = next(iter(configs))
        for setting in ("PRODUCT_BUNDLE_IDENTIFIER", "DEVELOPMENT_TEAM", "CODE_SIGN_ENTITLEMENTS"):
            changed = {**current, key: {**current[key], "buildSettings": {
                **current[key]["buildSettings"], setting: "changed"}}}
            self.assertTrue(check_app.feature_delta_errors(base, changed, []), setting)


if __name__ == "__main__":
    unittest.main()
