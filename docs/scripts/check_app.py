#!/usr/bin/env python3
"""Static checks for the app/ copy of watch-dot.

Verifies, without Xcode:
  1. Provenance: every upstream file at the pinned commit exists in app/ and is
     byte-identical, except the allowed modified files and files that equal
     upstream plus the reviewed English replacements in
     docs/translation/en-replacements.json, then the simulator-only insertions in
     docs/patches/simulator-mac-browser-login.json, then the reviewed feature patch
     pinned by docs/patches/avatar-voice.json; extra files only as that manifest lists.
  2. Project: no hardcoded team or upstream bundle IDs, bundle IDs derive from
     WATCHDOT_BUNDLE_PREFIX, phone/watch/complication relationships intact, and
     no structural pbxproj change beyond the signing parameterization, except the
     pinned feature delta (new Swift file references, version and microphone keys).
  3. Config: committed xcconfig holds placeholders only; the optional local
     override, if present, holds real-looking values; the override is git-ignored.

Usage: python3 -I docs/scripts/check_app.py [--root DIR] [--upstream DIR]
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent))
import branding_assets
import feature_patch  # noqa: E402

PINNED_SHA = "0ca53cc050017533e5ed8aef0436fc32e20f2ba1"
PBXPROJ = "WatchDot.xcodeproj/project.pbxproj"
ALLOWED_MODIFIED = {PBXPROJ, "NOTICE"}
IGNORED_PARTS = feature_patch.IGNORED_PARTS
FORBIDDEN_TEXT = ("85ZLZTQP82", "85zlztqp82", "australapps")
PREFIX = "$(WATCHDOT_BUNDLE_PREFIX)"
EXPECTED_IDS = {
    "WatchDotPhone": PREFIX,
    "WatchDot": PREFIX + ".watchkitapp",
    "WatchDotComplication": PREFIX + ".watchkitapp.launcher",
}
# Settings the parameterization is allowed to add, change or remove.
PARAM_KEYS = {"DEVELOPMENT_TEAM", "PRODUCT_BUNDLE_IDENTIFIER",
              "INFOPLIST_KEY_WKCompanionAppBundleIdentifier"}
CONFIG_REL = "docs/config/WatchDot.xcconfig"
LOCAL_REL = "docs/config/WatchDot.local.xcconfig"
LOCAL_INCLUDE = '#include? "WatchDot.local.xcconfig"'
TRANSLATIONS_REL = "docs/translation/en-replacements.json"
PLACEHOLDER_PREFIX = "com.example.watchdot"
INSERTIONS_REL = "docs/patches/simulator-mac-browser-login.json"
INSERTION_FILES = {"PhoneDotApp/PhoneOAuthBrowser.swift"}
SIMULATOR_GUARD = "#if DEBUG && targetEnvironment(simulator)"
# Build settings the feature may change; the microphone key only on the watch app.
FEATURE_SETTINGS = {"CURRENT_PROJECT_VERSION", "MARKETING_VERSION"}
MICROPHONE_KEY = "INFOPLIST_KEY_NSMicrophoneUsageDescription"
FILE_REF_KEYS = {"isa", "path", "name", "lastKnownFileType", "sourceTree", "fileEncoding", "includeInIndex"}


def git(upstream, *args):
    return subprocess.run(["git", "-C", str(upstream), *args],
                          check=True, capture_output=True).stdout


def upstream_files(upstream):
    out = git(upstream, "ls-tree", "-r", "-z", "--name-only", PINNED_SHA)
    return [p for p in out.decode().split("\0") if p]


def load_translations(root):
    """Reads the reviewed manifest as {file: [entries]}; raises ValueError if malformed."""
    path = root / TRANSLATIONS_REL
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("upstream") != PINNED_SHA \
            or not isinstance(data.get("replacements"), list):
        raise ValueError(f"{TRANSLATIONS_REL} must be an object targeting {PINNED_SHA} with a replacements list")
    by_file = {}
    for index, entry in enumerate(data["replacements"]):
        if not valid_entry(entry):
            raise ValueError(f"{TRANSLATIONS_REL}: invalid entry #{index}")
        by_file = {**by_file, entry["file"]: [*by_file.get(entry["file"], []), entry]}
    return by_file


def valid_entry(entry):
    if not isinstance(entry, dict) or set(entry) != {"file", "old", "new", "count"}:
        return False
    file, old, new, count = entry["file"], entry["old"], entry["new"], entry["count"]
    return (all(isinstance(v, str) for v in (file, old, new)) and type(count) is int and count >= 1
            and old != "" and old != new and file not in ALLOWED_MODIFIED and is_plain_relative(file))


def is_plain_relative(rel):
    """True for a normalized POSIX path inside the tree: no absolute, '.', '..' or backslash parts."""
    path = PurePosixPath(rel)
    return (rel != "" and "\\" not in rel and not path.is_absolute() and str(path) == rel
            and all(part not in (".", "..") for part in path.parts))


def translated(original, entries):
    """Applies reviewed literal replacements in order; each must match its recorded count."""
    text = original.decode("utf-8")
    for entry in entries:
        found = text.count(entry["old"])
        if found != entry["count"]:
            raise ValueError(f"expected {entry['count']} of {entry['old']!r}, found {found}")
        text = text.replace(entry["old"], entry["new"])
    return text.encode("utf-8")


def load_insertions(root):
    """Reads the simulator-only insertions as {file: [entries]}; raises ValueError if malformed."""
    path = root / INSERTIONS_REL
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or set(data) != {"upstream", "insertions"} \
            or data["upstream"] != PINNED_SHA or not isinstance(data["insertions"], list):
        raise ValueError(f"{INSERTIONS_REL} must be an object targeting {PINNED_SHA} with an insertions list")
    by_file = {}
    for index, entry in enumerate(data["insertions"]):
        if not valid_insertion(entry):
            raise ValueError(f"{INSERTIONS_REL}: invalid insertion #{index}")
        by_file = {**by_file, entry["file"]: [*by_file.get(entry["file"], []), entry]}
    return by_file


def valid_insertion(entry):
    """Pure additions wrapped in one Debug-simulator guard, so device and Release builds compile none of it."""
    if not isinstance(entry, dict) or set(entry) != {"file", "before", "text"} \
            or not all(isinstance(v, str) for v in entry.values()):
        return False
    lines = entry["text"].splitlines()
    directives = [line.strip() for line in lines if line.strip().startswith("#")]
    return (entry["file"] in INSERTION_FILES and entry["before"].strip() != ""
            and entry["text"].endswith("\n") and len(lines) >= 3
            and lines[0].strip() == SIMULATOR_GUARD and lines[-1].strip() == "#endif"
            and directives == [SIMULATOR_GUARD, "#endif"])


def inserted(original, entries):
    """Inserts each block before its anchor, which must start a line and occur exactly once."""
    text = original.decode("utf-8")
    for entry in entries:
        found = text.count(entry["before"])
        if found != 1:
            raise ValueError(f"expected 1 anchor {entry['before']!r}, found {found}")
        at = text.index(entry["before"])
        if at > 0 and text[at - 1] != "\n":
            raise ValueError(f"anchor {entry['before']!r} must start a line")
        text = text[:at] + entry["text"] + text[at:]
    return text.encode("utf-8")


def expected_content(original, rel, translations, insertions):
    """Upstream bytes plus reviewed translations, then simulator-only insertions."""
    text = translated(original, translations[rel]) if rel in translations else original
    return inserted(text, insertions[rel]) if rel in insertions else text


def featured(content, rel, feature):
    """Applies the reviewed feature hunks for rel, if any."""
    if feature is None or rel not in feature["patches"]:
        return content
    before = None if content is None else content.decode("utf-8")
    return feature_patch.apply_file(before, feature["patches"][rel]).encode("utf-8")


def check_provenance(app, upstream, translations, insertions, feature=None):
    errors = []
    try:
        branding = branding_assets.load(app.parent)
    except (ValueError, OSError) as error:
        return [f"branding manifest is invalid: {error}"]
    expected = upstream_files(upstream)
    errors += [f"translation targets a non-upstream file: {rel}" for rel in translations if rel not in expected]
    errors += [f"insertion targets a non-upstream file: {rel}" for rel in insertions if rel not in expected]
    new_files = feature["new_files"] if feature else []
    patched = set(feature["patches"]) if feature else set()
    errors += [f"feature modifies a non-upstream file: {rel}" for rel in sorted(patched - set(new_files))
               if rel not in expected]
    errors += [f"feature creates an upstream file: {rel}" for rel in new_files if rel in expected]
    for rel in expected:
        try:
            local = feature_patch.contained(app, rel)  # Known paths never skip the symlink check.
        except ValueError:
            errors.append(f"symlink not allowed: app/{rel}")
            continue
        if not local.is_file():
            errors.append(f"missing upstream file: app/{rel}")
            continue
        original = git(upstream, "cat-file", "blob", f"{PINNED_SHA}:{rel}")
        current = local.read_bytes()
        if rel in branding:
            try:
                branding_assets.verify(branding[rel], original, current)
            except ValueError as error:
                errors.append(str(error))
            continue
        if rel == "NOTICE":
            if not current.startswith(original):
                errors.append("app/NOTICE must keep the upstream text unchanged and only append")
            continue
        if rel in ALLOWED_MODIFIED:
            continue
        try:
            wanted = featured(expected_content(original, rel, translations, insertions), rel, feature)
        except ValueError as error:
            errors.append(f"reviewed changes do not apply to app/{rel}: {error}")
            continue
        if current != wanted:
            errors.append(f"modified upstream file: app/{rel}")
    for rel in (r for r in new_files if r not in expected):
        try:
            local = feature_patch.contained(app, rel)
        except ValueError:
            errors.append(f"symlink not allowed: app/{rel}")
            continue
        if not local.is_file():
            errors.append(f"missing feature file: app/{rel}")
        elif local.read_bytes() != featured(None, rel, feature):
            errors.append(f"feature file differs from the reviewed patch: app/{rel}")
    assets = [entry["file"] for entry in feature["assets"]] if feature else []
    errors += feature_patch.asset_errors(app, feature) if feature else []
    known = set(expected) | set(new_files) | set(assets)
    if app.is_symlink():
        errors.append("app/ must not be a symlink")
    for path in app.rglob("*"):
        rel = path.relative_to(app).as_posix()
        if IGNORED_PARTS & set(path.parts):
            continue
        if path.is_symlink():
            # Content checks follow links, so a link could vouch for bytes outside app/.
            errors.append(f"symlink not allowed: app/{rel}")
        elif path.is_file() and rel not in known:
            errors.append(f"unexpected extra file: app/{rel}")
    return errors


def parse_pbxproj(text):
    """Converts an OpenStep pbxproj to a dict using macOS plutil."""
    result = subprocess.run(["plutil", "-convert", "json", "-o", "-", "-"],
                            input=text.encode(), capture_output=True)
    if result.returncode != 0:
        raise ValueError(result.stderr.decode().strip() or "plutil failed")
    return json.loads(result.stdout)


def targets_by_name(objects):
    return {o["name"]: o for o in objects.values() if o.get("isa") == "PBXNativeTarget"}


def configs_of(objects, owner):
    return [objects[c] for c in objects[owner["buildConfigurationList"]]["buildConfigurations"]]


def check_bundle_ids(objects):
    errors = []
    targets = targets_by_name(objects)
    for name, expected in EXPECTED_IDS.items():
        if name not in targets:
            errors.append(f"target missing: {name}")
            continue
        for cfg in configs_of(objects, targets[name]):
            settings = cfg["buildSettings"]
            actual = settings.get("PRODUCT_BUNDLE_IDENTIFIER")
            if actual != expected:
                errors.append(f"{name}/{cfg['name']}: bundle ID {actual!r}, expected {expected!r}")
            if name == "WatchDot":
                companion = settings.get("INFOPLIST_KEY_WKCompanionAppBundleIdentifier")
                if companion != EXPECTED_IDS["WatchDotPhone"]:
                    errors.append(f"WatchDot/{cfg['name']}: companion ID {companion!r} must equal phone ID")
    return errors


def embeds(objects, target, product_ref, dst_spec, dst_path=None):
    for phase_id in target["buildPhases"]:
        phase = objects[phase_id]
        if phase.get("isa") != "PBXCopyFilesBuildPhase" or phase.get("dstSubfolderSpec") != dst_spec:
            continue
        if dst_path is not None and phase.get("dstPath") != dst_path:
            continue
        if any(objects[f].get("fileRef") == product_ref for f in phase["files"]):
            return True
    return False


def depends_on(objects, target, dependency_id):
    return any(objects[d].get("target") == dependency_id for d in target["dependencies"])


def check_relationships(objects):
    targets = targets_by_name(objects)
    if not set(EXPECTED_IDS) <= set(targets):
        return []  # Already reported by check_bundle_ids.
    ids = {o["name"]: k for k, o in objects.items() if o.get("isa") == "PBXNativeTarget"}
    phone, watch = targets["WatchDotPhone"], targets["WatchDot"]
    complication = targets["WatchDotComplication"]
    errors = []
    if not depends_on(objects, phone, ids["WatchDot"]):
        errors.append("WatchDotPhone must depend on WatchDot")
    if not embeds(objects, phone, watch["productReference"], "16", "$(CONTENTS_FOLDER_PATH)/Watch"):
        errors.append("WatchDotPhone must embed WatchDot.app in $(CONTENTS_FOLDER_PATH)/Watch")
    if not depends_on(objects, watch, ids["WatchDotComplication"]):
        errors.append("WatchDot must depend on WatchDotComplication")
    if not embeds(objects, watch, complication["productReference"], "13"):
        errors.append("WatchDot must embed WatchDotComplication.appex as a plug-in")
    return errors


def check_base_config(objects, app):
    errors = []
    root = next(o for o in objects.values() if o.get("isa") == "PBXProject")
    project_configs = set(objects[root["buildConfigurationList"]]["buildConfigurations"])
    expected = (app.parent / CONFIG_REL).resolve()
    for cfg in configs_of(objects, root):
        ref = objects.get(cfg.get("baseConfigurationReference", ""))
        if ref is None:
            errors.append(f"project {cfg['name']} config has no baseConfigurationReference")
        elif ref.get("sourceTree") != "SOURCE_ROOT" or (app / ref["path"]).resolve() != expected:
            errors.append(f"project {cfg['name']} base config must be {CONFIG_REL}")
    for key, obj in objects.items():
        if obj.get("isa") != "XCBuildConfiguration":
            continue
        if "DEVELOPMENT_TEAM" in obj["buildSettings"]:
            errors.append(f"build configuration {key} sets DEVELOPMENT_TEAM; it must come from xcconfig")
        if key not in project_configs and "baseConfigurationReference" in obj:
            errors.append(f"target build configuration {key} must not set its own baseConfigurationReference")
    return errors


def without_parameterization(obj, xcconfig_ids):
    """Returns a copy of one pbxproj object minus the signing parameterization."""
    isa = obj.get("isa")
    if isa == "XCBuildConfiguration":
        return {**{k: v for k, v in obj.items() if k != "baseConfigurationReference"},
                "buildSettings": {k: v for k, v in obj["buildSettings"].items() if k not in PARAM_KEYS}}
    if isa == "PBXGroup":
        return {**obj, "children": [c for c in obj["children"] if c not in xcconfig_ids]}
    return obj


def normalized(objects):
    """Drops the parameterization so the rest can be compared to upstream."""
    xcconfig_ids = {k for k, o in objects.items()
                    if o.get("isa") == "PBXFileReference" and o.get("lastKnownFileType") == "text.xcconfig"}
    return {k: without_parameterization(o, xcconfig_ids) for k, o in objects.items() if k not in xcconfig_ids}


def appended(old, new):
    """The entries new adds to old, if new only inserts entries and keeps old's order; else None."""
    kept = set(old)
    return [x for x in new if x not in kept] if [x for x in new if x in kept] == old else None


