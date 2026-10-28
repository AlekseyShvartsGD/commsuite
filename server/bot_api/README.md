# Commsuite Bot API

Bots are real Commsuite accounts (`role = 'bot'`). They appear in People, can
be added to groups, and cannot sign in with a password. Each bot has an API
token that lets your own program act as that account.

Create a bot in **Settings → Developer tools**, then open **API** on the bot
card to copy its token. The same dialog contains a ready-to-run Python example.

## Endpoints

All requests use `Authorization: Bearer cmsb_…`.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/bot/me` | Bot identity |
| GET | `/api/bot/updates?offset=0&timeout=30&limit=100` | Long-poll incoming messages |
| POST | `/api/bot/sendMessage` | Send a message |

`sendMessage` body:

```json
{ "conversationId": "…", "text": "hello", "replyTo": "optional-message-id" }
```

`updates` response:

```json
{
  "updates": [
    {
      "updateId": 42,
      "conversationId": "…",
      "message": { "id": "…", "senderId": "…", "body": "hi", "…": "…" }
    }
  ]
}
```

Pass the last `updateId` as `offset` on the next request; acknowledged updates
are deleted. `timeout` keeps the request open while the bot is idle (maximum
50 seconds). A paused bot rejects its token with `401`.

A bot can also call the regular user API (`/api/conversations`,
`/api/conversations/:id/messages`, …) with the same token.

## Python

```python
from commsuite_bot import CommsuiteBot

bot = CommsuiteBot("http://localhost:3000", "cmsb_…")

def handle(update):
    message = update["message"]
    bot.send_message(update["conversationId"], "echo: " + message["body"])

bot.run(handle)
```

See `commsuite_bot.py` for the small standard-library client and
`example_echo_bot.py` for a complete echo bot. Only Python 3.8+ is required;
there are no external dependencies.

## Built-in replies and mini-apps

Bots without an external program can still use keyword replies and one
mini-app (JSON formatter, Base64, or UUID generator). Both are managed from the
bot card in Developer tools. `send /help` to a bot to discover its commands.

External programs receive updates for every message sent to the bot by a
human account. Messages sent by other bots are not queued, which prevents
runaway loops between automated accounts.
