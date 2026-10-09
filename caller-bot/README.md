# Caller Bot

A bot that calls **you** (or anyone) for free over VoIP. No Twilio, no credits,
no pay-per-minute — it speaks SIP directly using the open-source
[pjsua](https://www.pjsip.org) stack that we built as a self-contained Windows
binary (see `vendor/pjsua/pjsua.exe`).

- Calls a SIP address (e.g. your own softphone).
- Plays a message WAV to the callee when they answer.
- Records what the callee says into a WAV.
- Hangs up automatically after N seconds.

## How it works

`caller_bot.py` is a thin Python wrapper around `pjsua` (a real SIP UA with a
voice engine). Both you and the bot hold a SIP identity; when the bot sends an
`INVITE`, the provider routes it to your softphone the same way any VoIP call
is routed. Because both legs are VoIP, the call is free.

pjsua announces call state over a local telnet CLI (`--cli-telnet-port`), and
the wrapper polls that channel every half a second so it sees the moment the
callee answers and the moment the call ends — then hangs up pjsua cleanly.
(We don't rely on pjsua's stdout for that: it is block-buffered, so its text
arrives in bursts and cannot be used to react to a hang-up in real time.)

## Setup (free)

You need two things — a SIP address for you, and the numbers to dial.

1. **Get a free SIP account.** [sip2sip.info](https://www.sip2sip.info) and
   [ekiga.net](https://www.ekiga.net) are free SIP providers. Register a
   username there (this is your "phone number").
2. **Put that account on your phone.** Install a softphone app on your
   phone/desktop — [MicroSIP](https://www.microsip.org), Zoiper, Linphone,
   Bria, Blink — and register it with your provider account. This is where you'll
   answer the bot's call.
3. **Fill in `config.json`** (a copy of `config.example.json`):

```json
{
  "sip_domain": "sip2sip.info",
  "registrar": "proxy.sipthor.net",
  "username": "",            // optional: bot account so the provider accepts the call
  "password": "",
  "target": "sip:your-username@sip2sip.info",   // who to call (you!)
  "local_port": 5060,
  "duration_seconds": 30,    // how long the call may last
  "ring_timeout": 45,        // hang up if nobody answers in N seconds
  "message_file": "message.wav",   // what the bot plays to you (optional)
  "record_file": "recording.wav",  // where your reply is recorded (optional)
  "null_audio": true,
  "auto_answer": 200
}
```

`registrar` / `outbound_proxy`: some providers' public hostname resolves to
addresses that don't answer (that's the case for `sip2sip.info`). The bundled
config points these at the real proxy `proxy.sipthor.net`, which is what the
official softphones use.

## Usage

```bash
# generate a demo message WAV ("doorbell" melody) the bot can play
python caller_bot.py make-message

# OR: turn any typed text into a spoken message WAV (text-to-speech, free)
python caller_bot.py tts --text "Hello, this is the caller bot."

# call yourself
python caller_bot.py call

# you can override the target anytime
python caller_bot.py call --target sip:me@sip2sip.info

# open the graphical control panel (call + TTS)
python caller_bot.py gui
```

After the callee answers you'll hear the message playing to you, the bot
records what you say to `recording.wav`, and it hangs up after
`duration_seconds`.

### Instant answer (in-dial to self, so you control the greeting)

- **`python caller_bot.py gui`** — a window with a target field, **Call** and
  **Hang up** buttons, a **Text-to-Speech** box that renders whatever you type
  into the spoken `message.wav`, a **"Loop message while connected"** checkbox,
  and a log. As the call runs, any **DTMF digit the callee presses on their
  phone keypad** is detected, shown live in the log (e.g. `DTMF received: 5`),
  and — if that digit has a `dtmf_messages` entry — the bot speaks the mapped
  line back over the call (e.g. press `1` → "ok, sending").

  DTMF is detected two ways and either one triggers `DTMF received: X`:
    1. **In-band audio tones** (Goertzel dual-tone detection on the recording,
       `dtmf_goertzel.py`).
    2. **RFC 2833 telephone-events** reported by pjsua's CLI.

  > **Important caveat.** The bot can only detect DTMF that the peer softphone
  > actually *transmits* into the call (as RFC 2833 events or audible tones).
  > Some softphones send nothing for keyboard key-presses during a call — e.g.
  > Blink's keyboard keys do **not** produce DTMF, and Blink has no in-call
  > keypad. Use a softphone/handset that sends DTMF (or Blink's own DTMF pad if
  > it exposes one on the call window), otherwise `DTMF received:` will never
  > appear regardless of the bot.

- **`python caller_bot.py tts --text "..."`** — render any text to a
  SIP-friendly 8 kHz mono WAV (`message.wav` by default, or `--output file.wav`).
  Uses the free Windows SAPI voices via `pyttsx3`
  (`python -m pip install pyttsx3`).

## Local self-test (no internet, no account needed)

Verify the whole pipeline — call placement, answer, media exchange — on this
machine in seconds:

```bash
python caller_bot.py self-test
```

This starts a second pjsua instance acting as a "softphone" that auto-answers,
the bot calls it, and it reports whether real RTP audio was recorded
(`self-test/recording.wav`).

## Options reference

`python caller_bot.py --help` and `python caller_bot.py call --help`.

Key behaviors controlled from `config.json`:

| key | meaning |
| --- | --- |
| `sip_domain` | The SIP provider's domain (also used as registrar realm). |
| `registrar` / `outbound_proxy` | Explicit proxy to route through (overrides `sip_domain` when the provider's own hostname is unreachable). |
| `username` / `password` | Bot's own account. Leave empty to call without registration (some providers allow it). |
| `target` | Destination: `sip:user@domain` (use your own softphone's number to "call yourself"). |
| `local_port` | Local SIP port. Change it if you already run a SIP client (e.g. MicroSIP) on 5060. |
| `duration_seconds` | Auto-hangup after this many seconds. Omit/0 for no limit. |
| `ring_timeout` | Hang up if the callee doesn't answer within this many seconds. |
| `message_file` | WAV the bot plays to the callee when the call connects. |
| `loop` | `true` to keep looping the message for the whole call, `false` to play it once. Toggle-able from the GUI checkbox. |
| `dtmf_messages` | Map of keypad digit -> text the bot speaks when the callee presses that digit (e.g. `"1": "ok, sending"`). Pre-rendered to WAV; played into the live call on DTMF. |
| `tts_text` | Default text used by `python caller_bot.py tts` and by the GUI's TTS box. |
| `record_file` | WAV where the callee's voice is written. |
| `null_audio` | Run without a sound card (bot needs no speakers/mic). |
| `auto_answer` | Code used to auto-answer incoming calls (default `200`). |

## Notes

- Routing providers route SIP by A record by default here; if your provider
  is SRV-only, dial the server's IP directly, e.g. `sip:user@1.2.3.4`.
- The bundled `pjsua.exe` was compiled from pjsip 2.17 for Windows (VC14
  toolset, i386). Its license is in `vendor/pjsua/COPYING.txt`.
- Calling a real phone *number* (PSTN) does require a paid trunk — nothing
  here will break that rule; this project only does VoIP-to-VoIP.