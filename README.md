# Tesla Notify

A macOS menu bar app + background daemon to overcome a Tesla limitation: there is no native WhatsApp app in Tesla, which makes it harder (and less safe) to stay up to date while driving.
It forwards inbound WhatsApp Desktop messages to iMessage so they can appear in your Tesla via your paired iPhone.

Optional: Tesla Fleet API integration can check whether someone is in the car. If enabled, messages are forwarded only when the car reports a user is present, so you are not bothered by messages when you are not in the car.

## Why this exists

Tesla does not natively integrate with WhatsApp. This project bridges the gap on macOS by:
- Reading new inbound messages from WhatsApp's local Mac database
- Forwarding to a target iMessage recipient via AppleScript
- Optionally gating forwarding using Tesla Fleet API presence (`vehicle_state.is_user_present`)

## Architecture

- **Menu app** (status bar):
  - App bundle executable:
    - `/Applications/tesla-notifier-forwarder.app/Contents/MacOS/tesla-notifier-forwarder`
  - Controls and diagnostics:
    - Status
    - Start/Stop/Restart forwarder
    - Run setup verification
    - Live logs
    - Open config

- **Forwarder daemon**:
  - Binary:
    - `/Applications/tesla-notifier-forwarder.app/Contents/Resources/forwarder-daemon`
  - LaunchAgent:
    - `~/Library/LaunchAgents/com.tesla.notifier.forwarder.plist`

- **Menu LaunchAgent**:
  - `~/Library/LaunchAgents/com.tesla.notifier.menu.plist`

- **State/config/logs**:
  - `~/Library/Application Support/TeslaNotifier/config.json`
  - `~/Library/Application Support/TeslaNotifier/state.json`
  - `~/Library/Application Support/TeslaNotifier/forwarder.log`
  - `~/Library/Application Support/TeslaNotifier/forwarder.err.log`

## Prerequisites

- macOS
- WhatsApp Desktop logged in
- Messages app logged into iMessage
- iPhone paired to Tesla with message sharing enabled
- Xcode Command Line Tools (`swiftc`, `swift`)
- Public HTTPS hosting for Tesla public key PEM (`/.well-known/appspecific/com.tesla.3p.public-key.pem`)
- Cloudflare Pages recommended for PEM hosting (see section below)

## Tesla/iPhone Message Sharing (Required)

Tesla can only display message notifications from your paired iPhone profile.
Even if forwarding on the Mac works, Tesla will not show messages unless this is enabled.

On Tesla screen:
- `Bluetooth` / `Phone`
- Select your iPhone
- Ensure `Sync Messages` / `Show Messages` / `Text Messages` is enabled (label varies by firmware)

On iPhone:
- `Settings -> Bluetooth`
- Tap `i` next to your Tesla connection
- Ensure notifications/messages access is allowed (if shown)

In iOS notifications:
- `Settings -> Notifications -> Messages`
- `Allow Notifications` ON
- Lock screen/banner alerts ON (recommended)

## Install

```bash
cd /path/to/tesla-notifier
./scripts/install.sh
```

Installer behavior:
- Builds menu app + daemon
- Installs app bundle to `/Applications`
- Creates/updates LaunchAgents
- Preserves existing `config.json`
- Signs app (`Developer ID` if available, otherwise ad-hoc)

## First-time setup

1. Open config:

```bash
open ~/Library/Application\ Support/TeslaNotifier/config.json
```

2. Set your iMessage recipient:

```json
"targetRecipient": "+1YOUR_NUMBER"
```

3. Restart daemon:

```bash
launchctl kickstart -k gui/$(id -u)/com.tesla.notifier.forwarder
```

## Menu actions

- `Status`
- `⏸ Stop Forwarder` / `▶ Start Forwarder` (single toggle)
- `↻ Restart Forwarder`
- `Open Config`
- `Run Setup Check`
- `Live Logs`
- `Quit Menu App` (quits UI only; daemon keeps running unless stopped)

## Config File Reference

Config file path:
- `~/Library/Application Support/TeslaNotifier/config.json`

All supported keys:

