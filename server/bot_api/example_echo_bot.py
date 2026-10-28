"""Echo bot example.

1. In Commsuite: Settings → Developer tools → New bot.
2. Open the bot's API dialog and copy its token.
3. Set SERVER and TOKEN below, then run:

       python example_echo_bot.py

4. Find the bot in People and send it a message.
"""

from commsuite_bot import CommsuiteBot

SERVER = "http://localhost:3000"
TOKEN = "cmsb_replace_me"


def handle(update):
    message = update["message"]
    text = message.get("body") or ""
    if not text:
        return
    bot.send_message(
        update["conversationId"],
        f"echo: {text}",
        reply_to=message["id"],
    )


bot = CommsuiteBot(SERVER, TOKEN)
print("Connected as", bot.me()["username"])
bot.run(handle)
