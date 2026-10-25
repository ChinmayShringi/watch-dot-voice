# Setup

> The ChatGPT endpoints this app uses are non-public and undocumented. They are experimental, not
> supported by OpenAI, and may stop working at any time. See the notice in the
> [README](../README.md).

## 1. Prerequisites

- **Full Xcode** with the iOS and watchOS platforms. Command Line Tools alone can't build the
  Watch or iPhone targets.
- **An iPhone** on iOS 17 or later with Developer Mode on, paired with an **Apple Watch** on
  watchOS 10 or later.
- **An Apple ID** added in Xcode > Settings > Accounts. A free Personal Team works; its
  provisioning profiles expire after 7 days, after which you rebuild and reinstall.
- **A ChatGPT account** with Dot access. Sign in with the account or workspace that owns your Dot:
  any other account finds no Dot (HTTP 404).

## 2. Signing

The committed `docs/config/WatchDot.xcconfig` holds placeholders only. Put your values in the
git-ignored override:

```bash
cp docs/config/WatchDot.local.xcconfig.example docs/config/WatchDot.local.xcconfig
```

```
WATCHDOT_BUNDLE_PREFIX = com.<your-reverse-domain>.watchdot
DEVELOPMENT_TEAM = <YOUR_10_CHAR_TEAM_ID>
```

The bundle IDs derive from the prefix:

- iPhone: `<prefix>`
- Watch: `<prefix>.watchkitapp`
- Complication: `<prefix>.watchkitapp.launcher`

Choose the prefix once. Changing it later creates a new app.

## 3. Checks

```bash
git clone https://github.com/Torcata/watch-dot docs/prototype/watch-dot
git -C docs/prototype/watch-dot checkout --detach 0ca53cc050017533e5ed8aef0436fc32e20f2ba1
python3 -I docs/scripts/check_app.py
python3 -I -m unittest discover -s docs/scripts -v
swift test --package-path app
```

Simulator builds (keep ad-hoc signing on, because unsigned simulator apps can fail Keychain
access with OSStatus -34018):

```bash
xcodebuild -project app/WatchDot.xcodeproj -scheme WatchDotPhone -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

```bash
xcodebuild -project app/WatchDot.xcodeproj -scheme WatchDot -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

## 4. Install on devices

1. **Pair the Watch with Xcode.** In recent Xcode releases, start pairing from Device Hub > Add >
   Pair Nearby Device. On the Watch, open Settings > Privacy & Security > Developer Mode, scroll
   to **Devices**, select your Mac, and enter the PIN Xcode shows.
2. **Build the Watch app.** Keep the Watch unlocked. Build the **WatchDot** scheme to the physical
   Watch once, so Xcode registers it and creates profiles that include it.
3. **Build the iPhone app.** Build and run **WatchDotPhone** on the iPhone. If the profiles
   changed, clean first so the embedded Watch app is re-signed.
4. **Install on the Watch.** If installing from the iPhone's Watch app doesn't complete, run the
   **WatchDot** scheme on the Watch directly.

## 5. First sign-in

1. Open the app on the Watch and the iPhone.
2. Tap **Continue with ChatGPT** on either device and finish signing in on the iPhone. Enter your
   password only on OpenAI's own page.
3. Once the Watch has authorized and connected to your Dot, the home screen shows your avatar.

## 6. Use it

- **Talk.** The home screen is your avatar. Tap it to start recording and tap again to send; the
  first tap asks for microphone access. If you deny it, allow it later in the iPhone's Watch app,
  under Privacy. While recording, the status shows the elapsed time and "Tap to send". Tap
  **Cancel** to discard a recording. If the app becomes inactive while you are recording, for
  example when the screen dims after you lower your wrist, the recording stops and nothing is
  sent. A recording you have already sent keeps transcribing while the app is inactive and is
  sent; if the app moves to the background first, it is cancelled and you see a message. This
  timing has not been tested on a physical Watch.
- **Read replies.** A reply opens full screen. Scroll with the Digital Crown, then tap **Done** or
  the back-to-avatar control.
- **Everything else.** Tap the **Options** button (top left):

  | Item | Purpose |
  |---|---|
  | Type a Message | Type or dictate with the system keyboard. This is the upstream text chat. |
  | History | The full conversation |
  | Change Avatar | Page with the Crown, then tap **Choose** |
  | Settings | Account and connection |

  Options is unavailable while a voice message is being recorded, transcribed or sent.
- **Recover a message.** If a message is pending or failed, the status says **Review message**.
  Tap it or the avatar to resume, check for a reply or discard it. Nothing is resent
  automatically.
- **Privacy.** In Always On and whenever the app is inactive, conversation text, drafts and
  account details are hidden.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Primary Dot: HTTP 404" | You signed in with an account that has no Dot. Sign out and use the account that owns it. |
| The verification challenge message | OpenAI requested client verification. Wait, then try again; the app never tries to solve challenges. |
| App stops launching after a week | Free Personal Team profiles have expired. Rebuild and reinstall. |
| The microphone doesn't start | Check microphone access in the iPhone Watch app, and keep the app in the foreground while recording. |
