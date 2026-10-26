# Rillby branding

Rillby, pronounced RILL-bee, was formerly named Watch Dot Voice. The repository remains
`watch-dot-voice`, and the Xcode project, targets, schemes, bundle identifiers and protocol names
retain their existing technical names.

The icon is original artwork generated with OpenAI imagegen on 2026-10-25 without a reference
image: an ivory companion mark with two charcoal eyes on a warm teal background. It is distributed
under the project's [GPL-3.0-only license](../LICENSE). This creation record does not imply
endorsement by Apple or OpenAI.

The generated opaque RGB PNG was 1254 by 1254 pixels. Apple's `sips` resampled it to 1024 by 1024
for the existing iPhone, Watch and complication asset catalogs. It is a flat PNG, not a layered
Icon Composer asset. No outer mask is baked into the artwork; the system supplies platform masks.
Ancillary PNG metadata was removed without changing the IDAT image data; the strict validator
permits only IHDR, IDAT and IEND chunks in an opaque RGB image without alpha.

[The icon manifest](branding/icon.json) records the exact upstream and replacement SHA-256 hashes
for all three assets. The app icon is separate from the optional custom sprite avatar described in
[custom-avatar.md](custom-avatar.md).
