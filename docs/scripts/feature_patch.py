"""Reviewed feature patch for app/: strict unified diffs plus a manifest of new files and assets.

The manifest (docs/patches/avatar-voice.json) pins the patch and the pre-feature project file by
SHA256. Hunks apply only at their recorded positions with exact context (no fuzz, no offsets).
"""
import hashlib
import json
import re
from difflib import SequenceMatcher
from pathlib import PurePosixPath
from typing import NamedTuple

FEATURE_REL = "docs/patches/avatar-voice.json"
MANIFEST_KEYS = {"upstream", "patch", "patch_sha256", "project_base", "project_base_sha256",
                 "new_files", "assets", "artwork"}
ARTWORK_KEYS = {"asset", "sha256", "width", "height", "cell", "license"}
PATCH_DIR = "docs/patches/"
NEW_SOURCE_DIRS = ("Sources/WatchDotCore/", "Tests/WatchDotCoreTests/", "WatchDotApp/")
ASSET_DIR = "WatchDotApp/Assets.xcassets/"
# Build and editor state the checker skips when scanning; never valid in a declared feature path.
IGNORED_PARTS = {".DS_Store", "xcuserdata", "DerivedData", ".build", ".swiftpm"}
PROTECTED = {"NOTICE", "LICENSE"}  # NOTICE is append-only; LICENSE never changes.
HUNK_HEADER = re.compile(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
NO_NEWLINE = "\\ No newline at end of file"
SHA256 = re.compile(r"[0-9a-f]{64}")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


class Hunk(NamedTuple):
    old_start: int
    old_len: int
    new_start: int
    new_len: int
    lines: tuple  # (tag, text) pairs; text keeps its "\n" unless the file ends without one


class FilePatch(NamedTuple):
    created: bool
    hunks: tuple


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def split_lines(text):
    """Splits on "\\n" only, keeping it; a final line without a newline stays as is."""
    parts = text.split("\n")
    return [p + "\n" for p in parts[:-1]] + ([parts[-1]] if parts[-1] else [])


def parse_patch(text):
    """Returns {path: FilePatch}; raises ValueError on anything outside the strict format."""
    if not text.endswith("\n"):
        raise ValueError("patch must end with a newline")
    lines = text.split("\n")[:-1]
    files, i = {}, 0
    while i < len(lines):
        old, new = lines[i], lines[i + 1] if i + 1 < len(lines) else ""
        rel = new[len("+++ b/"):]
        if not new.startswith("+++ b/") or old not in ("--- /dev/null", f"--- a/{rel}"):
            raise ValueError(f"patch line {i + 1}: expected a ---/+++ file header")
        if not is_plain_relative(rel) or rel in files:
            raise ValueError(f"patch line {i + 2}: invalid or repeated path {rel!r}")
        i += 2
        hunks = []
        while i < len(lines) and lines[i].startswith("@@"):
            hunk, i = parse_hunk(lines, i)
            hunks.append(hunk)
        if not hunks:
            raise ValueError(f"patch for {rel} has no hunks")
        files = {**files, rel: FilePatch(old == "--- /dev/null", tuple(hunks))}
    return files


def parse_hunk(lines, i):
    match = HUNK_HEADER.fullmatch(lines[i])
    if not match:
        raise ValueError(f"patch line {i + 1}: malformed hunk header")
    old_start, old_len, new_start, new_len = (int(g) if g is not None else 1 for g in match.groups())
    body, olds, news, at = [], 0, 0, i + 1
    while olds < old_len or news < new_len:
        if at >= len(lines) or lines[at][:1] not in (" ", "-", "+"):
            raise ValueError(f"patch line {at + 1}: hunk is truncated or has an invalid line")
        tag, text = lines[at][:1], lines[at][1:]
        at += 1
        ends_file = at < len(lines) and lines[at] == NO_NEWLINE
        body.append((tag, text if ends_file else text + "\n"))
        at += 1 if ends_file else 0
        olds, news = olds + (tag != "+"), news + (tag != "-")
    if (olds, news) != (old_len, new_len):
        raise ValueError(f"patch line {i + 1}: hunk line counts do not match its header")
    return Hunk(old_start, old_len, new_start, new_len, tuple(body)), at


def apply_file(original, file_patch):
    """Applies one file's hunks to text (None when the file must not exist yet)."""
    if file_patch.created != (original is None):
        raise ValueError("feature patch creates an existing file" if file_patch.created
                         else "feature patch modifies a missing file")
    source = split_lines(original or "")
    out, pos, delta = [], 0, 0
    for hunk in file_patch.hunks:
        start = hunk.old_start - 1 if hunk.old_len else hunk.old_start
        old = [text for tag, text in hunk.lines if tag != "+"]
        if start < pos or start > len(source):
            raise ValueError(f"hunk at line {hunk.old_start} is out of order or out of range")
        if hunk.new_start != start + delta + (1 if hunk.new_len else 0):
            raise ValueError(f"hunk at line {hunk.old_start} has an inconsistent new position")
        if source[start:start + len(old)] != old:
            raise ValueError(f"hunk at line {hunk.old_start} does not match exactly")
        out += source[pos:start] + [text for tag, text in hunk.lines if tag != "-"]
        pos, delta = start + len(old), delta + hunk.new_len - hunk.old_len
    return "".join(out + source[pos:])


def unified_diff(rel, before, after):
    """Records before -> after (before None for a new file) in the strict format, or "" if equal."""
    if before == after:
        return ""
    a, b = split_lines(before or ""), split_lines(after)
    out = ["--- /dev/null" if before is None else f"--- a/{rel}", f"+++ b/{rel}"]
    for group in SequenceMatcher(None, a, b, autojunk=False).get_grouped_opcodes(3):
        i1, i2, j1, j2 = group[0][1], group[-1][2], group[0][3], group[-1][4]
        out.append(f"@@ -{i1 + 1 if i2 > i1 else i1},{i2 - i1} +{j1 + 1 if j2 > j1 else j1},{j2 - j1} @@")
        for tag, x1, x2, y1, y2 in group:
            out += marked(" ", a[x1:x2]) if tag == "equal" else []
            out += marked("-", a[x1:x2]) if tag in ("replace", "delete") else []
            out += marked("+", b[y1:y2]) if tag in ("replace", "insert") else []
    return "\n".join(out) + "\n"


def marked(tag, lines):
    return [part for line in lines for part in
            ([tag + line[:-1]] if line.endswith("\n") else [tag + line, NO_NEWLINE])]


def is_plain_relative(rel):
    """True for a normalized POSIX path inside the tree: no absolute, '.', '..' or backslash parts."""
    path = PurePosixPath(rel)
    return (isinstance(rel, str) and rel != "" and "\\" not in rel and not path.is_absolute()
            and str(path) == rel and all(part not in (".", "..") for part in path.parts))


def contained(root, rel):
    """root/rel, provided rel is plain and neither root nor any existing component below it is a
    symlink (dangling ones included), so reads and writes stay inside root."""
    if not is_plain_relative(rel) or root.is_symlink():
        raise ValueError(f"unsafe path {rel!r}")
    path = root
    for part in PurePosixPath(rel).parts:
        path = path / part
        if path.is_symlink():
            raise ValueError(f"symlink in path {rel}")
    return path


def allowed_new_file(rel):
    return not IGNORED_PARTS & set(PurePosixPath(rel).parts) and (
        (rel.endswith(".swift") and rel.startswith(NEW_SOURCE_DIRS))
        or (rel.startswith(ASSET_DIR) and PurePosixPath(rel).name == "Contents.json"))


def png_size(data):
    """Returns (width, height) from a PNG header, or None if the bytes are not a PNG."""
    if len(data) < 24 or not data.startswith(PNG_SIGNATURE) or data[12:16] != b"IHDR":
        return None
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


def load_feature(root, pinned_sha):
    """Reads and cross-checks the feature manifest; None if absent, ValueError if invalid."""
    path = root / FEATURE_REL
    if not path.is_file():
        return None
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or set(data) != MANIFEST_KEYS or data["upstream"] != pinned_sha:
        raise ValueError(f"{FEATURE_REL} must be an object with keys {sorted(MANIFEST_KEYS)} "
                         f"targeting {pinned_sha}")
    patch = pinned_file(root, data["patch"], data["patch_sha256"], ".patch")
    base = pinned_file(root, data["project_base"], data["project_base_sha256"], ".pbxproj")
    patches = parse_patch(patch.decode("utf-8"))
    new_files, assets = data["new_files"], data["assets"]
    if not isinstance(new_files, list) or not all(map(is_plain_relative, new_files)) \
            or len(set(new_files)) != len(new_files):
        raise ValueError("new_files must be a list of unique plain relative paths")
    if bad := [rel for rel in new_files if not allowed_new_file(rel)]:
        raise ValueError(f"new files outside the reviewed locations: {', '.join(bad)}")
    created = {rel for rel, fp in patches.items() if fp.created}
    if created != set(new_files):
        raise ValueError("new_files must list exactly the files the patch creates")
    if touched := sorted(PROTECTED & set(patches)):
        raise ValueError(f"feature patch must not touch {', '.join(touched)}")
    return {"patches": patches, "new_files": new_files, "base": base,
            "assets": validated_assets(assets, new_files), "artwork": validated_artwork(data["artwork"], assets)}


def pinned_file(root, rel, digest, suffix):
    if not is_plain_relative(rel) or not rel.startswith(PATCH_DIR) or not rel.endswith(suffix) \
            or not isinstance(digest, str) or not SHA256.fullmatch(digest):
        raise ValueError(f"{rel!r} must be a {suffix} file under {PATCH_DIR} with a SHA256")
    path = contained(root, rel)
    if not path.is_file():
        raise ValueError(f"missing {rel}")
    data = path.read_bytes()
    if sha256(data) != digest:
        raise ValueError(f"{rel} does not match its recorded SHA256")
    return data


def validated_assets(assets, new_files):
    if not isinstance(assets, list):
        raise ValueError("assets must be a list")
    for index, entry in enumerate(assets):
        ok = (isinstance(entry, dict) and set(entry) == {"file", "sha256"}
              and is_plain_relative(entry["file"]) and entry["file"].startswith(ASSET_DIR)
              and not IGNORED_PARTS & set(PurePosixPath(entry["file"]).parts)
              and ".imageset/" in entry["file"] and entry["file"].endswith(".png")
              and entry["file"] not in new_files
              and isinstance(entry["sha256"], str) and SHA256.fullmatch(entry["sha256"]))
        if not ok:
            raise ValueError(f"invalid asset #{index}")
    if len({entry["file"] for entry in assets}) != len(assets):
        raise ValueError("asset paths must be unique")
    return assets


def validated_artwork(artwork, assets):
    """Source record for the converted frames: required exactly when there are assets."""
    if not assets:
        if artwork is not None:
            raise ValueError("artwork must be null when there are no assets")
        return None
    ints = lambda *values: all(type(v) is int and v > 0 for v in values)  # noqa: E731
    ok = (isinstance(artwork, dict) and set(artwork) == ARTWORK_KEYS
          and isinstance(artwork["asset"], str) and artwork["asset"].endswith(".webp")
          and isinstance(artwork["sha256"], str) and SHA256.fullmatch(artwork["sha256"])
          and isinstance(artwork["license"], str) and artwork["license"].strip() != ""
          and isinstance(artwork["cell"], list) and len(artwork["cell"]) == 2
          and ints(artwork["width"], artwork["height"], *artwork["cell"])
          and artwork["width"] % artwork["cell"][0] == 0 and artwork["height"] % artwork["cell"][1] == 0)
    if not ok:
        raise ValueError("artwork must record asset, sha256, width, height, cell and license, "
                         "with the cell dividing the sheet")
    return artwork


def asset_errors(app, feature):
    """Each frame must match its SHA256 and be whole cells no larger than the source sheet."""
    errors = []
    artwork = feature["artwork"]
    for entry in feature["assets"]:
        try:
            path = contained(app, entry["file"])
        except ValueError as error:
            errors.append(f"feature asset is not a plain file: {error}")
            continue
        if not path.is_file():
            errors.append(f"missing feature asset: app/{entry['file']}")
            continue
        data = path.read_bytes()
        size = png_size(data)
        if sha256(data) != entry["sha256"]:
            errors.append(f"feature asset does not match its SHA256: app/{entry['file']}")
        elif size is None or size[0] % artwork["cell"][0] or size[1] % artwork["cell"][1] \
                or size[0] > artwork["width"] or size[1] > artwork["height"] or 0 in size:
            errors.append(f"feature asset is not whole {artwork['cell'][0]}x{artwork['cell'][1]} cells: "
                          f"app/{entry['file']}")
    return errors
