#!/usr/bin/env python3
"""Reshapes Donetick webhook events into Discord's expected payload and forwards them."""
import http.server
import json
import os
import sys
import urllib.error
import urllib.request

DISCORD_WEBHOOK_URL = os.environ["DISCORD_WEBHOOK_URL"]

EVENT_STYLES = {
    "task.created": ("🆕", 0x5865F2),
    "task.completed": ("✅", 0x57F287),
    "task.updated": ("✏️", 0xFEE75C),
    "task.deleted": ("🗑️", 0xED4245),
}
DEFAULT_STYLE = ("🔔", 0x99AAB5)


def build_embed(payload):
    event_type = payload.get("type", "unknown")
    data = payload.get("data") or {}
    chore = data.get("chore") if isinstance(data.get("chore"), dict) else {}
    emoji, color = EVENT_STYLES.get(event_type, DEFAULT_STYLE)

    embed = {
        "title": f"{emoji} {event_type.replace('.', ' ').replace('_', ' ').title()}",
        "color": color,
        "fields": [],
    }

    if chore.get("name"):
        embed["fields"].append({"name": "Chore", "value": chore["name"], "inline": True})

    who = data.get("display_name") or data.get("username")
    if who:
        embed["fields"].append({"name": "By", "value": who, "inline": True})

    if chore.get("nextDueDate"):
        embed["fields"].append({"name": "Next Due", "value": chore["nextDueDate"], "inline": True})

    note = data.get("note")
    if note:
        embed["fields"].append({"name": "Note", "value": note, "inline": False})

    timestamp = chore.get("updatedAt") or chore.get("createdAt")
    if timestamp:
        embed["timestamp"] = timestamp

    embed["footer"] = {"text": "Donetick"}

    return embed


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path == "/healthz" else 404)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b"{}"

        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            return

        discord_body = json.dumps({"embeds": [build_embed(payload)]}).encode()
        request = urllib.request.Request(
            DISCORD_WEBHOOK_URL,
            data=discord_body,
            headers={
                "Content-Type": "application/json",
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            },
            method="POST",
        )

        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                status = response.status
        except urllib.error.HTTPError as error:
            status = error.code
            print(f"discord returned {status}: {error.read().decode(errors='replace')}", file=sys.stderr)
        except urllib.error.URLError as error:
            print(f"discord request failed: {error.reason}", file=sys.stderr)
            self.send_response(502)
            self.end_headers()
            return

        self.send_response(status if status < 400 else 502)
        self.end_headers()

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    http.server.HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