| Key | Type | Default | Valid values / behavior |
|---|---|---:|---|
| `targetRecipient` | string | `+15555555555` | iMessage target (E.164 recommended, e.g. `+15551234567`). Required for real forwarding. |
| `messagePrefix` | string | `[WA->Tesla]` | Prepended to forwarded text. Set `\"\"` to disable prefix. |
| `includeSenderInMessage` | bool | `true` | `true`: sends `Sender: message`. `false`: sends message body only. |
| `forwardingGateMode` | string | `always` | Single string value (not list). Valid: `\"always\"`, `\"tesla_fleet\"`. Code also accepts `\"off\"` and `\"none\"` as aliases for `\"always\"`. |
| `forwardingGateFailOpen` | bool | `true` | Only relevant in `tesla_fleet` mode. `true`: forward on API errors/timeouts. `false`: block on API errors/timeouts. |
| `senderAllowlist` | array[string] | `[]` | JSON array of sender names, e.g. `[\"Alice Example\", \"Bob Example\"]`. Empty array `[]` = allow all senders. Non-empty = only exact listed names are forwarded. |
| `dedupeWindowSeconds` | int | `90` | Duplicate suppression window for same sender+message text. |
| `maxMessageLength` | int | `500` | Truncates long forwarded messages and appends `...`. |
| `logPath` | string(path) | generated | Log file path. Usually `~/Library/Application Support/TeslaNotifier/forwarder.log`. |
| `statePath` | string(path) | generated | State file path (dedupe/history/last seen). |
| `debugNotificationDump` | bool | `false` | Enables additional fetch/poll debug logging. |
| `whatsappDBPath` | string(path) | generated | WhatsApp DB path (`ChatStorage.sqlite`). |
| `pollIntervalSeconds` | int | `5` | Poll interval in seconds. Values below `2` are clamped to `2` to avoid overly aggressive DB polling and high CPU usage. |
| `teslaFleetVehicleDataURL` | string(URL) | `\"\"` | Required for `tesla_fleet` mode. Format: `https://<fleet-host>/api/1/vehicles/<vehicle_id>/vehicle_data`. |
| `teslaFleetBearerToken` | string | `\"\"` | Required for `tesla_fleet` mode. OAuth access token. |
| `teslaFleetRefreshToken` | string | `\"\"` | Optional but recommended. If set with client credentials, daemon auto-refreshes access token on HTTP 401. |
| `teslaOAuthClientID` | string | `\"\"` | Tesla OAuth `client_id` used for auto-refresh. |
| `teslaOAuthClientSecret` | string | `\"\"` | Tesla OAuth `client_secret` used for auto-refresh. Keep private. |
| `teslaOAuthTokenURL` | string(URL) | `https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token` | Token endpoint for refresh flow. |
| `teslaFleetCacheSeconds` | int | `20` | Fleet gate cache TTL in seconds. Values below `1` are clamped to `1` so the cache logic remains valid and avoids request storms. |
| `teslaFleetAllowWhenUserPresent` | bool | `true` | In fleet mode, forwarding is allowed only when `vehicle_state.is_user_present == true` and this flag is true. |

Notes:
- `scripts/install.sh` creates a working config template on first install.
- Existing `config.json` is preserved on reinstall.
- `config.example.json` intentionally omits path fields (`logPath`, `statePath`, `whatsappDBPath`) to avoid broken `~` handling in JSON.

## Verify setup

Run from terminal:

```bash
./scripts/verify_tesla_setup.sh
```

Or use menu action: **Run Setup Check**.

Checks include:
- recipient configured
- WhatsApp DB readability
- Messages automation permission
- Tesla Fleet config and API response (if fleet mode enabled)

## Fleet gating (optional)

To only forward when you are likely in the car:

```json
{
  "forwardingGateMode": "tesla_fleet",
  "forwardingGateFailOpen": false,
  "teslaFleetVehicleDataURL": "https://<fleet-host>/api/1/vehicles/<vehicle_id>/vehicle_data",
  "teslaFleetBearerToken": "<access-token>",
  "teslaFleetRefreshToken": "<refresh-token>",
  "teslaOAuthClientID": "<client-id>",
  "teslaOAuthClientSecret": "<client-secret>",
  "teslaOAuthTokenURL": "https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token",
  "teslaFleetCacheSeconds": 20,
  "teslaFleetAllowWhenUserPresent": true
}
```

