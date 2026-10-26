# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Original Rillby app icon for the iPhone, Watch and complication, with recorded creation and
  asset hashes. The artwork is distributed under GPL-3.0-only with the project.
- Avatar-first Watch home screen. Text chat, history, avatar choice and settings move into a
  top-left Options menu.
- Tap-to-talk voice input, transcribed by ChatGPT dictation with the existing sign-in and sent
  through the existing receipt-based message path.
- Full-screen reply reader that never interrupts recording and closes only on an explicit action.
- Avatar picker with built-in Pebble, Orbit and Pixel avatars and optional user-supplied sprite art.
- English UI copy for all user-facing text.
- Portable signing: bundle IDs derive from one prefix in a git-ignored local xcconfig.
- A byte-exact provenance checker, a strict feature-patch recorder, and CI.
- Home recovery: when a message is pending or failed, tapping the avatar or **Review message**
  opens the available actions (Resume Message, Check for Reply, Discard Unsent, Save Again). They
  reuse the existing retry rules; nothing is resent automatically.
- A shared privacy shield. History, Type a Message, voice error details, the reply reader, the
  avatar picker and account Settings hide their content in Always On, while the app is inactive,
  or under privacy redaction. Hidden content is also removed from VoiceOver and taps.
- History keeps your reading position when messages arrive and offers a **Latest** button. It
  follows new messages only while you are at the end.

### Changed

- Build 8 names the app **Rillby**, formerly Watch Dot Voice, in its display names, setup copy and
  complication. Bundle IDs, Xcode targets and schemes, saved data and protocol identifiers retain
  their existing names. The complication refresh revision advances to 7.
- The avatar's VoiceOver label, hint and value follow the recording state. While listening, the
  status line also says "Tap to send".
- A transcription already running now continues while the app is inactive, for example when the
  screen dims, and is sent. It is still cancelled if the app moves to the background (with a
  message), you sign out or the Dot changes. Recording itself stops when the app becomes
  inactive and now ends with "Recording was interrupted" instead of silently resetting. Capture
  never resumes on its own. How long watchOS keeps the app inactive after a wrist-down, before
  moving it to the background, has not been tested on a physical Watch.
- Voice errors offer **Dismiss**, or **Discard Transcript** when an unsent transcript is held. A
  held transcript is kept in memory only and is never sent without your action.
- History scrolls without animation and uses the system progress indicator, so it respects Reduce
  Motion.
- Settings shows the app version and plain connection wording. **Save again** is not offered when
  the saved chat could not be loaded.

### Notes

- Experimental: relies on non-public ChatGPT endpoints with no official support.
- The `WatchDotCore` suite has 193 tests.
- VoiceOver, real audio interruptions (calls, Siri) and wrist-down timing have not been verified
  on a physical Apple Watch.

### Upstream

- Based on [Torcata/watch-dot](https://github.com/Torcata/watch-dot) at `0ca53cc`.
