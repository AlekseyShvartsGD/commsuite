import json
import os
import sqlite3
import sys
import urllib.error
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(HERE, "..", "bot_api")))
from commsuite_bot import CommsuiteBot, CommsuiteError  # noqa: E402

BASE = "http://127.0.0.1:3000/api"
SUFFIX = uuid.uuid4().hex[:8]
USERNAME = f"zzapi_{SUFFIX}"
PASSWORD = "test-pass-12345"

user_token = ""
user_id = ""
bot_id = ""
conv_id = ""
bot = None


def http(method, path, body=None, token=None):
    request = urllib.request.Request(
        BASE + path,
        data=None if body is None else json.dumps(body).encode(),
        method=method,
        headers={
            **({"Content-Type": "application/json"} if body is not None else {}),
            **({"Authorization": f"Bearer {token}"} if token else {}),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        try:
            return error.code, json.load(error)
        except Exception:
            return error.code, {}


def check(name, ok, extra=""):
    print(f"{'PASS' if ok else 'FAIL'} {name}" + (f" — {extra}" if extra else ""))
    if not ok:
        raise SystemExit(1)


def cleanup():
    db = sqlite3.connect(os.path.abspath(os.path.join(HERE, "..", "data", "app.db")))
    try:
        convs = db.execute(
            """SELECT DISTINCT c.id FROM conversations c
               LEFT JOIN group_members gm ON gm.conversation_id = c.id
               WHERE c.user_low IN (?, ?) OR c.user_high IN (?, ?)
                  OR (c.kind = 'group' AND gm.user_id IN (?, ?))""",
            (user_id, bot_id, user_id, bot_id, user_id, bot_id),
        ).fetchall()
        for (cid,) in convs:
            for table in ("messages", "group_members"):
                db.execute(f"DELETE FROM {table} WHERE conversation_id = ?", (cid,))
            db.execute("DELETE FROM conversations WHERE id = ?", (cid,))
        if bot_id:
            db.execute("DELETE FROM bot_updates WHERE bot_id = ?", (bot_id,))
            db.execute("DELETE FROM bot_replies WHERE bot_id = ?", (bot_id,))
            db.execute("DELETE FROM bots WHERE user_id = ?", (bot_id,))
        for uid in (bot_id, user_id):
            if not uid:
                continue
            db.execute("DELETE FROM blocks WHERE blocked_by = ? OR blocked = ?", (uid, uid))
            db.execute("DELETE FROM reports WHERE reporter_id = ? OR target_id = ?", (uid, uid))
            db.execute("DELETE FROM users WHERE id = ?", (uid,))
        db.commit()
    finally:
        db.close()


try:
    status, data = http(
        "POST",
        "/register",
        {
            "username": USERNAME,
            "password": PASSWORD,
            "displayName": f"API Tester {SUFFIX}",
            "bio": "",
        },
    )
    check("register test user", status == 201, f"status {status}")
    user_token = data["token"]
    user_id = data["user"]["id"]

    status, data = http(
        "POST",
        "/bots",
        {
            "name": "API Bot Test",
            "description": "Programmed externally",
            "mode": "api",
        },
        user_token,
    )
    check("create external bot", status == 201, f"status {status}")
    created = data["bot"]
    bot_id = created["user"]["id"]
    check("external bot starts in API mode", created.get("mode") == "api")
    check(
        "bot token is issued",
        created.get("token", "").startswith("cmsb_"),
        created.get("token", "")[:12],
    )

    bot = CommsuiteBot("http://127.0.0.1:3000", created["token"])
    me = bot.me()
    check("bot API /me", me["id"] == bot_id and me["username"] == created["user"]["username"])

    status, data = http("POST", "/conversations", {"peerId": bot_id}, user_token)
    conv_id = data["conversation"]["id"]
    check("user opens chat with bot", status in (200, 201), f"status {status}")

    status, _ = http(
        "POST",
        f"/conversations/{conv_id}/messages",
        {"kind": "text", "body": "hello bot"},
        user_token,
    )
    check("user sends message", status == 201, f"status {status}")

    updates = bot.get_updates(timeout=5)
    check("bot long-polls its updates", len(updates) == 1, f"{len(updates)} update(s)")
    update = updates[0]
    check(
        "update carries the incoming message",
        update["conversationId"] == conv_id
        and update["message"]["body"] == "hello bot",
    )
    check(
        "API-mode bot does not add built-in help",
        all(u["message"]["senderId"] != bot_id for u in updates),
    )

    sent = bot.send_message(
        conv_id, "echo hello bot", reply_to=update["message"]["id"]
    )
    check("bot sends through bot API", sent["senderId"] == bot_id)

    status, data = http(
        "GET", f"/conversations/{conv_id}/messages?limit=50", token=user_token
    )
    check(
        "user receives the bot reply",
        status == 200
        and any(
            m["senderId"] == bot_id and m["body"] == "echo hello bot"
            for m in data["messages"]
        ),
    )

    acked = bot.get_updates(offset=update["updateId"], timeout=0)
    check("updates are acknowledged by offset", acked == [])

    http("PATCH", f"/bots/{bot_id}", {"enabled": False}, user_token)
    try:
        bot.me()
        check("paused bot token is rejected", False)
    except CommsuiteError as error:
        check("paused bot token is rejected", error.status == 401, f"status {error.status}")

    http("PATCH", f"/bots/{bot_id}", {"enabled": True}, user_token)
    check("resumed bot token works", bot.me()["id"] == bot_id)

    status, data = http("POST", f"/bots/{bot_id}/token", token=user_token)
    new_token = data.get("bot", {}).get("token", "")
    check(
        "token rotation returns a different token",
        status == 200 and new_token.startswith("cmsb_") and new_token != created["token"],
    )
    try:
        bot.me()
        check("old token is invalidated", False)
    except CommsuiteError as error:
        check("old token is invalidated", error.status == 401, f"status {error.status}")
    replaced = CommsuiteBot("http://127.0.0.1:3000", new_token)
    check("new token works", replaced.me()["id"] == bot_id)

    status, data = http("DELETE", f"/bots/{bot_id}", token=user_token)
    check("delete bot", status == 200)
    bot_id = ""
finally:
    cleanup()
    print("cleaned up test rows")
