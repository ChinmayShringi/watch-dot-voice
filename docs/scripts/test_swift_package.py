"""Tests for the one reviewed Swift package (libwebp). Run: python3 -I -m unittest discover -s docs/scripts -v

Each case adds the package to the synthetic feature from test_feature_patch, records it, and runs
the whole checker, so only the pinned revision, linked into the watch app alone, passes.
"""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_app  # noqa: E402
import export_public  # noqa: E402
import test_feature_patch  # noqa: E402

URL, REVISION = check_app.WEBP_URL, check_app.WEBP_REVISION
REF, PRODUCT, LINK = "F30000000000000000000001", "F30000000000000000000002", "F30000000000000000000003"
PACKAGE = (f'{REF} = {{isa = XCRemoteSwiftPackageReference; repositoryURL = "{URL}"; '
           f"requirement = {{kind = revision; revision = {REVISION}; }}; }};\n")
PRODUCT_DEP = f"{PRODUCT} = {{isa = XCSwiftPackageProductDependency; package = {REF}; productName = libwebp; }};\n"
LINK_FILE = f"{LINK} = {{isa = PBXBuildFile; productRef = {PRODUCT}; }};\n"
CONFIG_SECTION = "/* Begin XCBuildConfiguration section */\n"
WATCH_FRAMEWORKS = "isa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n"
WATCH_NAME = "\t\t\tname = WatchDot;\n"
MAIN_GROUP = "\t\t\tmainGroup = A00000000000000000000004;\n"
PHONE_FRAMEWORKS = "D0000000000000000000000E = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); "
PHONE_NAME = "name = WatchDotPhone; "
MANIFEST_LINE = '    products: [.library(name: "WatchDotCore", targets: ["WatchDotCore"])],\n'
DEPENDENCY = f'    dependencies: [.package(url: "{URL}", revision: "{REVISION}")],\n'
PIN = {"identity": "libwebp-xcode", "kind": "remoteSourceControl", "location": URL, "state": {"revision": REVISION}}
XCODE_RESOLVED = check_app.RESOLVED_FILES[1]


def resolved(pins=None, version=3, **extra):
    return json.dumps({"originHash": "b" * 64, "pins": [PIN] if pins is None else pins, "version": version, **extra})


class SwiftPackageTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_feature_patch.FeaturePatchTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.make_feature()

    def add_package(self, package=PACKAGE, product=PRODUCT_DEP, link=LINK_FILE, phone=False):
        f = self.fixture
        f.edit(check_app.PBXPROJ, test_feature_patch.ASSETS_LINE, "\t\t" + link + test_feature_patch.ASSETS_LINE)
        f.edit(check_app.PBXPROJ, CONFIG_SECTION, "\t\t" + package + "\t\t" + product + CONFIG_SECTION)
        f.edit(check_app.PBXPROJ, MAIN_GROUP, MAIN_GROUP + f"\t\t\tpackageReferences = ({REF}, );\n")
        if phone:
            f.edit(check_app.PBXPROJ, PHONE_FRAMEWORKS, PHONE_FRAMEWORKS.replace("files = ()", f"files = ({LINK}, )"))
            f.edit(check_app.PBXPROJ, PHONE_NAME, PHONE_NAME + f"packageProductDependencies = ({PRODUCT}, ); ")
        else:
            f.edit(check_app.PBXPROJ, WATCH_FRAMEWORKS, WATCH_FRAMEWORKS + f"\t\t\t\t{LINK},\n")
            f.edit(check_app.PBXPROJ, WATCH_NAME, WATCH_NAME + f"\t\t\tpackageProductDependencies = ({PRODUCT}, );\n")
        f.edit("Package.swift", MANIFEST_LINE, MANIFEST_LINE + DEPENDENCY)

    def check(self, ok, fragment=""):
        self.fixture.record()
        self.fixture.assert_check(ok, fragment)

    def test_pinned_package_linked_into_watch_app_passes(self):
        self.add_package()
        self.fixture.write("Package.resolved", resolved(version=2))
        self.fixture.write(XCODE_RESOLVED, resolved())
        self.check(True, "reviewed feature patch")

    def test_package_reference_must_be_exact(self):
        cases = {
            "other revision": PACKAGE.replace(REVISION, "0" * 40),
            "version range": PACKAGE.replace(f"kind = revision; revision = {REVISION};",
                                             "kind = upToNextMajorVersion; minimumVersion = 1.6.0;"),
            "branch": PACKAGE.replace(f"kind = revision; revision = {REVISION};", "kind = branch; branch = master;"),
            "other repository": PACKAGE.replace("SDWebImage/libwebp-Xcode", "example/libwebp-Xcode"),
            "extra key": PACKAGE.replace("isa = XCRemoteSwiftPackageReference;",
                                         "isa = XCRemoteSwiftPackageReference; relativePath = ../x;"),
        }
        for name, package in cases.items():
            with self.subTest(name=name):
                self.setUp()
                self.add_package(package=package)
                self.check(False, f"disallowed project object {REF}")

    def test_product_must_be_libwebp(self):
        self.add_package(product=PRODUCT_DEP.replace("productName = libwebp;", "productName = webpdemux;"))
        self.check(False, f"disallowed project object {PRODUCT}")

    def test_link_into_another_target_fails(self):
        self.add_package(phone=True)
        self.check(False, "beyond reviewed additions")

    def test_unlinked_package_fails(self):
        self.add_package()
        self.fixture.edit(check_app.PBXPROJ, WATCH_FRAMEWORKS + f"\t\t\t\t{LINK},\n", WATCH_FRAMEWORKS)
        self.check(False, "each new package link must be added exactly once")

    def test_second_package_fails(self):
        second = PACKAGE.replace(REF, "F30000000000000000000004").replace("libwebp-Xcode", "Other")
        self.add_package(package=PACKAGE + "\t\t" + second)
        self.check(False, "disallowed project object F30000000000000000000004")

    def test_package_manifest_must_pin_the_revision(self):
        cases = {
            "version range": (DEPENDENCY, DEPENDENCY.replace(f'revision: "{REVISION}"', 'from: "1.6.0"')),
            "second package": (DEPENDENCY, DEPENDENCY.replace(")],", '), .package(path: "../Local")],')),
            "binary target": ("    targets: [\n", '    targets: [\n        .binaryTarget(name: "X", path: "X.xcframework"),\n'),
        }
        for name, (old, new) in cases.items():
            with self.subTest(name=name):
                self.setUp()
                self.add_package()
                self.fixture.edit("Package.swift", old, new)
                self.check(False, "Package.swift")

    def test_resolved_files_pin_only_the_package(self):
        cases = {
            "second pin": resolved(pins=[PIN, {**PIN, "identity": "other", "location": "https://example.com/o.git"}]),
            "branch state": resolved(pins=[{**PIN, "state": {"branch": "master", "revision": REVISION}}]),
            "other revision": resolved(pins=[{**PIN, "state": {"revision": "0" * 40}}]),
            "unknown version": resolved(version=1),
            "extra key": resolved(note="x"),
            "not json": "{",
        }
        for name, content in cases.items():
            for rel in check_app.RESOLVED_FILES:
                with self.subTest(name=name, rel=rel):
                    self.setUp()
                    self.add_package()
                    self.fixture.write(rel, content)
                    self.check(False, f"app/{rel} must pin only libwebp-Xcode")

    def test_resolved_file_elsewhere_is_an_extra_file(self):
        self.add_package()
        self.fixture.record()
        self.fixture.write("Sources/Package.resolved", resolved())
        self.fixture.assert_check(False, "unexpected extra file: app/Sources/Package.resolved")
        code, out = self.fixture.run_main(test_feature_patch.record_feature)
        self.assertEqual(code, 1, out)
        self.assertIn("unreviewable extra file app/Sources/Package.resolved", out)

    def test_export_keeps_resolved_files_and_drops_build_state(self):
        known = set()
        for rel in check_app.RESOLVED_FILES:
            self.assertTrue(export_public.exportable_app_file(rel, known), rel)
        for rel in (".build/workspace-state.json", "WatchDot.xcodeproj/project.xcworkspace/xcuserdata/u/x.plist",
                    "Sources/Package.resolved"):
            self.assertFalse(export_public.exportable_app_file(rel, known), rel)


if __name__ == "__main__":
    unittest.main()