def without(obj, key):
    return {k: v for k, v in obj.items() if k != key}


def project_paths(objects, key=None, parent=""):
    """App-relative paths of groups and file references reachable from the main group. A path is
    None when it is absolute or escaping, uses a source tree other than <group> or SOURCE_ROOT,
    sits under such a group, or is reachable from more than one group."""
    if key is None:
        key = next(o for o in objects.values() if o.get("isa") == "PBXProject")["mainGroup"]
    obj = objects.get(key, {})
    tree, rel = obj.get("sourceTree"), obj.get("path")
    base = parent if tree == "<group>" else "" if tree == "SOURCE_ROOT" else None
    if base is None or (rel is not None and not is_plain_relative(rel)):
        path = None
    else:
        path = "/".join(p for p in (base, rel) if p)
    found = {key: path}
    for child in obj.get("children", []) if obj.get("isa") == "PBXGroup" else []:
        below = project_paths(objects, child, path) if path is not None else {child: None}
        found = {**found, **{k: None if k in found else v for k, v in below.items()}}
    return found


def feature_delta_errors(base, current, new_files):
    """The feature may only add Swift file references and their build files, insert them into
    groups and sources phases, and change version keys (plus the microphone key on the watch)."""
    errors = []
    if removed := sorted(set(base) - set(current)):
        errors.append(f"feature removes project objects: {', '.join(removed)}")
    added = {k: current[k] for k in set(current) - set(base)}
    swift = {rel for rel in new_files if rel.endswith(".swift")}
    paths = project_paths(current)
    # Each new reference must resolve through its parent groups to exactly one listed new Swift file.
    candidates = {k: paths.get(k) for k, o in added.items() if o.get("isa") == "PBXFileReference"
                  and set(o) <= FILE_REF_KEYS and o.get("sourceTree") in ("<group>", "SOURCE_ROOT")
                  and o.get("lastKnownFileType", "sourcecode.swift") == "sourcecode.swift"}
    resolved = [path for path in candidates.values() if path in swift]
    refs = {k for k, path in candidates.items() if path in swift and resolved.count(path) == 1}
    builds = {k for k, o in added.items() if o.get("isa") == "PBXBuildFile" and set(o) == {"isa", "fileRef"}
              and o["fileRef"] in refs}
    errors += [f"feature adds a disallowed project object {k}" for k in sorted(set(added) - refs - builds)]
    watch = targets_by_name(current).get("WatchDot")
    watch_configs = set(current[watch["buildConfigurationList"]]["buildConfigurations"]) if watch else set()
    brand_configs = {cfg for target in targets_by_name(base).values()
                     if target.get("name") in EXPECTED_IDS
                     for cfg in base[target["buildConfigurationList"]]["buildConfigurations"]}
    placed = {"children": [], "files": []}
    for key in sorted(set(base) & set(current)):
        old, new = base[key], current[key]
        if old == new:
            continue
        field = {"PBXGroup": "children", "PBXSourcesBuildPhase": "files"}.get(old.get("isa"))
        if field and without(old, field) == without(new, field):
            extra = appended(old[field], new[field])
            if extra is not None and set(extra) <= (refs if field == "children" else builds):
                placed = {**placed, field: placed[field] + extra}
                continue
        if old.get("isa") == "XCBuildConfiguration" and without(old, "buildSettings") == without(new, "buildSettings"):
            before, after = old["buildSettings"], new["buildSettings"]
            changed = {k for k in set(before) | set(after) if before.get(k) != after.get(k)}
            display_name = "INFOPLIST_KEY_CFBundleDisplayName"
            brand_keys = {display_name} if key in brand_configs and display_name in before else set()
            allowed = FEATURE_SETTINGS | brand_keys | ({MICROPHONE_KEY} if key in watch_configs else set())
            if changed <= allowed and all(isinstance(after.get(k), str) and after[k].strip() for k in changed):
                continue
        errors.append(f"feature changes project object {key} beyond reviewed additions")
    for field, pool, what in (("children", refs, "file reference"), ("files", builds, "build file")):
        if sorted(placed[field]) != sorted(pool):
            errors.append(f"each new {what} must be added exactly once")
    return errors


