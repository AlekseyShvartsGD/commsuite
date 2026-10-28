"""Tiny standard-library client for the Commsuite Bot API.

Create a bot in Commsuite → Settings → Developer tools, open its API dialog,
copy the token, and pass it here. No third-party packages are required.

    from commsuite_bot import CommsuiteBot

    bot = CommsuiteBot("http://localhost:3000", "cmsb_...")
    print(bot.me())
"""

import json
import urllib.error
import urllib.request


class CommsuiteError(RuntimeError):
    def __init__(self, status, message):
        super().__init__(f"{status}: {message}")
        self.status = status
        self.message = message


class CommsuiteBot:
    def __init__(self, base_url, token, request_timeout=60):
        self.api_base = base_url.rstrip("/") + "/api"
        self.token = token
        self.request_timeout = request_timeout

    def _request(self, method, path, data=None, timeout=None):
        body = None if data is None else json.dumps(data).encode("utf-8")
        request = urllib.request.Request(
            self.api_base + path,
            data=body,
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(
                request, timeout=timeout or self.request_timeout
            ) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            try:
                payload = json.load(error)
                message = payload.get("error", error.reason)
            except Exception:
                message = error.reason
            raise CommsuiteError(error.code, message) from None

    def me(self):
        return self._request("GET", "/bot/me")

    def get_updates(self, offset=0, timeout=30, limit=100):
        """Long-polls for messages. Pass the last updateId back as offset."""
        query = f"?offset={int(offset)}&timeout={int(timeout)}&limit={int(limit)}"
        return self._request(
            "GET", "/bot/updates" + query, timeout=timeout + 10
        )["updates"]

    def send_message(self, conversation_id, text, reply_to=None):
        payload = {"conversationId": conversation_id, "text": text}
        if reply_to:
            payload["replyTo"] = reply_to
        return self._request("POST", "/bot/sendMessage", payload)["message"]

    # The regular API is available too, e.g. conversations() to discover id's.
    def conversations(self):
        return self._request("GET", "/conversations")["conversations"]

    def messages(self, conversation_id, limit=50):
        return self._request(
            "GET", f"/conversations/{conversation_id}/messages?limit={int(limit)}"
        )["messages"]

    def run(self, handler, poll_timeout=30):
        """Calls handler(update) forever, acknowledging each batch."""
        offset = 0
        while True:
            updates = self.get_updates(offset=offset, timeout=poll_timeout)
            for update in updates:
                offset = update["updateId"]
                handler(update)
