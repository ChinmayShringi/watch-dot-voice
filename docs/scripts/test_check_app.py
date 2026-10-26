"""Tests for check_app.py. Run: python3 -I -m unittest discover -s docs/scripts -v"""
import io
import json
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import apply_translations  # noqa: E402
import check_app  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
UPSTREAM = REPO / "docs/prototype/watch-dot"
# The public export omits the Debug-simulator insertions; their tests run only where they exist.
needs_insertions = unittest.skipUnless((REPO / check_app.INSERTIONS_REL).is_file(),
                                       "simulator insertion manifest not present")


class CheckAppTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)  # setUp also re-runs per subTest
        shutil.copytree(REPO / "app", self.root / "app")
        shutil.copytree(REPO / "docs/config", self.root / "docs/config")
        shutil.copytree(REPO / "docs/translation", self.root / "docs/translation")
        shutil.copytree(REPO / "docs/patches", self.root / "docs/patches")
        if (REPO / "docs/branding").is_dir():
            shutil.copytree(REPO / "docs/branding", self.root / "docs/branding")
        shutil.copy(REPO / ".gitignore", self.root / ".gitignore")
        (self.root / check_app.LOCAL_REL).unlink(missing_ok=True)

    def run_check(self):
        out = io.StringIO()
        with redirect_stdout(out):
            code = check_app.main(["--root", str(self.root), "--upstream", str(UPSTREAM)])
        return code, out.getvalue()

    def edit(self, rel, old, new):
        path = self.root / rel
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    def assert_fails(self, fragment):
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn(fragment, out)

    def test_clean_copy_passes(self):
        code, out = self.run_check()
        self.assertEqual(code, 0, out)

    def test_modified_source_fails(self):
        self.edit("app/Sources/WatchDotCore/Authentication.swift", "import", "import ")
        self.assert_fails("modified upstream file: app/Sources/WatchDotCore/Authentication.swift")

    def test_untranslated_file_fails(self):
        rel = "Sources/WatchDotCore/Authentication.swift"
        original = check_app.git(UPSTREAM, "cat-file", "blob", f"{check_app.PINNED_SHA}:{rel}")
        (self.root / "app" / rel).write_bytes(original)
        self.assert_fails(f"modified upstream file: app/{rel}")

    def test_edit_beyond_manifest_in_translated_file_fails(self):
        # A code line, not UI copy, so copy changes in later feature patches don't break the test.
        self.edit("app/WatchDotApp/WatchDotApp.swift", "import WidgetKit", "import WidgetKit // edit")
        self.assert_fails("modified upstream file: app/WatchDotApp/WatchDotApp.swift")

    def rewrite_manifest(self, change):
        path = self.root / check_app.TRANSLATIONS_REL
        data = json.loads(path.read_text(encoding="utf-8"))
        path.write_text(json.dumps(change(data)), encoding="utf-8")

    def with_entry(self, **fields):
        def change(data):
            first = data["replacements"][0]
            return {**data, "replacements": [{**first, **fields}, *data["replacements"][1:]]}
        return change

    def test_success_message_mentions_english_replacements(self):
        code, out = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertIn("reviewed English replacements", out)

    def test_tampered_manifest_count_fails(self):
        first = json.loads((self.root / check_app.TRANSLATIONS_REL).read_text(encoding="utf-8"))["replacements"][0]
        self.rewrite_manifest(self.with_entry(count=first["count"] + 1))
        self.assert_fails("reviewed changes do not apply")

    def test_manifest_targeting_project_file_fails(self):
        self.rewrite_manifest(self.with_entry(file=check_app.PBXPROJ))
        self.assert_fails("translation manifest is invalid")

    def test_manifest_rejects_non_plain_paths(self):
        for rel in ("../outside.swift", "/etc/hosts", "./PhoneDotApp/PhoneDotApp.swift",
                    "PhoneDotApp//PhoneDotApp.swift", "PhoneDotApp\\PhoneDotApp.swift"):
            with self.subTest(rel=rel):
                self.setUp()
                self.rewrite_manifest(self.with_entry(file=rel))
                self.assert_fails("translation manifest is invalid")

    def test_manifest_rejects_wrong_types(self):
        for fields in ({"count": True}, {"count": "1"}, {"new": 5}, {"old": ""}, {"extra": "x"}):
            with self.subTest(fields=fields):
                self.setUp()
                self.rewrite_manifest(self.with_entry(**fields))
                self.assert_fails("translation manifest is invalid")

    def test_manifest_must_be_object_with_list(self):
        for data in ([], {"upstream": check_app.PINNED_SHA, "replacements": {}}):
            with self.subTest(data=data):
                self.setUp()
                self.rewrite_manifest(lambda _: data)
                self.assert_fails("translation manifest is invalid")

    def test_apply_writes_nothing_when_a_later_entry_is_bad(self):
        manifest = json.loads((self.root / check_app.TRANSLATIONS_REL).read_text(encoding="utf-8"))
        first_rel = manifest["replacements"][0]["file"]
        spanish = check_app.git(UPSTREAM, "cat-file", "blob", f"{check_app.PINNED_SHA}:{first_rel}")
        (self.root / "app" / first_rel).write_bytes(spanish)
        last = manifest["replacements"][-1]
        self.rewrite_manifest(lambda data: {**data, "replacements": [
            *data["replacements"][:-1], {**last, "count": last["count"] + 1}]})
        out = io.StringIO()
        with redirect_stdout(out):
            code = apply_translations.main(["--root", str(self.root), "--upstream", str(UPSTREAM)])
        self.assertEqual(code, 1, out.getvalue())
        self.assertIn("nothing written", out.getvalue())
        self.assertEqual((self.root / "app" / first_rel).read_bytes(), spanish)

    def rewrite_insertions(self, change):
        path = self.root / check_app.INSERTIONS_REL
        data = json.loads(path.read_text(encoding="utf-8"))
        path.write_text(json.dumps(change(data)), encoding="utf-8")

    def with_insertion(self, **fields):
        def change(data):
            first = data["insertions"][0]
            return {**data, "insertions": [{**first, **fields}, *data["insertions"][1:]]}
        return change

    @needs_insertions
    def test_success_message_mentions_simulator_insertions(self):
        code, out = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertIn("Debug-simulator-only insertions", out)

    @needs_insertions
    def test_insertions_are_guarded_in_app(self):
        text = (self.root / "app" / "PhoneDotApp/PhoneOAuthBrowser.swift").read_text(encoding="utf-8")
        self.assertEqual(text.count(check_app.SIMULATOR_GUARD), 3)
        self.assertIn('"--mac-browser-login"', text)

    @needs_insertions
    def test_missing_insertion_fails(self):
        rel = "app/PhoneDotApp/PhoneOAuthBrowser.swift"
        entry = check_app.load_insertions(self.root)["PhoneDotApp/PhoneOAuthBrowser.swift"][1]
        self.edit(rel, entry["text"], "")
        self.assert_fails(f"modified upstream file: {rel}")

    @needs_insertions
    def test_unguarded_insertion_fails(self):
        for text in ("    private var x = 0\n",
                     "    #if DEBUG\n    private var x = 0\n    #endif\n",
                     f"    {check_app.SIMULATOR_GUARD}\n    #endif\n    private var x = 0\n"
                     f"    {check_app.SIMULATOR_GUARD}\n    #endif\n",
                     f"    {check_app.SIMULATOR_GUARD}\n    #else\n    private var x = 0\n    #endif\n",
                     f"    {check_app.SIMULATOR_GUARD}\n    private var x = 0\n    #endif"):
            with self.subTest(text=text):
                self.setUp()
                self.rewrite_insertions(self.with_insertion(text=text))
                self.assert_fails("insertion manifest is invalid")

    @needs_insertions
    def test_insertion_outside_allowed_file_fails(self):
        for rel in ("Sources/WatchDotCore/Authentication.swift", check_app.PBXPROJ, "NOTICE",
                    "../PhoneDotApp/PhoneOAuthBrowser.swift"):
            with self.subTest(rel=rel):
                self.setUp()
                self.rewrite_insertions(self.with_insertion(file=rel))
                self.assert_fails("insertion manifest is invalid")

    @needs_insertions
    def test_insertion_manifest_shape(self):
        for data in ([], {"upstream": check_app.PINNED_SHA, "insertions": {}},
                     {"upstream": "0" * 40, "insertions": []},
                     {"upstream": check_app.PINNED_SHA, "insertions": [], "extra": 1}):
            with self.subTest(data=data):
                self.setUp()
                self.rewrite_insertions(lambda _: data)
                self.assert_fails("insertion manifest is invalid")
        self.setUp()
        self.rewrite_insertions(self.with_insertion(extra="x"))
        self.assert_fails("insertion manifest is invalid")

    @needs_insertions
    def test_missing_or_ambiguous_anchor_fails(self):
        for before in ("    no such line in this file\n", "        }\n", "var generation = UUID()\n"):
            with self.subTest(before=before):
                self.setUp()
                self.rewrite_insertions(self.with_insertion(before=before))
                self.assert_fails("reviewed changes do not apply")

    @needs_insertions
    def test_apply_restores_insertions(self):
        rel = "PhoneDotApp/PhoneOAuthBrowser.swift"
        patched = (self.root / "app" / rel).read_bytes()
        english = check_app.translated(
            check_app.git(UPSTREAM, "cat-file", "blob", f"{check_app.PINNED_SHA}:{rel}"),
            check_app.load_translations(self.root)[rel])
        (self.root / "app" / rel).write_bytes(english)
        with redirect_stdout(io.StringIO()):
            code = apply_translations.main(["--root", str(self.root), "--upstream", str(UPSTREAM)])
        self.assertEqual(code, 0)
        self.assertEqual((self.root / "app" / rel).read_bytes(), patched)

    def test_rewritten_notice_fails(self):
        self.edit("app/NOTICE", "Watch Dot", "Something Else")
        self.assert_fails("app/NOTICE must keep the upstream text")

    def test_extra_file_fails(self):
        (self.root / "app/Sources/WatchDotCore/Extra.swift").write_text("// extra\n")
        self.assert_fails("unexpected extra file: app/Sources/WatchDotCore/Extra.swift")

    def test_hardcoded_team_fails(self):
        self.edit(f"app/{check_app.PBXPROJ}", "CODE_SIGNING_ALLOWED = YES;",
                  "CODE_SIGNING_ALLOWED = YES;\n\t\t\t\tDEVELOPMENT_TEAM = ABCDE12345;")
        self.assert_fails("sets DEVELOPMENT_TEAM")

    def test_wrong_watch_bundle_id_fails(self):
        self.edit(f"app/{check_app.PBXPROJ}", '"$(WATCHDOT_BUNDLE_PREFIX).watchkitapp";',
                  '"$(WATCHDOT_BUNDLE_PREFIX).watch";')
        self.assert_fails("WatchDot/Debug: bundle ID")

    def test_mismatched_companion_fails(self):
        self.edit(f"app/{check_app.PBXPROJ}", 'WKCompanionAppBundleIdentifier = "$(WATCHDOT_BUNDLE_PREFIX)";',
                  "WKCompanionAppBundleIdentifier = com.other.app;")
        self.assert_fails("companion ID")

    def test_structural_change_fails(self):
        self.edit(f"app/{check_app.PBXPROJ}", "WATCHOS_DEPLOYMENT_TARGET = 10.0;",
                  "WATCHOS_DEPLOYMENT_TARGET = 11.0;")
        # With the reviewed feature recorded, the project must equal its base plus that patch.
        self.assert_fails("pbxproj differs from the reviewed base plus feature patch")
        self.assert_fails("beyond reviewed additions")

    def test_target_level_base_config_fails(self):
        self.edit(f"app/{check_app.PBXPROJ}",
                  "\t\tA00000000000000000000013 /* Debug */ = {\n\t\t\tisa = XCBuildConfiguration;\n",
                  "\t\tA00000000000000000000013 /* Debug */ = {\n\t\t\tisa = XCBuildConfiguration;\n"
                  "\t\t\tbaseConfigurationReference = E00000000000000000000001;\n")
        self.assert_fails("must not set its own baseConfigurationReference")

    def test_include_before_defaults_fails(self):
        path = self.root / check_app.CONFIG_REL
        text = path.read_text(encoding="utf-8").replace(check_app.LOCAL_INCLUDE + "\n", "")
        path.write_text(check_app.LOCAL_INCLUDE + "\n" + text, encoding="utf-8")
        self.assert_fails(f"must end with {check_app.LOCAL_INCLUDE}")

    def test_team_in_committed_config_fails(self):
        self.edit(check_app.CONFIG_REL, "DEVELOPMENT_TEAM =", "DEVELOPMENT_TEAM = ABCDE12345")
        self.assert_fails("must keep DEVELOPMENT_TEAM empty")

    def test_unignored_local_config_fails(self):
        (self.root / ".gitignore").write_text(".build/\n")
        self.assert_fails(".gitignore must list")

    def test_placeholder_local_config_fails(self):
        shutil.copy(self.root / "docs/config/WatchDot.local.xcconfig.example", self.root / check_app.LOCAL_REL)
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn("WATCHDOT_BUNDLE_PREFIX must be your own", out)
        self.assertIn("DEVELOPMENT_TEAM must be a 10-character", out)

    def test_valid_local_config_passes(self):
        (self.root / check_app.LOCAL_REL).write_text(
            "WATCHDOT_BUNDLE_PREFIX = com.tester.watchdot\nDEVELOPMENT_TEAM = ABCDE12345\n")
        code, out = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertIn("local override present", out)


if __name__ == "__main__":
    unittest.main()
