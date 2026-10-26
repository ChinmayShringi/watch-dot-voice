# Avatar selection

Open **Options > Change Avatar** to browse the catalog available through your existing ChatGPT
sign-in. The app fetches the catalog when the picker opens and downloads artwork as you browse.
Downloaded artwork is cached per account; the selected avatar remains available offline. The
catalog is a private OpenAI endpoint and can change without notice. No OpenAI artwork is shipped
in this repository.

Pebble, Orbit and Pixel are drawn in SwiftUI and always available. You may also supply a local
`AvatarAtlas` image, named after your connected Dot. A saved choice is cosmetic and never changes
which Dot the app talks to or your avatar in OpenAI apps. Existing local sprite choices are kept
separate from downloaded avatars.

## Optional local artwork

### Atlas format

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

### Adding your own

1. Use artwork you have the right to use. Don't commit artwork you may not redistribute.
2. Put the PNG at the path above, then assign it to the imageset. Either open
   `app/WatchDotApp/Assets.xcassets` in Xcode, select **AvatarAtlas** and drag the PNG onto its
   empty slot, or add `"filename": "AvatarAtlas.png"` to the single entry in `images` in the
   imageset's `Contents.json`. The public imageset names no file, so a build without art has no
   missing-image warning.
3. Build. The sprite now appears in **Options > Change Avatar**.

The exact PNG path above is git-ignored, so it stays local. The provenance checker still reports the
PNG as an extra file and the edited `Contents.json` as a difference, which is expected for a local
build. If you fork the project with your own redistributable art, remove the ignore rule and record
the art as a feature asset with `docs/scripts/record_feature.py`.
