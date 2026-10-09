#!/usr/bin/env python3
"""Caller bot.

A small Python wrapper around pjsua (a real, free, open-source SIP stack)
that calls a SIP address (e.g. your own softphone) for free over VoIP,
plays a message, records what you say, and hangs up.

Free TXT:  no call minutes, no credits, no Twilio. Both sides just need
           a SIP identity on the same network/provider.
"""

import argparse
import json
import math
import os
import queue
import re
import shutil
import socket
import struct
import subprocess
import tempfile
import sys
import threading
import time
import wave

try:
    import dtmf_goertzel
except Exception:
    dtmf_goertzel = None

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONFIG = os.path.join(SCRIPT_DIR, "config.json")
VENDOR_EXE = os.path.join(SCRIPT_DIR, "vendor", "pjsua", "pjsua.exe")


def find_pjsua():
    """Return the pjsua binary to use (vendored copy beats PATH)."""
    if os.name == "nt" and os.path.exists(VENDOR_EXE):
        return VENDOR_EXE
    path = shutil.which("pjsua")
    if path:
        return path
    sys.exit(
        "Could not find pjsua. Either place it at "
        "vendor/pjsua/pjsua.exe or install pjsua and put it on PATH."
    )


def pick_tcp_port():
    """Return a currently-free ephemeral TCP port (for the pjsua CLI)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
    finally:
        s.close()


def strip_telnet_negotiation(data):
    """Remove telnet IAC negotiation bytes (0xFF sequences) from raw bytes."""
    out = bytearray()
    i, n = 0, len(data)
    while i < n:
        if data[i] == 0xFF:
            i += 1
            if i >= n:
                break
            cmd = data[i]
            i += 1
            if cmd in (0xFA, 0xFB, 0xFC, 0xFD, 0xFE) and i < n:
                i += 1
        else:
            out.append(data[i])
            i += 1
    return bytes(out)


def load_config(path=DEFAULT_CONFIG, verbose=True):
    if not os.path.exists(path):
        sys.exit("Config file not found: %s (copy config.example.json to config.json)" % path)
    with open(path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    if verbose:
        print("[config] loaded %s" % path)
    return cfg


def make_sip_uri(target, domain):
    """Normalize short targets like 'alice' to 'sip:alice@domain'."""
    if isinstance(target, str) and target.lower().startswith("sip:"):
        return target
    if isinstance(target, str) and "@" in target and not target.lower().startswith("sip:"):
        return "sip:%s" % target
    return "sip:%s@%s" % (target, domain)


def build_command(cfg, target_uri, cli_port=None):
    """Build the pjsua command line from the config."""
    cmd = [find_pjsua()]

    port = cfg.get("local_port")
    if port:
        cmd += ["--local-port", str(port)]

    if cfg.get("null_audio", True):
        cmd += ["--null-audio"]

    auto_answer = cfg.get("auto_answer")
    if auto_answer:
        cmd += ["--auto-answer", str(auto_answer)]

    duration = cfg.get("duration_seconds")
    if duration:
        cmd += ["--duration", str(duration)]

    # Run the pjsua CLI over a local telnet port so we can query call state
    # in real time (pjsua's plain stdout is block-buffered, so it is NOT a
    # reliable place to watch for "call ended").
    if cli_port:
        cmd += ["--use-cli", "--cli-telnet-port", str(cli_port), "--no-cli-console"]

    domain = cfg.get("sip_domain", "")
    # The reachable SIP proxy/registrar (sip2sip.info's own hostname resolves
    # to addresses that do not respond from some networks; proxy.sipthor.net
    # is the real proxy and is what the official softphones use).
    registrar = cfg.get("registrar") or domain
    outbound = cfg.get("outbound_proxy") or (registrar if registrar else None)
    is_local = "127.0.0.1" in target_uri or "localhost" in target_uri.lower()

    username = cfg.get("username")
    if username and domain and not is_local:
        # Register an account so the provider will accept our outgoing call.
        cmd += ["--id", "sip:%s@%s" % (username, domain)]
        cmd += ["--registrar", "sip:%s" % registrar]
        if outbound:
            cmd += ["--outbound", "sip:%s" % outbound]
        cmd += ["--username", username]
        cmd += ["--password", cfg.get("password", "")]
        cmd += ["--realm", domain]
    else:
        # Unauthenticated caller. Works when the provider lets you call its
        # own users without credentials, and for local softphone tests.
        cmd += ["--id", "sip:callerbot@%s" % (domain or "localhost")]
        if outbound and not is_local:
            cmd += ["--outbound", "sip:%s" % outbound]

    message_file = cfg.get("message_file")
    if message_file and os.path.exists(message_file):
        cmd += ["--play-file", message_file, "--auto-play"]
        if cfg.get("loop", False):
            cmd += ["--auto-loop"]

    record_file = cfg.get("record_file")
    if record_file:
        cmd += ["--rec-file", record_file, "--auto-rec"]

    cmd.append(target_uri)
    return cmd


def wav_frames_valid(path):
    """True when `path` is a real PCM WAV with at least one audio frame.

    pjsua exits at startup if a --play-file is missing data (e.g. a 44-byte
    header-only WAV), so we must not hand it an empty file.
    """
    try:
        with wave.open(path, "rb") as w:
            return w.getnframes() > 0
    except (wave.Error, EOFError, OSError):
        return False


def ensure_valid_message(cfg):
    """Make sure cfg['message_file'] points at a playable WAV before a call.

    If the configured file is missing, empty, or corrupt, replace it in-place
    with a freshly generated valid tone so pjsua never fails to start.
    Returns the path in use (possibly regenerated).
    """
    mf = cfg.get("message_file")
    if not mf:
        return None
    if os.path.exists(mf) and wav_frames_valid(mf):
        return mf
    reply = "message file %r was missing or empty; regenerating a valid tone" % mf
    try:
        make_message_wav(mf, seconds=4.0)
    except OSError as e:
        reply = "message file %r unavailable (%s); proceeding silently" % (mf, e)
        mf = None
    return mf


def make_message_wav(path, seconds=8.0):
    """Generate a small audible 'hello, this is the bot' style tone WAV.

    8 kHz, 16-bit mono PCM - a format every SIP stack understands.
    """
    sample_rate = 8000
    nframes = int(sample_rate * seconds)
    # A short two-part melody (like a doorbell).
    notes = [
        (523.25, 0.6),   # C5
        (0, 0.15),       # gap
        (659.25, 0.6),   # E5
        (0, 0.15),
        (783.99, 0.6),   # G5
        (0, 0.30),
        (1046.5, 1.6),   # C6 (sustained)
    ]
    samples = bytearray(nframes * 2)
    pos = 0
    for freq, dur in notes:
        count = int(sample_rate * dur)
        for i in range(count):
            if pos >= nframes:
                break
            if freq > 0:
                value = int(12000 * math.sin(2 * math.pi * freq * (i % sample_rate) / sample_rate))
                value += int(9000 * math.sin(2 * math.pi * 2 * freq * (i % sample_rate) / sample_rate))
                if value > 32767:
                    value = 32767
                elif value < -32768:
                    value = -32768
            else:
                value = 0
            struct.pack_into("<h", samples, pos * 2, value)
            pos += 1
    with wave.open(path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(bytes(samples))
    return path


def _resample_mono_16(src_path, dst_path, sample_rate=8000):
    """Re-encode src_path as <sample_rate> Hz mono 16-bit PCM at dst_path."""
    with wave.open(src_path, "rb") as w:
        rate = w.getframerate()
        nch = w.getnchannels()
        width = w.getsampwidth()
        n = w.getnframes()
        raw = w.readframes(n)
    if width != 2:
        raise ValueError("TTS engine produced a non-16-bit WAV")
    samples = struct.unpack("<%dh" % (len(raw) // 2), raw[: len(raw) // 2 * 2])
    if nch > 1:
        samples = samples[::nch]  # take first channel
    if rate == sample_rate:
        out = samples
    else:
        n_out = int(len(samples) * sample_rate / max(rate, 1))
        out = []
        for i in range(n_out):
            pos = i * rate // sample_rate
            out.append(samples[min(pos, len(samples) - 1)])
    with wave.open(dst_path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(struct.pack("<%dh" % len(out), *out))
    return dst_path


_CYRILLIC = re.compile(r"[А-Яа-яЁё]")


def _pick_voice(engine, text):
    """Select the SAPI voice that best matches the text's script.

    The bundled Microsoft David/Zira voices are English-only; feeding them
    Cyrillic silence (which used to fall back to the tone melody). Prefer a
    Russian voice when the text is Russian, otherwise keep the default.
    """
    voices = []
    try:
        voices = engine.getProperty("voices")
    except Exception:
        return None
    if not voices:
        return None
    wants_ru = bool(_CYRILLIC.search(text))
    for v in voices:
        low = (str(getattr(v, "id", "")) + " " + str(getattr(v, "name", ""))).lower()
        if wants_ru and ("ru-ru" in low or "russian" in low or "IRC-RU" in low):
            return v
    # If there's no matching script voice, keep whatever engine default is set.
    try:
        return engine.getProperty("voice") or None
    except Exception:
        return None


def _list_other_voices(engine, chosen):
    """All SAPI voices other than `chosen` (for retry attempts)."""
    picked_id = getattr(chosen, "id", "")
    out = []
    try:
        for v in engine.getProperty("voices"):
            if getattr(v, "id", "") != picked_id:
                out.append(v)
    except Exception:
        return []
    return out


_DTMF_TMP = None


def _dtmf_wav_path(digit):
    """A stable per-digit temp WAV path for DTMF-triggered messages."""
    global _DTMF_TMP
    if _DTMF_TMP is None:
        _DTMF_TMP = tempfile.mkdtemp(prefix="callerbot_dtmf_")
    return os.path.join(_DTMF_TMP, "dtmf_%s.wav" % digit)


def make_tts_message(text, path=None, amp=1.0):
    """Render `text` to speech via Windows SAPI (pyttsx3) into a SIP-friendly
    8 kHz mono 16-bit WAV file. Returns the output path."""
    path = path or os.path.join(SCRIPT_DIR, "message.wav")
    tmp = path + ".tts.tmp.wav"
    try:
        import pyttsx3
    except ImportError:
        sys.exit("pyttsx3 is not installed. Run: python -m pip install pyttsx3")
    engine = pyttsx3.init()
    voice = _pick_voice(engine, text)
    if voice is not None:
        try:
            engine.setProperty("voice", voice.id)
        except Exception:
            pass
    engine.save_to_file(text, tmp)
    engine.runAndWait()
    engine.stop()
    # Empty/header-only output usually means the voice couldn't render the text
    # (e.g. Russian text on an English-only voice). Retry once with any other
    # available voice before giving up on the spoken message.
    if not os.path.exists(tmp) or os.path.getsize(tmp) < 44:
        for v in _list_other_voices(engine, voice):
            engine2 = pyttsx3.init()
            try:
                engine2.setProperty("voice", v.id)
            except Exception:
                pass
            try:
                os.remove(tmp)
            except OSError:
                pass
            engine2.save_to_file(text, tmp)
            engine2.runAndWait()
            engine2.stop()
            if os.path.exists(tmp) and os.path.getsize(tmp) > 44:
                break
    try:
        _resample_mono_16(tmp, path)
    except (wave.Error, EOFError, OSError, ValueError):
        make_message_wav(path, seconds=4.0)
    if not wav_frames_valid(path):
        make_message_wav(path, seconds=4.0)
    try:
        os.remove(tmp)
    except OSError:
        pass
    return path


_STATUS_FAIL = re.compile(r"SIP/2\.0\s+[45]\d\d", re.IGNORECASE)
_FAIL_PHRASES = (
    "request timeout",
    "connection error",
    "unable to resolve",
    "dns resolution failed",
    "registration failed",
    "auth challenge",
    "sip server is unreachable",
    "no candidate",
)


def stream_output(proc, report, connected, ended):
    """Drain pjsua stdout (prevents pipe deadlock) and detect lifecycle
    events as a SECONDARY source. Primary detection is the telnet CLI,
    because pjsua's stdout is block-buffered and arrives in bursts."""
    while True:
        line = proc.stdout.readline()
        if not line:
            break
        line = line.rstrip("\r\n")
        if line:
            print(line)
        low = line.lower()
        if "state changed to confirmed" in low:
            connected.set()
        if "is disconnected" in low or "state changed to disconn" in low:
            ended.set()
        if not ended.is_set():
            m = _STATUS_FAIL.search(line)
            if m:
                report("Peer rejected the call: %s" % m.group(0))
            for marker in _FAIL_PHRASES:
                if marker in low:
                    report("Trouble: %s" % line.strip())
                    break


