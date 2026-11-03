# Commsuite

Self-hosted chat suite for **Android and Windows** (Flutter) with a custom Node.js backend:

- 1:1 messaging (text + attachments) with typing indicators and read receipts
- Voice and video calls over WebRTC (Google STUN out of the box; server-issued TURN relay for TCP-only / correlated-NAT networks like CloudPub tunnels)
- Live streaming: a Twitch-like Stream tab with multi-viewer broadcasts (up to 8), forced through the server TURN relay (no peer-to-peer media)
- Local file manager (browse, search, rename, delete, copy/cut/paste, new folder, properties)
- Web browser (tabbed InAppWebView with bookmarks)
- Presence (online/offline) and a persistent accounts database
- Two-factor authentication (TOTP) with QR setup and ten single-use recovery codes

```
commsuite/
├── server/   Node.js API + WebSocket signaling server (SQLite)
└── app/      Flutter app (Android + Windows)
```

## Server

Node.js >= 20 required.

```bash
cd server
npm install
npm start      # listens on 0.0.0.0:3000
```

- HTTP API on port `3000` (`/api/...`), WebSocket signaling on `/ws?token=<jwt>`.
- Data is stored in `server/data/` (SQLite DB `app.db`, uploads, JWT secret). This folder is git-ignored and created on first start.
- Smoke test (starts the server on port 3457 against a throwaway data directory and runs 76 assertions):

```bash
npm run smoke
```

### API overview

- `POST /api/register` · `POST /api/login` → `{ token, user }`, or `{ twoFactorRequired, challenge }` when TOTP is on · `POST /api/login/2fa` (challenge + TOTP or recovery code) → `{ token, user }`
- `GET /api/2fa/status` · `POST /api/2fa/setup` (secret + `otpauth://` URL) · `POST /api/2fa/enable` (code → ten recovery codes, shown once) · `POST /api/2fa/disable` (password + code)
- `GET /api/me` (Bearer token)
- `GET /api/users/search?q=` · `POST /api/conversations` (idempotent 1:1 lookup)
- `GET /api/conversations` · `GET /api/conversations/:id/messages?limit=&before=`
- `POST /api/conversations/:id/messages` (`kind: text|file`)
- `POST /api/attachments` (multipart) · `GET /api/attachments/:id` (streamed, same-auth)
- Streams: `GET /api/streams` (directory) · `GET /api/streams/mine` · `PATCH /api/streams/channel` · `GET /api/streams/games` · `POST /api/streams` (go live) · `POST /api/streams/:id/join|leave|end` · `GET /api/streams/:id` / `viewers` / `bans` / `mods` · `POST /api/streams/:id/kick|ban|mods` · `DELETE /api/streams/:id/ban/:userId` / `mods/:userId`
- WebSocket events: client `ping|typing|read|signal|stream-signal`; server pushes `hello|presence|message|typing|read|signal|stream-viewer-joined|stream-viewer-left|stream-ended|stream-kicked|stream-updated|stream-modded|stream-unmodded|stream-signal|error`

## App (Flutter)

Flutter 3.47+ with Windows (Visual Studio 2022) and/or Android toolchains installed.

```bash
cd app
flutter pub get
flutter run -d windows        # desktop
flutter run -d <android-device>   # phone/emulator
```

### Server URL

- Android **emulator**: defaults to `http://10.0.2.2:3000`.
- Windows / real device: defaults to `http://localhost:3000`. For a phone, edit the URL in **Settings** to your machine's LAN IP, e.g. `http://192.168.1.20:3000`, and make sure the server is reachable on that address.

### Feature map

| Tab | What it does |
|-----|--------------|
| Chats | Conversation list, last message + time, unread badge, online indicator, typing/read state |
| People | Directory search, start chat / voice / video call |
| Files | Local storage browser (Android `/storage/emulated/0`, Windows drive roots), full file operations |
| Browse | Tabbed web browser, URL bar, reload/back/forward, persisted bookmarks |
| Stream | Live directory, channel profile (title/description/game), broadcast room with chat and moderation |
| Settings | Your profile, security (two-factor auth), connection status, server URL (live reconnect), sign out |

### Notes / platform specifics

- **Permissions**: the Android manifest declares camera/microphone/storage permissions; runtime permission prompts happen when a call starts. Storage browsing uses the legacy all-files access path; on Android 11+ you may need to grant "All files access" while the flag `MANAGE_EXTERNAL_STORAGE` is in place.
- **WebView2**: the Windows browser uses `flutter_inappwebview`, which requires the WebView2 runtime (preinstalled on Windows 11).
- **Vendored patches** (pre-existing upstream incompatibilities, kept local):
  - `flutter_inappwebview_android` (1.1.3) `android/build.gradle` uses `proguard-android.txt`, which AGP 8.9+ rejects → patched to `proguard-android-optimize.txt` in the pub cache.
  - `flutter_webrtc` on Android downloads the NDK (`28.2.13676358`) and libwebrtc on first build (large first build).
