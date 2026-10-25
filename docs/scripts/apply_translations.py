#!/usr/bin/env python3
"""Regenerates changed app/ files as pinned upstream plus reviewed translations, insertions and feature patch.

All outputs are computed before any file is written, so a bad entry changes nothing.

Usage: python3 -I docs/scripts/apply_translations.py [--root DIR] [--upstream DIR]
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_app  # noqa: E402


def translated_outputs(root, upstream):
    """Returns {relative path: bytes}; raises ValueError before any write if anything is invalid.

    Includes the reviewed feature patch when docs/patches/avatar-voice.json exists, so regenerating
    never reverts recorded feature work (binary assets are not regenerated).
    """
    translations = check_app.load_translations(root)
    insertions = check_app.load_insertions(root)
    feature = check_app.feature_patch.load_feature(root, check_app.PINNED_SHA)
    patched = set(feature["patches"]) - set(feature["new_files"]) - {check_app.PBXPROJ} if feature else set()
    known = set(check_app.upstream_files(upstream))
    unknown = sorted((set(translations) | set(insertions) | patched) - known)
    if unknown:
        raise ValueError(f"manifest targets non-upstream files: {', '.join(unknown)}")
    outputs = {rel: check_app.featured(check_app.expected_content(
                   check_app.git(upstream, "cat-file", "blob", f"{check_app.PINNED_SHA}:{rel}"),
                   rel, translations, insertions), rel, feature)
               for rel in sorted(set(translations) | set(insertions) | patched)}
    if feature is None:
        return outputs
    created = {rel: check_app.featured(None, rel, feature) for rel in feature["new_files"]}
    return {**outputs, **created, check_app.PBXPROJ: check_app.featured(feature["base"], check_app.PBXPROJ, feature)}


def preflight(app, outputs):
    """Checks every destination before any write: no symlinks anywhere below app/, no directories
    in the way. Returns {rel: path}; raises ValueError so nothing is written on any failure."""
    destinations = {rel: check_app.feature_patch.contained(app, rel) for rel in outputs}
    if blocked := sorted(rel for rel, path in destinations.items() if path.exists() and not path.is_file()):
        raise ValueError(f"destination is not a regular file: {', '.join(blocked)}")
    return destinations


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--upstream", type=Path, default=None)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    upstream = (args.upstream or root / "docs/prototype/watch-dot").resolve()
    try:
        outputs = translated_outputs(root, upstream)
        destinations = preflight(root / "app", outputs)
    except (ValueError, KeyError, TypeError) as error:
        print(f"FAIL nothing written: {error}")
        return 1
    for rel, content in outputs.items():
        destinations[rel].parent.mkdir(parents=True, exist_ok=True)
        destinations[rel].write_bytes(content)
        print(f"wrote app/{rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