Gate behavior:
- allow when `vehicle_state.is_user_present == true`
- deny on API failure if `forwardingGateFailOpen=false`
- allow on API failure if `forwardingGateFailOpen=true`
- on HTTP 401, daemon auto-refreshes `teslaFleetBearerToken` if refresh credentials are configured

## Tesla token helper

Use the guided wizard:

```bash
./scripts/get_tesla_token.py
```

Capabilities:
- partner registration (EU/NA)
- local OAuth callback (`http://localhost:3000/callback`)
- token exchange
- fleet region detection
- optional vehicle ID lookup

Print full token when needed:

```bash
./scripts/get_tesla_token.py --interactive --skip-register --print-token
```

## Tesla Developer Portal Setup (Required)

Create and configure your Tesla app before running token setup.

1. Open Tesla Developer Portal:
- [https://developer.tesla.com](https://developer.tesla.com)
- Create a new app (or open existing app)

2. OAuth authorization type:
- Select `Authorization Code + Machine to Machine`

3. Configure URLs exactly:
- Allowed Origin(s): `https://<your-public-key-domain>`
- Allowed Redirect URI(s): `http://localhost:3000/callback`
- Return URL(s) (if the UI asks): `http://localhost:3000/callback`

Example:
- Allowed Origin: `https://tesla-key-host.pages.dev`
- Redirect URI: `http://localhost:3000/callback`

4. API scopes:
- Enable `vehicle_device_data` (shown as `Fahrzeugdaten` in some locales)
- `openid` and `offline_access` are requested during OAuth by the helper script

5. Save app settings, then note:
- `client_id`
- `client_secret`

6. Run token helper:

```bash
./scripts/get_tesla_token.py
```

When prompted:
- `client_id`: paste from Tesla app
- `client_secret`: paste from Tesla app
- `App domain from Tesla allowed_origins`: host only (no scheme), e.g. `tesla-key-host.pages.dev`

Important:
- `localhost:3000` is expected for OAuth callback on your Mac (local listener).
- Your public key must be hosted on a public HTTPS domain (not localhost).

## Cloudflare Pages key hosting (recommended)

Tesla partner registration requires a publicly hosted key at:

`/.well-known/appspecific/com.tesla.3p.public-key.pem`

Quick path:

```bash
mkdir -p /tmp/tesla-key-site/.well-known/appspecific
cp ~/.config/tesla-notifier/public-key.pem /tmp/tesla-key-site/.well-known/appspecific/com.tesla.3p.public-key.pem
```

Deploy `/tmp/tesla-key-site` as a **Cloudflare Pages** static upload.

Verify:

```bash
curl -s https://<your-pages-domain>/.well-known/appspecific/com.tesla.3p.public-key.pem | sed -n '1,5p'
```

Must return PEM text (`BEGIN PUBLIC KEY` / `END PUBLIC KEY`).

## Permissions

1. **Automation** (Messages control)
- Grant when prompted

2. **Full Disk Access**
- Needed when WhatsApp DB read is denied
- Add your terminal and/or app binary if required

## Troubleshooting

- **No forwarding, gate skips with 408**
  - Vehicle is offline/asleep; wake vehicle or set `forwardingGateFailOpen=true`

- **Fleet API 401 invalid authentication**
  - Token invalid/expired; refresh token via helper

- **Messages send appears successful but no Tesla popup**
  - Validate iPhone/Tesla Bluetooth message sharing
  - Test with a non-self iMessage recipient

- **Menu icon missing**
  - Restart menu agent:
    - `launchctl kickstart -k gui/$(id -u)/com.tesla.notifier.menu`

## Security notes

- `config.json` contains sensitive token(s)
- Do not commit real tokens or personal phone numbers
- Rotate tokens if exposed

## Uninstall

```bash
./scripts/uninstall.sh
```

Removes app + LaunchAgents. Leaves config/log/state in `~/Library/Application Support/TeslaNotifier`.

## Disclaimer

This project relies on local app automation and private local app storage format assumptions. OS/app updates may affect behavior.