def kill_stray_pjsua(verbose=True):
    """Terminate any pjsua owned by this tool that survived a previous run.

    A leftover pjsua keeps both UDP 5060 and its telnet CLI port bound, which
    is why repeated runs can go from \"working\" to \"could not reach CLI\".
    """
    target = os.path.realpath(find_pjsua())
    cmd = [
        "powershell", "-NoProfile", "-Command",
        "Get-CimInstance Win32_Process -Filter \"Name='pjsua.exe'\" | "
        "ForEach-Object { $_.ProcessId.ToString() + '|' + $_.ExecutablePath }",
    ]
    killed = 0
    try:
        out = subprocess.run(
            cmd, capture_output=True, text=True, timeout=15, check=True
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return 0
    for line in out.splitlines():
        line = line.strip()
        if "|" not in line:
            continue
        pid_s, exe = line.split("|", 1)
        if not pid_s.isdigit():
            continue
        try:
            if os.path.realpath(exe).lower() == target.lower():
                subprocess.run(
                    ["taskkill", "/PID", pid_s, "/T", "/F"],
                    capture_output=True, timeout=15,
                )
                killed += 1
        except (OSError, subprocess.SubprocessError):
            pass
    if killed and verbose:
        print("[bot] killed %d leftover pjsua process(es)" % killed)
    return killed


class CallSession:
    """Manages a single bot call end to end.

    Spawns pjsua, drives it through its local telnet CLI in a background
    thread, and exposes thread-safe control (send DTMF, hang up) plus an
    event/callback interface suitable for both the CLI and the GUI.
    """

    def __init__(self, cfg, on_connected=None, on_ended=None, on_log=None,
                 on_dtmf=None):
        self.cfg = cfg
        self.on_connected = on_connected
        self.on_ended = on_ended
        self.on_log = on_log or (lambda m: print("[bot] " + m))
        self.on_dtmf = on_dtmf
        self.proc = None
        self.sock = None
        self.sock_dead = threading.Event()
        self.connected = threading.Event()
        self.ended = threading.Event()
        self._write_lock = threading.Lock()
        self._stopping = threading.Event()
        self._dtmf_wavs = {}  # digit -> pre-rendered WAV played back on DTMF
        self._rec_info = None  # (data_offset, channels, rate) parsed from header
        self._rec_off = 0      # bytes of record file already consumed
        self._dtmf_det = None  # DtmfToneDetector instance

    def _log(self, msg):
        try:
            self.on_log(msg)
        except Exception:
            pass

    def start(self, target_uri, timeout=None, kill_strays=True):
        """Spawn pjsua and connect to its CLI. Returns True on success."""
        if kill_strays:
            kill_stray_pjsua()
        before = self.cfg.get("message_file")
        after = ensure_valid_message(self.cfg)
        if after == before:
            pass
        elif after is None and before:
            self._log("message file unavailable; continuing without it")
        elif before is not None:
            self._log("regenerated message file (previous was invalid/empty)")
        cli_port = pick_tcp_port()
        cmd = build_command(self.cfg, target_uri, cli_port)
        self._log("command: %s" % " ".join(cmd))
        self._prep_dtmf_messages()

        creationflags = 0
        if os.name == "nt":
            creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(
                subprocess, "CREATE_NEW_PROCESS_GROUP", 0
            )

        try:
            self.proc = subprocess.Popen(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                creationflags=creationflags,
                universal_newlines=True,
                bufsize=1,
            )
        except OSError as e:
            self._log("failed to launch pjsua: %s" % e)
            return False

        threading.Thread(
            target=stream_output,
            args=(self.proc, self._log, self.connected, self.ended),
            daemon=True,
        ).start()

        deadline = time.time() + (timeout if timeout else 300)
        wait_until = min(deadline, time.time() + 15)
        while time.time() < wait_until:
            if self.proc.poll() is not None:
                self._log(
                    "pjsua exited (code %s) before its CLI was reachable; "
                    "check the log lines above (e.g. port 5060 conflict)"
                    % self.proc.returncode
                )
                return False
            try:
                self.sock = socket.create_connection(("127.0.0.1", cli_port), timeout=2)
                self.sock.settimeout(2)
                threading.Thread(
                    target=self._cli_reader,
                    daemon=True,
                ).start()
                self._start_dtmf_monitor()
                break
            except OSError:
                self.sock = None
                time.sleep(0.25)
        if self.sock is None and self.proc.poll() is None:
            self._log("warning: could not reach pjsua CLI; relying on timers")
        return True

    def _cli_reader(self):
        text = ""
        pos = 0
        saw_call = False
        while not self._stopping.is_set():
            try:
                data = self.sock.recv(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            if not data:
                break
            text += strip_telnet_negotiation(data).decode("utf-8", errors="replace")
            # Only inspect the newly received slice; the accumulated buffer can
            # otherwise re-match stale lines on every poll (e.g. an old
            # "disconnect" mention) and falsely end a live call.
            seg = text[pos:]
            pos = len(text)
            if re.search(r"\[CONFIRMED\]", seg) or re.search(
                r"state changed to CONFIRMED", seg
            ):
                self.connected.set()
                saw_call = True
            if re.search(r"Current call id=", seg) or re.search(
                r"You have [1-9]\d* active calls?", seg
            ):
                saw_call = True
            # Detect DTMF the callee sends (RFC 2833 telephone-events). pjsua
            # logs each one as:  Incoming DTMF on call N: D, using RFC2833 method
            for m in re.finditer(r"Incoming DTMF on call\s+\d+:\s+([0-9A-D*#])",
                                 seg, re.IGNORECASE):
                self._handle_inbound_dtmf(m.group(1).upper())
            # A real call end shows up as a DISCONNECTED state transition.
            if re.search(r"state changed to DISCONNECT", seg, re.IGNORECASE):
                self.ended.set()
            # "0 active" right after startup (before the call exists yet) is normal.
            if saw_call and re.search(r"You have 0 active calls?", seg):
                self.ended.set()
        self.sock_dead.set()

    def _handle_inbound_dtmf(self, digit):
        """Common handler for an inbound DTMF digit, from any source."""
        self._log("DTMF received: %s" % digit)
        try:
            if self.on_dtmf:
                self.on_dtmf(digit)
        except Exception:
            pass
        self.play_dtmf_message(digit)

    def _start_dtmf_monitor(self):
        """Watch the (teardown) record file for in-band DTMF tones.

        Blink (and many softphones) send DTMF as audible in-band dual-tones
        rather than RFC 2833 telephone-events. We therefore monitor the WAV
        pjsua writes via --auto-rec and run a Goertzel dual-tone detector on
        the freshly appended PCM in real time.
        """
        rec = self.cfg.get("record_file")
        if not rec or dtmf_goertzel is None:
            return
        self._rec_info = None
        self._rec_off = 0
        self._dtmf_det = dtmf_goertzel.DtmfToneDetector(
            on_dtmf=self._handle_inbound_dtmf)
        threading.Thread(target=self._dtmf_monitor_loop, daemon=True).start()

    def _parse_rec_header(self, head):
        """Return (data_offset, channels, rate) from a WAV header, else None."""
        if len(head) < 44 or head[:4] != b"RIFF" or head[8:12] != b"WAVE":
            return None
        i = head.find(b"data")
        if i < 0:
            return None
        ch = struct.unpack("<H", head[22:24])[0]
        rate = struct.unpack("<I", head[24:28])[0]
        return (i + 8, ch or 1, rate)

    def _dtmf_monitor_loop(self):
        rec = self.cfg.get("record_file")
        if not rec:
            return
        det = self._dtmf_det
        while not self._stopping.is_set() and not self.ended.is_set():
            try:
                st = os.stat(rec)
            except OSError:
                time.sleep(0.2)
                continue
            total = st.st_size
            if self._rec_info is None:
                if total < 160:
                    time.sleep(0.2)
                    continue
                try:
                    with open(rec, "rb") as f:
                        head = f.read(4096)
                except OSError:
                    time.sleep(0.2)
                    continue
                info = self._parse_rec_header(head)
                if info is None:
                    time.sleep(0.2)
                    continue
                self._rec_info = info
                self._rec_off = info[0]
            off, ch, rate = self._rec_info
            if total > off and total > self._rec_off:
                try:
                    with open(rec, "rb") as f:
                        f.seek(self._rec_off)
                        raw = f.read(total - self._rec_off)
                    self._rec_off = total
                    if len(raw) >= 2:
                        det.feed_bytes(raw, rate, channels=ch)
                except OSError:
                    pass
            time.sleep(0.2)
        self.sock_dead.set()

    def send_command(self, cmd):
        """Write a raw command to the pjsua CLI. Thread safe."""
        if self.sock is None or self.sock_dead.is_set():
            return False
        with self._write_lock:
            try:
                self.sock.sendall(cmd.encode("utf-8") + b"\r\n")
                return True
            except OSError:
                self.sock_dead.set()
                return False

    def send_dtmf(self, digits):
        """Send DTMF digits via RFC 2833 (only valid once media is up)."""
        self._log("DTMF: %s" % digits)
        return self.send_command("call d_2833 %s" % digits)

    def _prep_dtmf_messages(self):
        """Pre-render each DTMF-triggered spoken message to a little WAV.

        config:  dtmf_messages = {"1": "ok, sending", "2": "please wait", ...}
        On an inbound DTMF digit the mapped file is played into the live call,
        so the callee hears the bot answer by pressing a key.
        """
        mapping = self.cfg.get("dtmf_messages") or {}
        if not isinstance(mapping, dict):
            return
        self._dtmf_wavs = {}
        for digit, text in mapping.items():
            try:
                path = make_tts_message(text, path=_dtmf_wav_path(digit))
                if wav_frames_valid(path):
                    self._dtmf_wavs[str(digit).upper()] = path
            except Exception as e:
                self._log("DTMF message for %r failed: %s" % (digit, e))

    def play_audio(self, path):
        """Play a WAV file into the active call via the pjsua CLI."""
        if not os.path.exists(path):
            return False
        self._log("Playing: %s" % os.path.basename(path))
        return self.send_command('play-file %s' % path)

    def play_dtmf_message(self, digit):
        """Play the message mapped to an inbound DTMF digit, if configured."""
        wav = self._dtmf_wavs.get(str(digit).upper())
        if wav:
            self.play_audio(wav)
            return True
        return False

    def hangup(self):
        """Send shutdown to pjsua CLI; terminate the process if needed."""
        self._stopping.set()
        if self.sock is not None and not self.sock_dead.is_set():
            with self._write_lock:
                try:
                    self.sock.sendall(b"shutdown\r\n")
                except OSError:
                    pass
        if self.proc is not None and self.proc.poll() is None:
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None
        self.ended.set()

    def wait(self, timeout=None):
        """Run the main loop until the call ends or the deadline is reached."""
        if self.proc is None:
            return "not started"
        deadline = time.time() + (timeout if timeout else self.cfg.get("timeout", 300))
        connected_once = False
        last_poll = 0.0
        ring_timeout = self.cfg.get("ring_timeout", 45)
        ring_deadline = time.time() + ring_timeout
        try:
            while True:
                if self.proc.poll() is not None:
                    self.ended.set()
                    self._log("pjsua exited (code %s)" % self.proc.returncode)
                    if self.on_ended:
                        self.on_ended()
                    return "exited"
                if self.connected.is_set() and not connected_once:
                    connected_once = True
                    self._log("Connected!")
                    if self.on_connected:
                        self.on_connected()
                if self.ended.is_set():
                    if not connected_once:
                        self._log("call finished (or was rejected)")
                    else:
                        self._log("Call ended.")
                    if self.on_ended:
                        self.on_ended()
                    return "ended"
                if not connected_once and time.time() >= ring_deadline:
                    self._log("no answer within %ds; hanging up" % ring_timeout)
                    self.cleanup()
                    return "no answer"
                if time.time() >= deadline:
                    self._log("gave up after %ds; hanging up" % (timeout or 300))
                    self.cleanup()
                    return "gave up"
                if self.sock is not None and not self.sock_dead.is_set():
                    if time.time() - last_poll >= 0.5:
                        last_poll = time.time()
                        self.send_command("call list")
                        if self.sock_dead.is_set():
                            self.ended.set()
                time.sleep(0.1)
        except KeyboardInterrupt:
            self._log("interrupted, hanging up...")
            return "interrupted"
        finally:
            self.cleanup()

    def cleanup(self):
        """Release the pjsua process and CLI socket."""
        self._stopping.set()
        if self.sock is not None:
            with self._write_lock:
                try:
                    self.sock.sendall(b"shutdown\r\n")
                except OSError:
                    pass
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None
        if self.proc is not None and self.proc.poll() is None:
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
        if self.proc is not None:
            try:
                self.proc.wait()
            except Exception:
                pass


def run_call(target_uri, cfg, timeout=None, kill_strays=True):
    """CLI convenience wrapper: spawn a call and block until it ends."""
    sess = CallSession(cfg)
    if not sess.start(target_uri, timeout=timeout, kill_strays=kill_strays):
        return "failed to start"
    return sess.wait(timeout=timeout)


def cmd_call(cfg, args):
    target = args.target or cfg.get("target") or cfg.get("call_target")
    if not target:
        sys.exit("No call target. Set 'target' in config.json or pass --target")
    target_uri = make_sip_uri(target, cfg.get("sip_domain", ""))
    print("[bot] calling %s ..." % target_uri)
    run_call(target_uri, cfg, timeout=args.timeout)


def cmd_make_message(cfg, args):
    path = args.output or os.path.join(SCRIPT_DIR, "message.wav")
    make_message_wav(path, args.seconds)
    print("[bot] wrote message wav: %s" % path)


def cmd_tts(cfg, args):
    path = args.output or os.path.join(
        SCRIPT_DIR, cfg.get("message_file", "message.wav")
    )
    text = args.text or cfg.get(
        "tts_text", "Hello, this is the caller bot. Please say your message."
    )
    make_tts_message(text, path)
    print("[bot] wrote TTS message wav: %s" % path)


def cmd_self_test(cfg, args):
    """Full local test: spawn an answering 'softphone' (a second pjsua) and
    let the bot call it, exchange RTP, then report success."""
    tmp = os.path.join(SCRIPT_DIR, "self-test")
    os.makedirs(tmp, exist_ok=True)
    tone = os.path.join(tmp, "message.wav")
    rec = os.path.join(tmp, "recording.wav")
    seconds = args.seconds

    make_message_wav(tone, seconds)

    answ = [find_pjsua(),
            "--local-port", str(args.answer_port),
            "--id", "sip:self-test@127.0.0.1",
            "--null-audio",
            "--auto-answer", "200",
            "--play-file", tone, "--auto-play", "--auto-loop",
            "--duration", str(seconds + 2)]
    answ_log = open(os.path.join(tmp, "answerer.log"), "w", encoding="utf-8", errors="replace")
    print("[test] starting answering endpoint on UDP 127.0.0.1:%d" % args.answer_port)
    p_ans = subprocess.Popen(
        answ,
        stdin=subprocess.DEVNULL,
        stdout=answ_log,
        stderr=subprocess.STDOUT,
        universal_newlines=True,
        bufsize=1,
    )

    cfg = dict(cfg)
    cfg["username"] = ""
    cfg["password"] = ""
    cfg["message_file"] = None
    cfg["record_file"] = rec
    cfg["local_port"] = args.bot_port
    cfg["duration_seconds"] = seconds

    print("[test] bot will call sip:self-test@127.0.0.1:%d" % args.answer_port)
    run_call("sip:self-test@127.0.0.1:%d" % args.answer_port, cfg,
             timeout=seconds + 30, kill_strays=False)

    try:
        p_ans.terminate()
        p_ans.wait(timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        p_ans.kill()

    ok = os.path.exists(rec) and os.path.getsize(rec) > 1000
    print("[test] recording file: %s (%d bytes)"
          % (rec, os.path.getsize(rec) if os.path.exists(rec) else 0))
    print("[test] %s" % ("SUCCESS: the bot called, the callee answered, and RTP audio flowed."
                         if ok else "FAILED: no useful RTP was recorded. Review the logs above."))
    return 0 if ok else 1


def main():
    parser = argparse.ArgumentParser(
        prog="caller_bot",
        description="Free SIP caller bot (pjsua under the hood).",
    )
    parser.add_argument("--config", default=DEFAULT_CONFIG, help="config.json path")
    sub = parser.add_subparsers(dest="subcommand")

    p_call = sub.add_parser("call", help="place a call to the target SIP address")
    p_call.add_argument("--target", help="override target, e.g. alice or sip:alice@domain")
    p_call.add_argument("--timeout", type=int, default=300, help="give up after N seconds")

    p_msg = sub.add_parser("make-message", help="generate the 'message' WAV the bot plays")
    p_msg.add_argument("--output", help="output wav path (default message.wav)")
    p_msg.add_argument("--seconds", type=float, default=8.0)

    p_test = sub.add_parser("self-test", help="call an auto-answering local softphone")
    p_test.add_argument("--seconds", type=int, default=8)
    p_test.add_argument("--bot-port", type=int, default=5060)
    p_test.add_argument("--answer-port", type=int, default=5090)

    p_tts = sub.add_parser(
        "tts", help="render typed text to a spoken message WAV (text to speech)"
    )
    p_tts.add_argument("--text", help="the text to speak")
    p_tts.add_argument("--output", help="output wav path")

    sub.add_parser("gui", help="open the graphical control panel (keypad + TTS)")

    args = parser.parse_args()
    cfg = load_config(args.config)

    if args.subcommand == "call":
        cmd_call(cfg, args)
    elif args.subcommand == "make-message":
        cmd_make_message(cfg, args)
    elif args.subcommand == "tts":
        cmd_tts(cfg, args)
    elif args.subcommand == "gui":
        _run_gui(cfg)
    elif args.subcommand == "self-test":
        sys.exit(cmd_self_test(cfg, args))
    else:
        parser.print_help()


def _run_gui(cfg):
    """Launch the tkinter control panel (imported lazily so the core stays
    usable without tkinter / a display)."""
    try:
        import tkinter
    except ImportError:
        sys.exit("tkinter is not available; the GUI cannot run on this system.")
    from caller_gui import main as gui_main

    gui_main(cfg)


if __name__ == "__main__":
    main()