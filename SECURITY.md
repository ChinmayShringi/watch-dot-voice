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
| Network | HTTPS to `auth.openai.com` and `chatgpt.com` only, with no redirects followed on API calls and capped response sizes. |
| Errors | Users see fixed messages. Response bodies, challenge pages, tokens and account IDs are never shown or logged. |
| Voice | Recorded only in the foreground, at most 60 s and 2 MB. Near-silent recordings are rejected before upload (a loudness threshold, not speech detection). The audio file has complete file protection, is deleted after use, and its upload is never retried automatically. |
| Sending | One request per attempt, with one client turn ID saved as a receipt first. When the outcome is uncertain, the app only reads back, looking for the message by its request ID, and never resends automatically; resending takes an explicit retry. The endpoints are undocumented, so server-side deduplication is not assumed: this lowers the risk of a duplicate message but cannot rule it out. |

## Supported versions

Only the latest commit on `main` is supported.