def check_project(app, upstream, feature=None):
    text = (app / PBXPROJ).read_text(encoding="utf-8")
    errors = [f"pbxproj still contains {s!r}" for s in FORBIDDEN_TEXT if s in text]
    base_text = feature["base"].decode("utf-8") if feature else text
    if feature:
        try:
            if featured(feature["base"], PBXPROJ, feature) != text.encode("utf-8"):
                errors.append("pbxproj differs from the reviewed base plus feature patch")
        except ValueError as error:
            errors.append(f"reviewed changes do not apply to the project base: {error}")
    try:
        whole = parse_pbxproj(text)
        base_whole = parse_pbxproj(base_text)
        current, base = whole["objects"], base_whole["objects"]
        original = parse_pbxproj(git(upstream, "cat-file", "blob", f"{PINNED_SHA}:{PBXPROJ}").decode())["objects"]
    except (ValueError, KeyError) as error:
        return errors + [f"pbxproj does not parse: {error}"]
    errors += check_bundle_ids(current)
    errors += check_relationships(current)
    errors += check_base_config(current, app)
    if normalized(base) != normalized(original):
        errors.append("pbxproj has structural changes beyond signing parameterization"
                      + (" in the reviewed base" if feature else ""))
    if feature:
        if without(whole, "objects") != without(base_whole, "objects"):
            errors.append("feature changes the project header")
        errors += feature_delta_errors(base, current, feature["new_files"])
    return errors