- **NuGet**: `flutter_inappwebview_windows` needs `nuget.exe` on PATH; `tools/nuget/nuget.exe` is installed and added to the user PATH.
- Calls rely on the server-issued TURN credentials (`GET /api/turn`); when the
  server has no TURN configured the app falls back to Google STUN.

### Live streaming

The **Stream** tab is a Twitch-like channel and directory:

- **My channel** — title, description, game (free text with autocomplete from
  games you have used before), visibility (`public`, `unlisted`, `contacts`) and
  slow mode. Settings are saved on the server and reused the next time you go
  live.
- **Live now** — every public broadcast. Unlisted streams are reachable by id,
  `contacts` streams only by people who share a DM or group conversation with
  the broadcaster. A broadcast holds **up to 8 viewers**; the ninth join is
  rejected with `409 stream is full`.
- **Broadcast room** — the broadcaster sees their own preview plus mic, camera,
  camera-switch, quality (480p/720p hot-swap) and end controls. Viewers see the
  relayed video and can leave at any time.
- **Stream chat** — a dedicated per-stream conversation is created when the
  broadcaster goes live, viewers join and leave with the stream, and it is
  archived to the broadcaster when the stream ends.
- **Moderation** — kick or ban viewers (bans persist on the channel), appoint
  moderators, and set slow mode to 0/3/10/30 seconds. Moderators can delete
  messages, kick and ban.

Media is relayed by the server TURN relay (Cloudflare Realtime TURN,
credentials from `GET /api/turn`). Every peer connection sets
`iceTransportPolicy: 'relay'`, so neither video nor audio travels directly
between devices. Without a configured TURN relay the app refuses to start or
join a stream instead of silently degrading to P2P.

Sessions are stored in SQLite (`stream_sessions`, `stream_viewers`), so a
broadcaster who drops their socket is cleaned up and the directory does not keep
zombie streams. Signalling is a single authenticated WebSocket message:

| Client → server | Server → client | Purpose |
|---|---|---|
| `ping` / `typing` / `read` | `hello` / `presence` / `message` / `typing` / `read` | normal chat traffic |
| `stream-signal` `{streamId, to, kind, payload}` | `stream-signal` `{streamId, from, kind, payload}` | SDP offer/answer + ICE relay |
| — | `stream-viewer-joined` / `stream-viewer-left` | broadcaster updates the viewer list |
| — | `stream-ended` / `stream-kicked` | viewer is disconnected or the room closes |
| — | `stream-updated` / `stream-modded` / `stream-unmodded` | live metadata and moderator changes |

Demo and smoke-test accounts are hidden from the people directory
(`users.hidden = 1`) but keep their message history.

### Calls on UDP-blocked networks (TURN relay)

If the two devices are behind restrictive NATs or a network that blocks UDP,
configure a relay in **Settings → Calls (TURN relay)** (host / port / user /
pass). With a relay saved, the app sets `iceTransportPolicy: 'relay'`, so media
is carried over TCP. Leave the fields empty to fall back to direct STUN.

- `server/turn/` contains a coturn setup: `turnserver.conf`, `mux.js`, and
  start / status / verify scripts.
- If a `turnserver` started earlier as root still holds :3478, stop it with:
  `wsl -d Ubuntu -u root -- pkill -x turnserver`.

### Tests / checks

```bash
cd app
flutter analyze          # clean
flutter test             # widget smoke test
```

## Windows installer

The Windows build ships as a single setup exe built from `installer/` (a .NET
Framework 4.8 WPF app, so there is no runtime to install - 4.8 is part of
Windows 10/11). It has a folder picker, a progress bar and a black
80%-transparent window, and embeds both the app payload and a small uninstaller.

```powershell
# 1. Flutter Windows build into dist\app
cd app
flutter build windows
Copy-Item build\windows\x64\runner\Release\* ..\dist\app -Recurse -Force

# 2. build dist\CommsuiteSetup.exe (stages dist\app -> embedded zip)
cd ..
powershell -ExecutionPolicy Bypass -File installer\build.ps1
```

- GUI: choose the folder, watch progress, optionally launch on finish.
- Silent (used by the app's in-place auto-update): `CommsuiteSetup.exe /S`
  (optionally `/D=<folder>`).
- Uninstall: the setup writes `Uninstall.exe` into the install folder; it
  removes the files, shortcuts, the autostart entry and the registry entries
  (relaunching itself from `%TEMP%` so the folder can be fully deleted).

The version lives in `installer/CommsuiteInstaller.csproj` (`Version`,
`FileVersion`) and must stay in sync with `app/pubspec.yaml`,
`app/lib/core/app_version.dart` and `server/update/latest.json`.

## Getting started (two accounts)

1. Start the server (`npm start`).
2. Register two accounts (e.g. one on the Windows app, one on a phone/emulator).
3. Search for each other in **People** and open a chat; calls and file sharing work from the chat/contacts screens.