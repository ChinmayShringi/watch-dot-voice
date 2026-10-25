# Custom sprite avatar

The repository ships no sprite artwork. The Watch app has three built-in avatars (Pebble, Orbit and
Pixel), drawn in SwiftUI. It adds a sprite avatar, named after your connected Dot, only if an image
named `AvatarAtlas` is in the Watch app's asset catalog. Without one, a saved sprite choice falls back
to Pebble. The choice is stored locally and is cosmetic: it never changes which Dot the app talks to.

## Atlas format

| Property | Value |
|---|---|
| File | `app/WatchDotApp/Assets.xcassets/AvatarAtlas.imageset/AvatarAtlas.png` |
| Size | 1536 x 2288 px PNG with transparency |
| Grid | 8 columns x 11 rows of 192 x 208 px cells |

Rows used by the app (zero-based), left to right:

| State | Row | Frames | Frame durations (ms) |
|---|---|---|---|
| Idle | 0 | 6 | 280, 110, 110, 140, 140, 320 |
| Failed | 5 | 8 | 140 x 7, 240 |
| Listening | 6 | 6 | 150 x 5, 260 |
| Working | 7 | 6 | 120 x 5, 220 |
| Replied | 8 | 6 | 150 x 5, 280 |

The authoritative values are in `app/Sources/WatchDotCore/AvatarAnimation.swift`.

## Adding your own

1. Use artwork you have the right to use. Don't commit artwork you may not redistribute.
2. Put the PNG at the path above. The imageset's `Contents.json` already names it.
3. Build. The sprite now appears in **Options > Change Avatar**.

The exact PNG path above is git-ignored, so it stays local. The provenance checker still reports it
as an extra file, which is expected for a local build. If you fork the project with your own
redistributable art, remove the ignore rule and record the art as a feature asset with
`docs/scripts/record_feature.py`.