def xcconfig_values(path):
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$", line)
        if match:
            values[match.group(1)] = match.group(2)
    return values


def check_config(root):
    errors = []
    base = root / CONFIG_REL
    if not base.is_file():
        return [f"missing {CONFIG_REL}"]
    values = xcconfig_values(base)
    if values.get("DEVELOPMENT_TEAM", None) != "":
        errors.append(f"{CONFIG_REL} must keep DEVELOPMENT_TEAM empty")
    if values.get("WATCHDOT_BUNDLE_PREFIX") != PLACEHOLDER_PREFIX:
        errors.append(f"{CONFIG_REL} must keep the placeholder prefix {PLACEHOLDER_PREFIX}")
    # The include must be the last statement so local values override the placeholders.
    statements = [s for s in (l.strip() for l in base.read_text(encoding="utf-8").splitlines())
                  if s and not s.startswith("//")]
    if [s for s in statements if s.startswith("#")] != [LOCAL_INCLUDE] or statements[-1] != LOCAL_INCLUDE:
        errors.append(f"{CONFIG_REL} must end with {LOCAL_INCLUDE} and contain no other directive")
    ignore = root / ".gitignore"
    if not ignore.is_file() or LOCAL_REL not in ignore.read_text(encoding="utf-8").splitlines():
        errors.append(f".gitignore must list {LOCAL_REL}")
    local = root / LOCAL_REL
    if local.is_file():
        errors += check_local(xcconfig_values(local))
    return errors


