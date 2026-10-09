# Commsuite

Self-hosted chat suite for **Android and Windows** (Flutter) with a custom Node.js backend:

- 1:1 messaging (text + attachments) with typing indicators and read receipts
- Voice and video calls over WebRTC (Google STUN out of the box; optional TURN-over-TCP relay for TCP-only / correlated-NAT networks like CloudPub tunnels)
- Local file manager (browse, search, rename, delete, copy/cut/paste, new folder, properties)
- Web browser (tabbed InAppWebView with bookmarks)
- Presence (online/offline) and a persistent accounts database

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
- Smoke test (starts the server on port 3457 and runs 24 assertions):

```bash
npm run smoke
```

### API overview

- `POST /api/auth/register` · `POST /api/auth/login` → `{ token, user }`
- `GET /api/auth/me` (Bearer token)
- `GET /api/users/search?q=` · `POST /api/conversations` (idempotent 1:1 lookup)
- `GET /api/conversations` · `GET /api/conversations/:id/messages?limit=&before=`
- `POST /api/conversations/:id/messages` (`kind: text|file`)
- `POST /api/attachments` (multipart) · `GET /api/attachments/:id` (streamed, same-auth)
- WebSocket events: `ping|typing|read|signal`; server pushes `hello|presence|message|typing|read|signal|error`

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
| Settings | Your profile, connection status, server URL (live reconnect), sign out |

### Notes / platform specifics

- **Permissions**: the Android manifest declares camera/microphone/storage permissions; runtime permission prompts happen when a call starts. Storage browsing uses the legacy all-files access path; on Android 11+ you may need to grant "All files access" while the flag `MANAGE_EXTERNAL_STORAGE` is in place.
- **WebView2**: the Windows browser uses `flutter_inappwebview`, which requires the WebView2 runtime (preinstalled on Windows 11).
- **Vendored patches** (pre-existing upstream incompatibilities, kept local):
  - `flutter_inappwebview_android` (1.1.3) `android/build.gradle` uses `proguard-android.txt`, which AGP 8.9+ rejects → patched to `proguard-android-optimize.txt` in the pub cache.
  - `flutter_webrtc` on Android downloads the NDK (`28.2.13676358`) and libwebrtc on first build (large first build).
- **NuGet**: `flutter_inappwebview_windows` needs `nuget.exe` on PATH; `tools/nuget/nuget.exe` is installed and added to the user PATH.
- Calls rely on Google STUN only; if two devices are behind restrictive NATs, add a TURN server in `app/lib/services/webrtc_service.dart`.

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

## Getting started (two accounts)

1. Start the server (`npm start`).
2. Register two accounts (e.g. one on the Windows app, one on a phone/emulator).
3. Search for each other in **People** and open a chat; calls and file sharing work from the chat/contacts screens.