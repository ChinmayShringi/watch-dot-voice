#!/usr/bin/env python3
"""Records the reviewed avatar-voice feature: app/ minus (upstream + translations + insertions).

Writes docs/patches/avatar-voice/avatar-voice.patch and docs/patches/avatar-voice.json, pinning the
patch, the pre-feature project base and every new asset by SHA256. Run only once the sources are
reviewed; check_app.py then fails on any later drift. Nothing is written if anything is unexpected.

Usage: python3 -I docs/scripts/record_feature.py [--root DIR] [--upstream DIR] [--artwork FILE]

With assets present, the artwork source record comes from --artwork, or else from the one JSON
manifest in docs/assets/ whose png_sha256 matches a recorded asset.
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_app  # noqa: E402
import feature_patch  # noqa: E402

PATCH_REL = "docs/patches/avatar-voice/avatar-voice.patch"
BASE_REL = "docs/patches/avatar-voice/base-project.pbxproj"
ASSETS_REL = "docs/assets"


def recorded(root, upstream, artwork_rel):
    """Returns (patch text, manifest dict); raises ValueError on any file it cannot classify."""
    app = root / "app"
    translations = check_app.load_translations(root)
    insertions = check_app.load_insertions(root)
    known = check_app.upstream_files(upstream)
    diffs = []
    for rel in sorted(known):
        if rel == "NOTICE":
            continue  # Append-only, checked separately.
        if rel == check_app.PBXPROJ:
            before = feature_patch.contained(root, BASE_REL).read_bytes()
        else:
            original = check_app.git(upstream, "cat-file", "blob", f"{check_app.PINNED_SHA}:{rel}")
            before = check_app.expected_content(original, rel, translations, insertions)
        local = feature_patch.contained(app, rel)
        if not local.is_file():
            raise ValueError(f"feature may not delete upstream file app/{rel}")
        if local.read_bytes() == before:
            continue  # Unchanged, possibly binary.
        diffs.append(feature_patch.unified_diff(rel, before.decode("utf-8"), local.read_text(encoding="utf-8")))
    new_files, assets = [], []
    for path in sorted(app.rglob("*")):
        rel = path.relative_to(app).as_posix()
        if check_app.IGNORED_PARTS & set(path.parts):
            continue
        if path.is_symlink():
            raise ValueError(f"symlink not allowed: app/{rel}")
        if not path.is_file() or rel in known:
            continue
        if feature_patch.allowed_new_file(rel):
            new_files.append(rel)
            diffs.append(feature_patch.unified_diff(rel, None, path.read_text(encoding="utf-8")))
        elif rel.startswith(feature_patch.ASSET_DIR) and rel.endswith(".png"):
            assets.append({"file": rel, "sha256": feature_patch.sha256(path.read_bytes())})
        else:
            raise ValueError(f"unreviewable extra file app/{rel}")
    patch = "".join(diffs)
    base = feature_patch.contained(root, BASE_REL).read_bytes()
    manifest = {
        "upstream": check_app.PINNED_SHA,
        "patch": PATCH_REL, "patch_sha256": feature_patch.sha256(patch.encode("utf-8")),
        "project_base": BASE_REL, "project_base_sha256": feature_patch.sha256(base),
        "new_files": new_files, "assets": assets,
        "artwork": artwork_record(artwork_manifest(root, artwork_rel, assets), assets) if assets else None,
    }
    return patch, manifest


def artwork_manifest(root, artwork_rel, assets):
    """The explicit --artwork file, or the single docs/assets manifest matching a recorded asset."""
    if artwork_rel is not None:
        return feature_patch.contained(root, artwork_rel)
    digests = {entry["sha256"] for entry in assets}
    folder = root / ASSETS_REL
    matches = [path for path in sorted(folder.glob("*.json")) if not path.is_symlink()
               and json.loads(path.read_text(encoding="utf-8")).get("png_sha256") in digests] \
        if folder.is_dir() and not folder.is_symlink() else []
    if len(matches) != 1:
        raise ValueError(f"expected one {ASSETS_REL}/*.json manifest matching the assets, found {len(matches)}")
    return matches[0]


def artwork_record(path, assets):
    """Maps Codex's atlas manifest to the checker's artwork record; the atlas PNG must match it."""
    source = json.loads(path.read_text(encoding="utf-8"))
    if source["png_sha256"] not in {entry["sha256"] for entry in assets}:
        raise ValueError(f"no asset matches png_sha256 in {path.name}")
    return {"asset": source["source_url"].rsplit("/", 1)[-1], "sha256": source["source_sha256"],
            "width": source["size"][0], "height": source["size"][1],
            "cell": list(source["cell_size"]), "license": source["rights"]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--upstream", type=Path, default=None)
    parser.add_argument("--artwork", default=None)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    upstream = (args.upstream or root / "docs/prototype/watch-dot").resolve()
    try:
        if root.is_symlink() or (root / "app").is_symlink():
            raise ValueError("root and app/ must not be symlinks")
        patch, manifest = recorded(root, upstream, args.artwork)
        outputs = {feature_patch.contained(root, PATCH_REL): patch,
                   feature_patch.contained(root, feature_patch.FEATURE_REL): json.dumps(manifest, indent=2) + "\n"}
        if blocked := [str(path) for path in outputs if path.exists() and not path.is_file()]:
            raise ValueError(f"destination is not a regular file: {', '.join(blocked)}")
        # Validate exactly as the checker will before writing anything.
        feature_patch.parse_patch(patch)
        feature_patch.validated_artwork(manifest["artwork"], manifest["assets"])
    except (ValueError, KeyError, TypeError, UnicodeDecodeError, OSError) as error:
        print(f"FAIL nothing written: {error}")
        return 1
    for path, text in outputs.items():
        path.write_text(text, encoding="utf-8")
    print(f"wrote {PATCH_REL} ({manifest['patch_sha256'][:12]}) and {feature_patch.FEATURE_REL}: "
          f"{len(manifest['new_files'])} new files, {len(manifest['assets'])} assets")
    return 0


if __name__ == "__main__":
    sys.exit(main())
