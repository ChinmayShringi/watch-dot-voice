# Provenance of app/

- **Upstream:** https://github.com/Torcata/watch-dot (GPL-3.0-only)
- **Pinned commit:** `0ca53cc050017533e5ed8aef0436fc32e20f2ba1`
- **Import:** the tracked files at that commit, unmodified (the first commit in this repository).

## Reviewed layers

`docs/scripts/check_app.py` rebuilds every file from upstream plus the layers below, in order, and
requires a byte-for-byte match. Anything else fails: an extra file, a symlink, a missing file, or an
unreviewed project change.

| Layer | Record | Scope |
|---|---|---|
| Signing | Structural comparison of `project.pbxproj` against upstream | The upstream team ID is removed. Bundle IDs derive from `$(WATCHDOT_BUNDLE_PREFIX)`, and the project-level base configuration is `docs/config/WatchDot.xcconfig`. |
| English | `docs/translation/en-replacements.json` | 194 exact literal replacements in 11 sources and 3 tests, each with its expected match count. Protocol identifiers, OAuth parameters, headers, Keychain service names and Swift identifiers are unchanged. |
| Voice and avatar | `docs/patches/avatar-voice.json` pinning `avatar-voice/avatar-voice.patch` and `avatar-voice/base-project.pbxproj` by SHA256 | One unified diff, applied at exact positions with no fuzz. See below. |
| NOTICE | Append-only | The upstream text is unchanged, followed by a local-modifications section. |

## The feature patch

- **Changes to upstream files:** Core sign-in, session, conversation and Dot discovery files, the
  Watch app entry point, the Watch `Info.plist` (microphone usage description), and the project
  file.
- **New files:** Core sources for voice, animation, avatar appearance and reply presentation, with
  their tests; Watch views (home, reply reader, avatar picker, avatars) and the recorder; and the
  avatar imageset's `Contents.json`.
- **Project file:** the patch applies to the recorded pre-feature project file, which must itself
  pass the signing comparison. The checker allows only:
  - new Swift file references whose parent groups resolve to exactly the listed new files;
  - their build files, in a sources phase;
  - `CURRENT_PROJECT_VERSION` and `MARKETING_VERSION`;
  - the Watch target's microphone usage description.

  Bundle IDs, targets, signing and embedding are checked separately and stay unchanged.

## Artwork

No sprite artwork is included. See [custom-avatar.md](custom-avatar.md).
