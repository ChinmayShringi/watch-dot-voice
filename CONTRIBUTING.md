# Contributing

Thanks for helping. This project keeps a strict, checkable record of how it differs from upstream,
so the workflow is slightly different from a typical app.

## Ground rules

- Open an issue before large changes so the design can be agreed first.
- One logical change per pull request, with tests.
- [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `refactor:`,
  `docs:`, `test:`, `chore:`, `perf:`, `ci:`.
- Never commit credentials, team IDs, device identifiers, logs from real accounts, or artwork you
  may not redistribute.

## How a change is recorded

`app/` must always equal the pinned upstream commit plus these reviewed layers, in order:

1. `docs/translation/en-replacements.json`: exact literal replacements.
2. `docs/patches/avatar-voice/avatar-voice.patch`: one strict unified diff (exact positions, no
   fuzz), pinned by SHA256 in `docs/patches/avatar-voice.json` together with the pre-feature project
   file.

After editing anything under `app/`:

```bash
python3 -I docs/scripts/record_feature.py   # re-record the feature patch from app/
python3 -I docs/scripts/check_app.py        # must print OK
python3 -I -m unittest discover -s docs/scripts -v
swift test --package-path app
```

The recorder writes nothing if it finds a file it cannot classify. New Swift files may live only in
`Sources/WatchDotCore/`, `Tests/WatchDotCoreTests/` or `WatchDotApp/`. Their project references
must sit in groups that resolve to exactly those paths. The only build settings a change may touch
are `CURRENT_PROJECT_VERSION`, `MARKETING_VERSION`, and the Watch app's microphone usage
description.

## Code style

- Match the surrounding Swift. Prefer value types and immutable updates.
- Handle every error explicitly and show users fixed, non-sensitive messages.
- Keep files small and focused.
- Accessibility is not optional: provide VoiceOver labels, hints and values that match the current
  state, and respect Reduce Motion and Always On.
- Wrap conversation, draft and account content in `.sensitiveContent()` so it is hidden in Always
  On, while inactive and under privacy redaction. Apply it to the content itself (for example the
  stack of text inside a `ScrollView`), never to a native container such as `NavigationStack`,
  `ScrollView` or a sheet. For a full-screen placeholder, overlay it on the container using the same
  visibility policy. Keep titles and toolbars the same while content is hidden.

## Pull requests

- Describe the user-visible change and how you verified it: simulator, device, and which watch size.
- CI must pass.
- Screenshots help for UI changes.
