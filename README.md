# Commsuite

Self-hosted chat suite for **Android and Windows** (Flutter) with a custom Node.js backend:

- 1:1 messaging (text + attachments) with typing indicators and read receipts
- Voice and video calls over WebRTC (Google STUN out of the box; server-issued TURN relay for TCP-only / correlated-NAT networks like CloudPub tunnels)
- Live streaming: a Twitch-like Stream tab with multi-viewer broadcasts (up to 8), forced through the server TURN relay (no peer-to-peer media)
- Local file manager (browse, search, rename, delete, copy/cut/paste, new folder, properties)
- Web browser (tabbed InAppWebView with bookmarks)
- Presence (online/offline) and a persistent accounts database
- Two-factor authentication (TOTP) with QR setup and ten single-use recovery codes
- Local encrypted password vault (AES-GCM, unlocked by its own passphrase) and in-app password change

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
- Smoke test (starts the server on port 3457 against a throwaway data directory and runs 86 assertions):

```bash
npm run smoke
npm test        # GitHub crash-report de-duplication tests (mocked API)
```

### API overview

- `POST /api/register` · `POST /api/login` → `{ token, user }`, or `{ twoFactorRequired, challenge }` when TOTP is on · `POST /api/login/2fa` (challenge + TOTP or recovery code) → `{ token, user }`
- `GET /api/2fa/status` · `POST /api/2fa/setup` (secret + `otpauth://` URL) · `POST /api/2fa/enable` (code → ten recovery codes, shown once) · `POST /api/2fa/disable` (password + code)
- `POST /api/password` (current password + new password; stored as a bcrypt hash, never recoverable from the server)
- `POST /api/crash-report` (public; automatic crash reports, de-duplicated by crash signature)
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
| Settings | Your profile, security (two-factor auth, encrypted password vault, password change), connection status, server URL (live reconnect), the Open Hexagon map maker, sign out |

### Open Hexagon map maker

**Settings → Support & Tools → Open Hexagon map maker** builds a complete,
self-contained pack for **Open Hexagon 1.92**:

- **Design** — pack/level name, author, description, palette, arena sides and
  speed/rotation pacing. The preview orbits the arena the same way the game does;
  drag it to look around, double-tap to reset the angle.
- **Patterns** — reorderable sequence of original pattern families (barrage,
  spiral, alternate, tunnel, zipper, mirror, sweep, breather), each with a calm /
  brisk / wild intensity. Optionally shuffle the order every cycle.
- **Ending** — a timed late-game switch that can flip to a generated black-and-
  white style, show an important message and boost the speed. This is the "die in
  a B&W stage" ending.
- **Export** — **Save .zip** writes `Packs/<pack>/…`; **Export as folder** writes
  the pack straight into a chosen folder. The pack always includes its own style,
  Lua script and a bundled silent OGG (replace that file to use real music).

The Lua is generated from Commsuite's own pattern implementations, not copied
from the default packs. Drafts autosave locally, and the generated Lua can be
viewed or copied from the export tab.

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

### Passwords, 2FA and the local vault

- **Two-factor authentication** — **Settings → Security → Two-factor
  authentication** shows a QR code (and the manual base32 key) for any TOTP app.
  After confirming a 6-digit code you receive ten single-use recovery codes,
  shown once. Turning 2FA off requires the account password plus a current
  authenticator or recovery code.
- **Change password** — **Settings → Security → Change password** verifies the
  current password and sends `POST /api/password`; the server stores only a
  bcrypt hash. If you also want the new password saved locally, tick “Save the
  new password in the local vault” (the vault must be unlocked first).
- **Password vault** — **Settings → Security → Password vault** keeps records
  (`title`, username, password, note) in `SharedPreferences`, encrypted with
  AES-GCM. The key is derived from a dedicated vault passphrase via
  PBKDF2-HMAC-SHA256 (100,000 iterations, random 16-byte salt) and exists in
  memory only while the vault is unlocked. The passphrase is independent of the
  account password and the Enigma app passcode, so changing either does not
  break saved records. Nothing is uploaded to the server; forgetting the vault
  passphrase means the records cannot be recovered, and deleting the vault
  erases them permanently.

### Crash reporting

The app reports unhandled crashes automatically — both the recovery dialog after
a crash and the in-app error window upload the log without waiting for a tap.
If the upload fails the dialog keeps the log and offers **Report** as a retry.

Set `COMMSUITE_GH_REPORTER_TOKEN` on the server to mirror reports into GitHub
issues. The server matches each crash by its summary line (the normalised
`App crash: …` title):

- a new signature creates one issue with the `bug` label;
- a known signature adds an occurrence comment with the timestamp, app version,
  platform, device details and log, and reopens the issue if it was closed.

Comments are throttled to one per issue every 15 minutes
(`COMMSUITE_CRASH_COMMENT_COOLDOWN_MS`), and simultaneous reports with the same
signature are serialised, so a crash loop or many affected devices cannot flood
the tracker with duplicate issues. `COMMSUITE_GH_REPORTER_REPO` overrides the
target repository; without a token reports stay local-only.

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
flutter build windows --release
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