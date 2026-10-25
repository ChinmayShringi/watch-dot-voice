"""Tests for the reviewed feature patch. Run: python3 -I -m unittest discover -s docs/scripts -v

Builds the pre-feature tree from upstream plus manifests (independent of in-progress app/ sources),
then records a small synthetic feature and checks that every drift fails closed.
"""
import io
import json
import shutil
import sys
import tempfile
import unittest
import zlib
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import apply_translations  # noqa: E402
import check_app  # noqa: E402
import feature_patch  # noqa: E402
import record_feature  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
UPSTREAM = REPO / "docs/prototype/watch-dot"
SWIFT = "Sources/WatchDotCore/NewThing.swift"
ASSET = "WatchDotApp/Assets.xcassets/Frames.imageset/Frames.png"
ARTWORK_REL = "docs/assets/test-atlas-manifest.json"  # Found by png_sha256, not by name.
CONTENTS = "WatchDotApp/Assets.xcassets/Frames.imageset/Contents.json"
FILE_REF = "E0000000000000000000000A /* NewThing.swift */ = {isa = PBXFileReference; " \
           "lastKnownFileType = sourcecode.swift; path = NewThing.swift; sourceTree = \"<group>\"; };\n"
BUILD_FILE = "E0000000000000000000000B /* NewThing.swift in Sources */ = {isa = PBXBuildFile; " \
             "fileRef = E0000000000000000000000A /* NewThing.swift */; };\n"
ASSETS_LINE = "\t\tA0000000000000000000001B /* Assets.xcassets in Resources */ = "
GROUP_LINE = "\t\t\t\tB00000000000000000000006 /* RoomReception.swift */,\n"
PHASE_LINE = "\t\t\t\tA00000000000000000000010 /* WatchDotApp.swift in Sources */,\n"
WATCH_LINE = "\t\t\t\tINFOPLIST_KEY_WKApplication = YES;\n"
MIC = "\t\t\t\tINFOPLIST_KEY_NSMicrophoneUsageDescription = \"Records a voice message.\";\n"


def png(width, height):
    """A minimal valid PNG header and empty image data; the checker reads only the header."""
    def chunk(kind, data):
        return len(data).to_bytes(4, "big") + kind + data + zlib.crc32(kind + data).to_bytes(4, "big")
    ihdr = width.to_bytes(4, "big") + height.to_bytes(4, "big") + bytes([8, 6, 0, 0, 0])
    return feature_patch.PNG_SIGNATURE + chunk(b"IHDR", ihdr) + chunk(b"IEND", b"")


class FeaturePatchTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        for rel in ("docs/config", "docs/translation"):
            shutil.copytree(REPO / rel, self.root / rel)
        (self.root / "docs/patches/avatar-voice").mkdir(parents=True)
        if (REPO / check_app.INSERTIONS_REL).is_file():
            shutil.copy(REPO / check_app.INSERTIONS_REL, self.root / check_app.INSERTIONS_REL)
        shutil.copy(REPO / record_feature.BASE_REL, self.root / record_feature.BASE_REL)
        shutil.copy(REPO / ".gitignore", self.root / ".gitignore")
        self.rebuild_pristine_app()

    def rebuild_pristine_app(self):
        translations = check_app.load_translations(self.root)
        insertions = check_app.load_insertions(self.root)
        for rel in check_app.upstream_files(UPSTREAM):
            original = check_app.git(UPSTREAM, "cat-file", "blob", f"{check_app.PINNED_SHA}:{rel}")
            target = self.root / "app" / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(check_app.expected_content(original, rel, translations, insertions))
        shutil.copy(REPO / "app/NOTICE", self.root / "app/NOTICE")
        shutil.copy(self.root / record_feature.BASE_REL, self.root / "app" / check_app.PBXPROJ)

    def run_main(self, module, *extra):
        out = io.StringIO()
        with redirect_stdout(out):
            code = module.main(["--root", str(self.root), "--upstream", str(UPSTREAM), *extra])
        return code, out.getvalue()

    def assert_check(self, ok, fragment=""):
        code, out = self.run_main(check_app)
        self.assertEqual(code, 0 if ok else 1, out)
        self.assertIn(fragment, out)

    def edit(self, rel, old, new, count=1):
        path = self.root / "app" / rel
        text = path.read_text(encoding="utf-8")
        self.assertEqual(text.count(old), count, old)
        path.write_text(text.replace(old, new), encoding="utf-8")

    def write(self, rel, data):
        path = self.root / "app" / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))

    def make_feature(self, project=True):
        self.edit("WatchDotApp/WatchDotApp.swift", "import SwiftUI\n", "import SwiftUI\n// Feature line.\n")
        self.write(SWIFT, "struct NewThing {}\n")
        self.write(CONTENTS, '{"images": [{"filename": "Frames.png", "idiom": "universal"}]}')
        self.write(ASSET, png(384, 208))
        artwork = {"source_url": "https://example.invalid/cdn/assets/sheet-v7.webp", "source_sha256": "a" * 64,
                   "size": [1536, 2288], "cell_size": [192, 208], "rights": "Test artwork, not GPL.",
                   "png_sha256": feature_patch.sha256(png(384, 208))}
        (self.root / "docs/assets").mkdir(parents=True, exist_ok=True)
        (self.root / ARTWORK_REL).write_text(json.dumps(artwork), encoding="utf-8")
        if project:
            self.edit(check_app.PBXPROJ, ASSETS_LINE, "\t\t" + FILE_REF + "\t\t" + BUILD_FILE + ASSETS_LINE)
            self.edit(check_app.PBXPROJ, GROUP_LINE, GROUP_LINE + "\t\t\t\tE0000000000000000000000A,\n")
            self.edit(check_app.PBXPROJ, PHASE_LINE, PHASE_LINE + "\t\t\t\tE0000000000000000000000B,\n")
            self.edit(check_app.PBXPROJ, "CURRENT_PROJECT_VERSION = 4;", "CURRENT_PROJECT_VERSION = 5;", count=6)
            self.edit(check_app.PBXPROJ, WATCH_LINE, WATCH_LINE + MIC, count=2)

    def record(self):
        code, out = self.run_main(record_feature)
        self.assertEqual(code, 0, out)

    def test_pristine_tree_passes_without_feature(self):
        self.assert_check(True, "OK app/ matches")

    def test_feature_files_fail_until_recorded(self):
        self.make_feature()
        code, out = self.run_main(check_app)
        self.assertEqual(code, 1, out)
        for fragment in ("modified upstream file: app/WatchDotApp/WatchDotApp.swift",
                         f"unexpected extra file: app/{SWIFT}", f"unexpected extra file: app/{ASSET}",
                         "structural changes beyond signing parameterization"):
            self.assertIn(fragment, out)

    def test_recorded_feature_passes(self):
        self.make_feature()
        self.record()
        self.assert_check(True, "reviewed feature patch (4 files, 2 new, 1 assets)")

    def test_drift_after_recording_fails(self):
        cases = {
            "upstream file": (lambda: self.edit("WatchDotApp/WatchDotApp.swift", "// Feature line.", "// Drift."),
                              "modified upstream file: app/WatchDotApp/WatchDotApp.swift"),
            "new file": (lambda: self.write(SWIFT, "struct NewThing { }\n"),
                         f"feature file differs from the reviewed patch: app/{SWIFT}"),
            "extra file": (lambda: self.write("WatchDotApp/Extra.swift", "\n"),
                           "unexpected extra file: app/WatchDotApp/Extra.swift"),
            "asset bytes": (lambda: self.write(ASSET, png(384, 208) + b"x"), "does not match its SHA256"),
            "project": (lambda: self.edit(check_app.PBXPROJ, "CURRENT_PROJECT_VERSION = 5;",
                                          "CURRENT_PROJECT_VERSION = 6;", count=6),
                        "pbxproj differs from the reviewed base plus feature patch"),
            "missing new file": (lambda: (self.root / "app" / SWIFT).unlink(), f"missing feature file: app/{SWIFT}"),
        }
        for name, (drift, fragment) in cases.items():
            with self.subTest(name=name):
                self.setUp()
                self.make_feature()
                self.record()
                drift()
                self.assert_check(False, fragment)

    def test_tampered_patch_or_base_fails(self):
        for rel in ("docs/patches/avatar-voice/avatar-voice.patch", record_feature.BASE_REL):
            with self.subTest(rel=rel):
                self.setUp()
                self.make_feature()
                self.record()
                with (self.root / rel).open("a", encoding="utf-8") as handle:
                    handle.write(" ")
                self.assert_check(False, "does not match its recorded SHA256")

    def test_asset_must_be_whole_cells(self):
        self.make_feature()
        self.write(ASSET, png(200, 208))
        artwork = json.loads((self.root / ARTWORK_REL).read_text(encoding="utf-8"))
        (self.root / ARTWORK_REL).write_text(
            json.dumps({**artwork, "png_sha256": feature_patch.sha256(png(200, 208))}), encoding="utf-8")
        self.record()
        self.assert_check(False, "is not whole 192x208 cells")

    def test_disallowed_project_deltas_fail(self):
        cases = {
            "other setting": (("SWIFT_VERSION = 6.0;", "SWIFT_VERSION = 5.0;", 6), "beyond reviewed additions"),
            "phone microphone key": (("            SWIFT_VERSION = 6.0;\n",
                                      "            SWIFT_VERSION = 6.0;\n" + MIC, 4), "beyond reviewed additions"),
            "unlisted file reference": (("path = NewThing.swift;", "path = Other.swift;", 1),
                                        "disallowed project object"),
            "unplaced build file": ((PHASE_LINE + "\t\t\t\tE0000000000000000000000B,\n", PHASE_LINE, 1),
                                    "each new build file must be added exactly once"),
        }
        for name, ((old, new, count), fragment) in cases.items():
            with self.subTest(name=name):
                self.setUp()
                self.make_feature()
                self.edit(check_app.PBXPROJ, old, new, count=count)
                self.record()
                self.assert_check(False, fragment)

    def test_file_references_must_resolve_to_the_listed_path(self):
        app_group_line = "\t\t\t\tA0000000000000000000000B /* WatchDotApp.swift */,\n"
        cases = {
            "absolute path": [('path = NewThing.swift; sourceTree = "<group>";',
                               'path = /tmp/unreviewed/NewThing.swift; sourceTree = "<absolute>";')],
            "absolute path in group tree": [("path = NewThing.swift;", "path = /tmp/unreviewed/NewThing.swift;")],
            "parent traversal": [("path = NewThing.swift;", "path = ../../outside/NewThing.swift;")],
            "same name in another group": [(GROUP_LINE + "\t\t\t\tE0000000000000000000000A,\n", GROUP_LINE),
                                           (app_group_line, app_group_line + "\t\t\t\tE0000000000000000000000A,\n")],
            "built products tree": [('sourceTree = "<group>"; };\n\t\tE0000000000000000000000B',
                                     "sourceTree = BUILT_PRODUCTS_DIR; };\n\t\tE0000000000000000000000B")],
        }
        for name, edits in cases.items():
            with self.subTest(name=name):
                self.setUp()
                self.make_feature()
                for old, new in edits:
                    self.edit(check_app.PBXPROJ, old, new)
                self.record()
                self.assert_check(False, "disallowed project object E0000000000000000000000A")

    def test_source_root_reference_to_the_listed_path_passes(self):
        self.make_feature()
        self.edit(check_app.PBXPROJ, 'path = NewThing.swift; sourceTree = "<group>";',
                  "path = Sources/WatchDotCore/NewThing.swift; sourceTree = SOURCE_ROOT;")
        self.record()
        self.assert_check(True, "reviewed feature patch")

    def test_two_references_to_one_file_fail(self):
        self.make_feature()
        second = FILE_REF.replace("E0000000000000000000000A", "E0000000000000000000000C")
        self.edit(check_app.PBXPROJ, ASSETS_LINE, "\t\t" + second + ASSETS_LINE)
        self.edit(check_app.PBXPROJ, GROUP_LINE, GROUP_LINE + "\t\t\t\tE0000000000000000000000C,\n")
        self.record()
        self.assert_check(False, "disallowed project object E0000000000000000000000A")

    def link_outside(self, rel, target_name="outside.txt", content=None, dangling=False):
        """Replaces app/rel with a symlink to a file outside app/ (same bytes unless content is given)."""
        path = self.root / "app" / rel
        outside = self.root / target_name
        if not dangling:
            outside.write_bytes(path.read_bytes() if content is None else content)
        path.unlink()
        path.symlink_to(outside)
        return outside

    def test_checker_rejects_symlinks_even_with_matching_content(self):
        cases = {
            "upstream file": lambda: self.link_outside("WatchDotApp/WatchDotApp.swift"),
            "new file": lambda: self.link_outside(SWIFT),
            "asset": lambda: self.link_outside(ASSET),
            "dangling": lambda: self.link_outside("WatchDotApp/Dangling.swift", dangling=True)
            if self.write("WatchDotApp/Dangling.swift", "") is None else None,
            "parent directory": lambda: self.link_dir("WatchDotApp/Assets.xcassets/Frames.imageset"),
        }
        for name, make_link in cases.items():
            with self.subTest(name=name):
                self.setUp()
                self.make_feature()
                self.record()
                make_link()
                self.assert_check(False, "symlink not allowed: app/")

    def link_dir(self, rel):
        path = self.root / "app" / rel
        outside = self.root / "outside-dir"
        shutil.move(path, outside)
        path.symlink_to(outside, target_is_directory=True)
        return outside

    def test_symlinked_pinned_file_fails(self):
        self.make_feature()
        self.record()
        self.link_outside_root(record_feature.BASE_REL)
        self.assert_check(False, "feature manifest is invalid: symlink in path")

    def link_outside_root(self, rel):
        path = self.root / rel
        outside = self.root / "outside-base"
        outside.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(outside)

    def test_apply_writes_nothing_through_symlinks(self):
        cases = {
            "file": lambda: self.link_outside(SWIFT, content=b"outside\n"),
            "dangling": lambda: self.link_outside(SWIFT, dangling=True),
            "parent directory": lambda: self.link_dir("WatchDotApp/Assets.xcassets/Frames.imageset"),
        }
        for name, make_link in cases.items():
            with self.subTest(name=name):
                self.setUp()
                self.make_feature()
                self.record()
                clobbered = self.root / "app/WatchDotApp/WatchDotApp.swift"
                clobbered.write_text("clobbered\n", encoding="utf-8")
                outside = make_link()
                before = outside.read_bytes() if outside.is_file() else None
                outside_files = sorted(p.name for p in outside.iterdir()) if outside.is_dir() else None
                code, out = self.run_main(apply_translations)
                self.assertEqual(code, 1, out)
                self.assertIn("FAIL nothing written: symlink in path", out)
                self.assertEqual(clobbered.read_text(encoding="utf-8"), "clobbered\n")  # No earlier write.
                if outside.is_dir():
                    self.assertEqual(sorted(p.name for p in outside.iterdir()), outside_files)
                else:
                    self.assertEqual(outside.read_bytes() if outside.is_file() else None, before)

    def test_recorder_rejects_symlinks(self):
        self.make_feature()
        self.link_outside(SWIFT)
        code, out = self.run_main(record_feature)
        self.assertEqual(code, 1, out)
        self.assertIn(f"FAIL nothing written: symlink not allowed: app/{SWIFT}", out)
        self.assertFalse((self.root / feature_patch.FEATURE_REL).exists())

    def test_recorder_does_not_write_through_symlinked_output(self):
        self.make_feature()
        outside = self.root / "outside.json"
        outside.write_text("keep\n", encoding="utf-8")
        (self.root / feature_patch.FEATURE_REL).symlink_to(outside)
        code, out = self.run_main(record_feature)
        self.assertEqual(code, 1, out)
        self.assertIn("symlink in path", out)
        self.assertEqual(outside.read_text(encoding="utf-8"), "keep\n")
        self.assertFalse((self.root / record_feature.PATCH_REL).exists())

    def test_ignored_directory_in_declared_path_fails(self):
        hidden = "Sources/WatchDotCore/.build/Voice.swift"
        self.assertFalse(feature_patch.allowed_new_file(hidden))
        self.make_feature()
        self.record()
        path = self.root / feature_patch.FEATURE_REL
        data = json.loads(path.read_text(encoding="utf-8"))
        path.write_text(json.dumps({**data, "new_files": [*data["new_files"], hidden]}), encoding="utf-8")
        self.assert_check(False, f"new files outside the reviewed locations: {hidden}")

    def test_known_paths_reject_symlinks_inside_ignored_directories(self):
        # Even if a declared path ran through an ignored directory, its read must not follow a link.
        self.make_feature()
        self.record()
        feature = feature_patch.load_feature(self.root, check_app.PINNED_SHA)
        hidden = "Sources/WatchDotCore/.build/Voice.swift"
        outside = self.root / "outside.swift"
        outside.write_text("struct Voice {}\n", encoding="utf-8")
        (self.root / "app/Sources/WatchDotCore/.build").mkdir()
        (self.root / "app" / hidden).symlink_to(outside)
        patches = {**feature["patches"], hidden: feature_patch.parse_patch(
            feature_patch.unified_diff(hidden, None, "struct Voice {}\n"))[hidden]}
        forged = {**feature, "patches": patches, "new_files": [*feature["new_files"], hidden]}
        errors = check_app.check_provenance(self.root / "app", UPSTREAM, check_app.load_translations(self.root),
                                            check_app.load_insertions(self.root), forged)
        self.assertIn(f"symlink not allowed: app/{hidden}", errors)

    def test_recorder_rejects_unreviewable_extra_file(self):
        self.make_feature()
        self.write("PhoneDotApp/Extra.swift", "\n")
        code, out = self.run_main(record_feature)
        self.assertEqual(code, 1, out)
        self.assertIn("unreviewable extra file app/PhoneDotApp/Extra.swift", out)
        self.assertFalse((self.root / feature_patch.FEATURE_REL).exists())

    def test_manifest_cross_checks_fail_closed(self):
        changes = {
            "unlisted new file": lambda d: {**d, "new_files": d["new_files"][:-1]},
            "new file outside reviewed dirs": lambda d: {**d, "new_files": [*d["new_files"], "PhoneDotApp/X.swift"]},
            "extra key": lambda d: {**d, "extra": 1},
            "artwork without license": lambda d: {**d, "artwork": {**d["artwork"], "license": " "}},
            "patch outside docs/patches": lambda d: {**d, "patch": "app/x.patch"},
        }
        for name, change in changes.items():
            with self.subTest(name=name):
                self.setUp()
                self.make_feature()
                self.record()
                path = self.root / feature_patch.FEATURE_REL
                path.write_text(json.dumps(change(json.loads(path.read_text(encoding="utf-8")))), encoding="utf-8")
                self.assert_check(False, "feature manifest is invalid")

    def test_apply_translations_restores_feature_content(self):
        self.make_feature()
        self.record()
        for rel in ("WatchDotApp/WatchDotApp.swift", SWIFT, check_app.PBXPROJ):
            (self.root / "app" / rel).write_text("clobbered\n", encoding="utf-8")
        code, out = self.run_main(apply_translations)
        self.assertEqual(code, 0, out)
        self.assert_check(True, "reviewed feature patch")