def check_local(values):
    errors = []
    prefix = values.get("WATCHDOT_BUNDLE_PREFIX", "")
    if not re.fullmatch(r"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+", prefix) or \
            re.search(r"replace|example", prefix, re.IGNORECASE):
        errors.append(f"{LOCAL_REL}: WATCHDOT_BUNDLE_PREFIX must be your own reverse-DNS prefix")
    if not re.fullmatch(r"[A-Z0-9]{10}", values.get("DEVELOPMENT_TEAM", "")):
        errors.append(f"{LOCAL_REL}: DEVELOPMENT_TEAM must be a 10-character Apple team ID")
    return errors


def feature_summary(feature):
    if feature is None:
        return ""
    return (f", plus the reviewed feature patch ({len(feature['patches'])} files, "
            f"{len(feature['new_files'])} new, {len(feature['assets'])} assets)")


def main(argv=None):
    here = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=here, help="repository root")
    parser.add_argument("--upstream", type=Path, default=None,
                        help="pristine watch-dot git clone (default: ROOT/docs/prototype/watch-dot)")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    upstream = (args.upstream or root / "docs/prototype/watch-dot").resolve()
    app = root / "app"
    try:
        translations = load_translations(root)
    except (ValueError, KeyError, TypeError) as error:
        print(f"FAIL translation manifest is invalid: {error}")
        return 1
    try:
        insertions = load_insertions(root)
    except (ValueError, KeyError, TypeError) as error:
        print(f"FAIL insertion manifest is invalid: {error}")
        return 1
    try:
        feature = feature_patch.load_feature(root, PINNED_SHA)
    except (ValueError, KeyError, TypeError, UnicodeDecodeError) as error:
        print(f"FAIL feature manifest is invalid: {error}")
        return 1
    errors = (check_provenance(app, upstream, translations, insertions, feature)
              + check_project(app, upstream, feature) + check_config(root))
    for error in errors:
        print(f"FAIL {error}")
    if errors:
        return 1
    mode = "local override present" if (root / LOCAL_REL).is_file() else "placeholder config only"
    count = sum(len(entries) for entries in translations.values())
    blocks = sum(len(entries) for entries in insertions.values())
    print(f"OK app/ matches {PINNED_SHA[:12]} apart from signing parameterization, "
          f"{count} reviewed English replacements in {len(translations)} files"
          f"{f' and {blocks} Debug-simulator-only insertions' if blocks else ''}"
          f"{feature_summary(feature)} ({mode})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
