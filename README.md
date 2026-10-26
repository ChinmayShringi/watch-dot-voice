# Rillby

Rillby, formerly Watch Dot Voice, lets you talk to your ChatGPT Dot from an Apple Watch: tap the
avatar, speak, and read the reply on your wrist. The repository remains `watch-dot-voice`.

[![CI](https://github.com/ChinmayShringi/watch-dot-voice/actions/workflows/ci.yml/badge.svg)](https://github.com/ChinmayShringi/watch-dot-voice/actions/workflows/ci.yml)
[![License: GPL-3.0-only](https://img.shields.io/badge/license-GPL--3.0--only-blue.svg)](LICENSE)

This is a fork of [Torcata/watch-dot](https://github.com/Torcata/watch-dot) (GPL-3.0-only), pinned at
`0ca53cc`. It adds English UI copy, portable signing, voice input with an animated avatar, and a
checker that verifies every byte of the app against upstream plus the reviewed changes.

> **Experimental and unofficial.** OpenAI publishes no Dot API. This app signs in with the Codex
> CLI's OAuth client and calls **non-public, undocumented** ChatGPT endpoints
> (`chatgpt.com/backend-api`), for Dot discovery, messaging and dictation. Nothing here is supported
> by OpenAI. There is no promise of stability, compatibility or continued access: any endpoint may
> change, be rate-limited or be blocked at any time, and the app will then stop working. Review
> OpenAI's terms before use, and use it at your own risk. Not affiliated with or endorsed by OpenAI
> or Apple.

## Features

- **Avatar-first.** The Watch home screen is a single large animated avatar with a one-line status.
  Everything else lives in the **Options** menu (top left): **Type a Message**, **History**,
  **Change Avatar** and **Settings**. The upstream text chat is still there, under Type a Message
  and History, but it is no longer the home screen.
- **Tap to talk.** Tap the avatar to record and tap again to send. The audio is transcribed by
  ChatGPT dictation with your existing sign-in. The transcript goes through the same send path as
  typed messages: one request per attempt, recorded first as a receipt. After a few idle seconds the
  avatar shows only
  "Tap to speak".
- **Full-screen replies.** A new reply opens in a scrollable reader (use the Digital Crown) and
  closes only with **Done** or the back-to-avatar control, so scrolling can never dismiss it or
  start a recording. Replies wait while you are recording, in a menu or in a sheet.
- **Choose an avatar.** Page through Pebble, Orbit and Pixel, plus an optional sprite you supply
  (see [docs/custom-avatar.md](docs/custom-avatar.md)). The choice is local and cosmetic; it never
  changes which Dot you talk to.
- **Private at a glance.** Conversation text, drafts and account details are hidden in Always On,
  while the app is inactive and under privacy redaction, for VoiceOver as well as on screen.
- **Recover from the home screen.** If a message is pending or failed, tap the avatar or
  **Review message** to resume, check for a reply or discard it. Nothing is resent
  automatically.
- **No API key.** It uses your ChatGPT subscription. There's no paid API and no relay server.
- **Watch first.** After a one-time sign-in on the iPhone, the watch talks to the Dot directly.
- **Careful with audio.** Recording stops at 60 seconds and happens only in the foreground.
  Near-silent recordings (below a simple loudness threshold, not speech detection) are rejected
  before upload. Each recording is deleted after use, and uploads are never retried
  automatically.
- **Accessible.** The avatar's VoiceOver label, hint and value follow the recording state.
  Animation pauses for Reduce Motion, Always On and inactive scenes, and History scrolls without
  animation. VoiceOver has not yet been checked on a physical Watch.

## Requirements

| | Minimum |
|---|---|
| Xcode | Full Xcode with the iOS and watchOS SDKs |
| iPhone | iOS 17 |
| Apple Watch | watchOS 10 |
| Account | A ChatGPT account with Dot access |
| Signing | Any Apple team (a free Personal Team works; its profiles last 7 days) |

## Quick start

```bash
git clone https://github.com/ChinmayShringi/watch-dot-voice.git
cd watch-dot-voice
cp docs/config/WatchDot.local.xcconfig.example docs/config/WatchDot.local.xcconfig
# Edit WatchDot.local.xcconfig: set WATCHDOT_BUNDLE_PREFIX and DEVELOPMENT_TEAM.
open app/WatchDot.xcodeproj
```

Build the **WatchDotPhone** scheme to your iPhone; the Watch app is embedded. Open **Rillby** and
tap **Continue with ChatGPT**. Xcode targets and schemes retain their `WatchDot` names. Full steps
are in [docs/setup.md](docs/setup.md).

## Repository layout

| Path | Contents |
|---|---|
| `app/` | The Xcode project: iPhone companion, Watch app, complication, and the `WatchDotCore` package |
| `docs/config/` | Signing placeholders and the template for your git-ignored local override |
| `docs/translation/`, `docs/patches/` | Every reviewed change to upstream, as manifests and one strict patch |
| `docs/scripts/` | The provenance checker, the feature recorder and their tests |
| `docs/` | [Setup](docs/setup.md), [architecture](docs/architecture.md), [provenance](docs/app-provenance.md), [branding](docs/branding.md), [custom avatars](docs/custom-avatar.md) |

## Verifying the tree

```bash
git clone https://github.com/Torcata/watch-dot docs/prototype/watch-dot
git -C docs/prototype/watch-dot checkout --detach 0ca53cc050017533e5ed8aef0436fc32e20f2ba1
python3 -I docs/scripts/check_app.py
python3 -I -m unittest discover -s docs/scripts -v
swift test --package-path app
```

`check_app.py` rebuilds `app/` from the pinned upstream plus the reviewed translations and the
recorded feature patch. It fails on any other byte, extra file,
symlink or unreviewed project change. See [CONTRIBUTING.md](CONTRIBUTING.md) for how changes are
recorded.

## Privacy

- **No analytics or telemetry,** and no data goes to any server other than OpenAI's.
- **Voice:** when you speak, the recording goes to OpenAI for transcription under your account. The
  local file is deleted afterwards.
- **Credentials** live in the Keychain and are never logged.

See [SECURITY.md](SECURITY.md).

## License

GPL-3.0-only, inherited from upstream. See [LICENSE](LICENSE) and [app/NOTICE](app/NOTICE). The OAuth
flow follows the protocol of [openai/codex](https://github.com/openai/codex) (Apache-2.0) as a
reference; no code is copied from it. The original generated Rillby icon uses the same GPL-3.0-only
license; its creation and file hashes are documented in [docs/branding.md](docs/branding.md).