class StrictApplyTests(unittest.TestCase):
    def roundtrip(self, before, after):
        patch = feature_patch.unified_diff("f.swift", before, after)
        parsed = feature_patch.parse_patch(patch)["f.swift"]
        self.assertEqual(feature_patch.apply_file(before, parsed), after)
        return parsed

    def test_roundtrips_including_missing_final_newline(self):
        lines = "".join(f"line {i}\n" for i in range(40))
        for before, after in ((lines, lines.replace("line 3\n", "LINE 3\n")),
                              (lines, lines.replace("line 30\n", "") + "tail"),
                              ("a\nb", "a\nb\n"), ("a\r\nb\n", "a\r\nc\n"), (None, "new\n")):
            with self.subTest(before=before and before[:12], after=after[-8:]):
                self.roundtrip(before, after)

    def test_applies_only_at_exact_position(self):
        lines = "".join(f"line {i}\n" for i in range(20))
        parsed = self.roundtrip(lines, lines.replace("line 10\n", "LINE 10\n"))
        for shifted in ("extra\n" + lines, lines.replace("line 9\n", "line nine\n")):
            with self.subTest(shifted=shifted[:10]):
                with self.assertRaisesRegex(ValueError, "does not match exactly"):
                    feature_patch.apply_file(shifted, parsed)

    def test_creation_and_modification_must_match_existence(self):
        created = self.roundtrip(None, "x\n")
        with self.assertRaisesRegex(ValueError, "creates an existing file"):
            feature_patch.apply_file("", created)
        modified = self.roundtrip("x\n", "y\n")
        with self.assertRaisesRegex(ValueError, "modifies a missing file"):
            feature_patch.apply_file(None, modified)

    def test_malformed_patches_fail(self):
        good = feature_patch.unified_diff("f.swift", "a\n", "b\n")
        for bad in (good[:-1], good.replace("+++ b/", "+++ c/"), good.replace("@@ -1,1", "@@ -1,2"),
                    good.replace("+b\n", "b\n"), good.replace("+b\n", "\n"), good + good,
                    good.replace("f.swift", "../f.swift"), "--- a/f\n+++ b/f\n"):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    feature_patch.parse_patch(bad)


if __name__ == "__main__":
    unittest.main()
