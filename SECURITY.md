# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/ChinmayShringi/watch-dot-voice/security/advisories/new)
(Security tab > Report a vulnerability). Do not open a public issue. Include the affected commit,
reproduction steps and the impact you expect. This is a personal, best-effort project with no
guaranteed response time.

Issues in OpenAI's or Apple's services belong with those vendors' own programs.

## Scope and design

| Area | Behavior |
|---|---|
| Sign-in | OAuth 2.0 authorization code with PKCE, `state` and `nonce`, using a loopback listener owned by the iPhone app. The ID token is validated before use. |
| Credentials | Stored in the Keychain on each device and moved iPhone to Watch over WatchConnectivity only after validation. Never logged, never written to files, never placed in URLs. |
| Network | Authenticated HTTPS requests go only to `auth.openai.com` and `chatgpt.com`. Avatar images use a separate, credential-free connection to `cdn.openai.com`. Neither transport follows redirects, and response sizes are capped. |
| Errors | Users see fixed messages. Response bodies, challenge pages, tokens and account IDs are never shown or logged. |
| Voice | Recorded only in the foreground, at most 60 s and 2 MB. Near-silent recordings are rejected before upload (a loudness threshold, not speech detection). The audio file has complete file protection, is deleted after use, and its upload is never retried automatically. Capture stops when the app becomes inactive; a transcription already under way may finish and send, but stops if the app moves to the background or the sign-in changes. An unsent transcript is kept in memory only. |
| Screen privacy | Conversation text, drafts, transcripts and account details are hidden in Always On, while the app is inactive and under privacy redaction. Hidden content is removed from the accessibility tree and ignores taps. |
| Sending | One request per attempt, with one client turn ID saved as a receipt first. When the outcome is uncertain, the app only reads back, looking for the message by its request ID, and never resends automatically; resending takes an explicit retry. The endpoints are undocumented, so server-side deduplication is not assumed: this lowers the risk of a duplicate message but cannot rule it out. |

## Avatar catalog

`chatgpt.com/backend-api/pets` is a private, undocumented endpoint, not a supported OpenAI API.
It uses the existing account session. Image requests carry no authorization or account headers,
use no cookies, and accept only validated PNG or WebP sprite sheets from the allowed CDN host.
Catalog URLs remain in memory. Cached artwork and names are isolated by account, excluded from
backups, and cleared on sign-out or account changes. A failed refresh leaves local appearances
available. Selecting an avatar changes only this app, with no write to the OpenAI avatar service.

## Supported versions

Only the latest commit on `main` is supported.
