# Tesla Notify

A macOS menu bar app + background daemon that forwards inbound WhatsApp Desktop messages to iMessage, so they can appear in Tesla via your paired iPhone.

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

## Install

```bash
cd /path/to/tesla-notify
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
  "teslaFleetCacheSeconds": 20,
  "teslaFleetAllowWhenUserPresent": true
}
```

Gate behavior:
- allow when `vehicle_state.is_user_present == true`
- deny on API failure if `forwardingGateFailOpen=false`
- allow on API failure if `forwardingGateFailOpen=true`

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
