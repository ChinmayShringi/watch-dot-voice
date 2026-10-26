"""Reviewed public icon replacements, separate from private avatar artwork.

Only the three existing launcher PNGs may be replaced. A manifest pins both
upstream and replacement bytes; it is review evidence, not a claim of authorship.
"""
import json
import zlib

import feature_patch

MANIFEST_REL = "docs/branding/icon.json"
ICON_PATHS = frozenset({
    "PhoneDotApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
    "WatchDotApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
    "WatchDotComplication/Assets.xcassets/WatchDotIcon.imageset/WatchDotIcon.png",
})


def load(root):
    path = feature_patch.contained(root, MANIFEST_REL)
    if not path.exists():
        return {}
    return validate(json.loads(path.read_text(encoding="utf-8")))


def validate(data):
    if not isinstance(data, dict) or set(data) != {"schema", "provenance", "replacements"} \
            or type(data["schema"]) is not int or data["schema"] != 1:
        raise ValueError("branding manifest must have schema 1, provenance and replacements")
    provenance = data["provenance"]
    if not isinstance(provenance, dict) or set(provenance) != {"description", "license"} \
            or not all(isinstance(v, str) and v.strip() for v in provenance.values()):
        raise ValueError("branding provenance must state description and license")
    entries = data["replacements"]
    if not isinstance(entries, list) or len(entries) != len(ICON_PATHS):
        raise ValueError("branding must replace exactly the three approved icons")
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"file", "upstream_sha256", "sha256"} \
                or not isinstance(entry["file"], str) or entry["file"] not in ICON_PATHS \
                or not all(isinstance(entry[k], str) and feature_patch.SHA256.fullmatch(entry[k])
                           for k in ("upstream_sha256", "sha256")):
            raise ValueError("invalid branding replacement path or SHA256")
    if {entry["file"] for entry in entries} != ICON_PATHS:
        raise ValueError("branding paths must be unique and exactly the approved icons")
    return {entry["file"]: entry for entry in entries}


def verify(entry, original, replacement):
    if feature_patch.sha256(original) != entry["upstream_sha256"]:
        raise ValueError(f"branding upstream SHA256 mismatch: {entry['file']}")
    if feature_patch.sha256(replacement) != entry["sha256"]:
        raise ValueError(f"branding replacement SHA256 mismatch: {entry['file']}")
    validate_png(replacement)


def validate_png(data):
    """Only opaque RGB8 pixels: reject metadata, extra chunks and trailing payloads."""
    if len(data) > 8 * 1024 * 1024:
        raise ValueError("branding PNG exceeds the 8 MiB limit")
    if not data.startswith(feature_patch.PNG_SIGNATURE):
        raise ValueError("branding replacement must be a 1024x1024 PNG")
    offset, kinds, image_bytes, compressed = 8, (), 0, ()
    while offset < len(data):
        if len(kinds) >= 1024:
            raise ValueError("branding PNG contains too many chunks")
        if len(data) - offset < 12:
            raise ValueError("branding PNG has a truncated chunk")
        length = int.from_bytes(data[offset:offset + 4], "big")
        end = offset + 12 + length
        if end > len(data):
            raise ValueError("branding PNG chunk length exceeds file")
        kind, payload = data[offset + 4:offset + 8], data[offset + 8:end - 4]
        crc = int.from_bytes(data[end - 4:end], "big")
        if zlib.crc32(kind + payload) != crc:
            raise ValueError("branding PNG chunk CRC mismatch")
        if kind not in (b"IHDR", b"IDAT", b"IEND"):
            raise ValueError("branding PNG must contain only IHDR, IDAT and IEND chunks")
        if kind == b"IHDR":
            expected = (1024).to_bytes(4, "big") * 2 + bytes([8, 2, 0, 0, 0])
            if kinds or payload != expected:
                raise ValueError("branding replacement must be an opaque RGB8 1024x1024 PNG")
        elif not kinds or kinds[0] != b"IHDR":
            raise ValueError("branding PNG must begin with IHDR")
        elif kind == b"IEND":
            if payload or not image_bytes or end != len(data):
                raise ValueError("branding PNG has missing pixels or trailing data")
        else:
            image_bytes += length
            compressed = (*compressed, payload)
        kinds, offset = (*kinds, kind), end
    if not kinds or kinds[-1] != b"IEND":
        raise ValueError("branding PNG must end with IEND")
    validate_pixels(compressed)


def validate_pixels(parts):
    """Bound decompression and reject payloads hidden after the zlib pixel stream."""
    row_bytes = 1 + 1024 * 3
    expected = 1024 * row_bytes
    decoder = zlib.decompressobj()
    try:
        pixels = decoder.decompress(b"".join(parts), expected + 1)
    except zlib.error as error:
        raise ValueError("branding PNG has invalid compressed pixels") from error
    if len(pixels) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError("branding PNG has incomplete, oversized or trailing pixel data")
    if any(pixels[offset] > 4 for offset in range(0, expected, row_bytes)):
        raise ValueError("branding PNG has invalid row filters")
