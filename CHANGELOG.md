# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Avatar-first Watch home screen. Text chat, history, avatar choice and settings move into a
  top-left Options menu.
- Tap-to-talk voice input, transcribed by ChatGPT dictation with the existing sign-in and sent
  through the existing receipt-based message path.
- Full-screen reply reader that never interrupts recording and closes only on an explicit action.
- Avatar picker with built-in Pebble, Orbit and Pixel avatars and optional user-supplied sprite art.
- English UI copy for all user-facing text.
- Portable signing: bundle IDs derive from one prefix in a git-ignored local xcconfig.
- A byte-exact provenance checker, a strict feature-patch recorder, and CI.

### Notes

- Experimental: relies on non-public ChatGPT endpoints with no official support.

### Upstream

- Based on [Torcata/watch-dot](https://github.com/Torcata/watch-dot) at `0ca53cc`.
