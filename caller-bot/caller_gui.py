#!/usr/bin/env python3
"""Caller bot GUI.

A small tkinter control panel for the caller bot: dial any SIP target, watch
the call happen, generate the outgoing spoken message with text-to-speech, and
see the DTMF digits the callee presses during the call.

Run with:  python caller_gui.py   (or: python caller_bot.py gui)
"""

import os
import queue
import threading
import tkinter as tk
from tkinter import messagebox, scrolledtext

import caller_bot

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


class CallerBotGUI:
    def __init__(self, root, cfg):
        self.root = root
        self.cfg = cfg
        self.session = None  # active CallSession
        self.session_lock = threading.Lock()
        self.events = queue.Queue()  # (kind, payload) for UI thread
        self.connected = False

        root.title("Caller Bot")
        root.geometry("360x520")
        root.minsize(320, 440)

        self._build_widgets()
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
        self._poll_events()

    # ---- UI construction -------------------------------------------------
    def _build_widgets(self):
        pad = {"padx": 8, "pady": 4}
        frm = tk.Frame(self.root)
        frm.pack(fill="both", expand=True)

        # Target row
        trow = tk.Frame(frm)
        trow.pack(fill="x", **pad)
        tk.Label(trow, text="Call target").pack(side="left")
        self.target_var = tk.StringVar(
            value=self.cfg.get("target", "")
        )
        self.target_entry = tk.Entry(trow, textvariable=self.target_var)
        self.target_entry.pack(side="left", fill="x", expand=True, padx=(6, 0))

        # Message (TTS) area
        tk.Label(frm, text="Spoken message (text to speech)").pack(anchor="w", **pad)
        self.msg_text = scrolledtext.ScrolledText(frm, height=4)
        self.msg_text.pack(fill="x", **pad)
        self.msg_text.insert(
            "1.0",
            self.cfg.get("tts_text", "Hello, this is the caller bot. "
                                   "Please state your name after the beep."),
        )
        self.tts_btn = tk.Button(
            frm, text="Generate spoken message (TTS)", command=self._gen_tts
        )
        self.tts_btn.pack(fill="x", **pad)

        # Loop message playback while the call is connected
        self.loop_var = tk.BooleanVar(value=bool(self.cfg.get("loop", False)))
        self.loop_cb = tk.Checkbutton(
            frm, text="Loop message while connected",
            variable=self.loop_var,
        )
        self.loop_cb.pack(anchor="w", **pad)

        # Call / hangup
        crow = tk.Frame(frm)
        crow.pack(fill="x", **pad)
        self.call_btn = tk.Button(crow, text="Call", command=self._call, bg="#8f8")
        self.call_btn.pack(side="left", expand=True, fill="x")
        self.hangup_btn = tk.Button(
            crow, text="Hang up", command=self._hangup, state="disabled", bg="#f88"
        )
        self.hangup_btn.pack(side="left", expand=True, fill="x", padx=(6, 0))

        # Status
        self.status_var = tk.StringVar(value="Idle")
        tk.Label(
            frm, textvariable=self.status_var, relief="sunken", anchor="w"
        ).pack(fill="x", **pad)

        # Log
        tk.Label(frm, text="Log").pack(anchor="w", **pad)
        self.log = scrolledtext.ScrolledText(frm, height=6, state="disabled")
        self.log.pack(fill="both", expand=True, **pad)

    # ---- helpers ---------------------------------------------------------
    def _log(self, msg):
        self.log.configure(state="normal")
        self.log.insert("end", msg.rstrip("\n") + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def _events_cb(self, kind, payload=None):
        """Thread-safe callback to feed the GUI event queue."""
        self.events.put((kind, payload))

    # ---- actions ---------------------------------------------------------
    def _gen_tts(self):
        text = self.msg_text.get("1.0", "end").strip()
        if not text:
            messagebox.showwarning("TTS", "Type the message first.")
            return
        # Run the blocking speech synthesis on a background thread so the
        # tkinter mainloop never freezes (that made TTS look broken before).
        self.tts_btn.config(state="disabled")
        self._log("Generating TTS message...")

        def worker():
            try:
                path = caller_bot.make_tts_message(text)
                self.cfg["message_file"] = path
                self._events_cb("tts_ok", path)
            except Exception as e:
                self._events_cb("tts_err", str(e))

        threading.Thread(target=worker, daemon=True).start()

    def _call(self):
        if self.session is not None:
            return
        target = self.target_var.get().strip()
        if not target:
            messagebox.showwarning("Call", "Enter a call target first.")
            return
        cfg = dict(self.cfg)
        cfg["target"] = target
        cfg["loop"] = bool(self.loop_var.get())
        target_uri = caller_bot.make_sip_uri(target, cfg.get("sip_domain", ""))

        sess = caller_bot.CallSession(
            cfg,
            on_log=lambda m: self._events_cb("log", m),
            on_connected=lambda: self._events_cb("connected"),
            on_ended=lambda: self._events_cb("ended"),
            on_dtmf=lambda digit: self._events_cb("dtmf", digit),
        )
        self.session = sess

        def worker():
            ok = sess.start(target_uri, timeout=cfg.get("timeout", 300),
                            kill_strays=True)
            if not ok:
                self._events_cb("log", "Failed to start pjsua / reach CLI.")
                self._events_cb("ended")
                return
            sess.wait(timeout=cfg.get("timeout", 300))
            self._events_cb("ended")

        self._events_cb("calling")
        threading.Thread(target=worker, daemon=True).start()

    def _hangup(self):
        sess = self.session
        if sess is not None:
            self._log("Hanging up...")
            sess.hangup()
        else:
            self._events_cb("ended")

    # ---- event pump ------------------------------------------------------
    def _poll_events(self):
        try:
            while True:
                kind, payload = self.events.get_nowait()
                if kind == "log":
                    self._log(payload)
                elif kind == "tts_ok":
                    self.tts_btn.config(state="normal")
                    self._log("TTS message saved to %s" % payload)
                    self.status_var.set("Message updated")
                elif kind == "tts_err":
                    self.tts_btn.config(state="normal")
                    self._log("TTS error: %s" % payload)
                elif kind == "dtmf":
                    self._log("DTMF received: %s" % payload)
                elif kind == "calling":
                    self.status_var.set("Calling...")
                    self.call_btn.config(state="disabled")
                    self.hangup_btn.config(state="normal")
                elif kind == "connected":
                    self.connected = True
                    self.status_var.set("Connected")
                elif kind == "ended":
                    self.connected = False
                    self.session = None
                    self.status_var.set("Idle")
                    self.call_btn.config(state="normal")
                    self.hangup_btn.config(state="disabled")
        except queue.Empty:
            pass
        self.root.after(100, self._poll_events)

    def _on_close(self):
        if self.session is not None:
            if messagebox.askokcancel("Quit", "Hang up the active call and quit?"):
                self._hangup()
                self.root.destroy()
        else:
            self.root.destroy()


def main(cfg=None):
    root = tk.Tk()
    cfg = cfg if cfg is not None else caller_bot.load_config(verbose=False)
    CallerBotGUI(root, cfg)
    root.mainloop()


if __name__ == "__main__":
    main()
