#!/usr/bin/env python3
"""Reshapes Donetick webhook events into Discord's expected payload and forwards them."""
from datetime import datetime, timezone, timedelta
import http.server
import json
import os
import sys
import urllib.error
import urllib.request

try:
    from zoneinfo import ZoneInfo
    CT = ZoneInfo("America/Chicago")
except Exception:
    CT = timezone(timedelta(hours=-5))

def fmt_ts(ts_str):
    try:
        dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        return dt.astimezone(CT).strftime("%b %d, %Y at %I:%M %p")
    except (ValueError, TypeError):
        return ts_str

DISCORD_WEBHOOK_URL = os.environ["DISCORD_WEBHOOK_URL"]

EVENT_STYLES = {
    "task.created": ("🆕", 0x5865F2),
    "task.completed": ("✅", 0x57F287),
    "task.updated": ("✏️", 0xFEE75C),
    "task.deleted": ("🗑️", 0xED4245),
    "task.reminder": ("⏰", 0xE67E22),
    "task.due": ("📅", 0xE67E22),
    "chore.reminder": ("⏰", 0xE67E22),
}
DEFAULT_STYLE = ("🔔", 0x99AAB5)


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def build_embed(payload):
    event_type = payload.get("type", "unknown")
    data = payload.get("data") or {}
    chore = data.get("chore") if isinstance(data.get("chore"), dict) else {}
    emoji, color = EVENT_STYLES.get(event_type, DEFAULT_STYLE)

    chore_name = chore.get("name") or data.get("chore_name") or data.get("name") or data.get("title") or ""

    if event_type == "task.reminder":
        reminder_type = data.get("type")
        label = f"{reminder_type.replace('_', ' ').title()} Reminder" if reminder_type else "Reminder"
    else:
        label = event_type.replace("task.", "").replace("_", " ").title()

    title = f"{emoji} {label}: {chore_name}" if chore_name else f"{emoji} {label}"
    embed = {
        "title": title,
        "color": color,
        "fields": [],
    }

    if chore_name:
        embed["fields"].append({"name": "Chore", "value": chore_name, "inline": True})

    who = data.get("display_name") or data.get("username") or data.get("assignee")
    if who:
        embed["fields"].append({"name": "By", "value": who, "inline": True})

    next_due = chore.get("nextDueDate") or data.get("nextDueDate") or data.get("due_date") or data.get("dueDate")
    if next_due:
        embed["fields"].append({"name": "Next Due", "value": fmt_ts(next_due), "inline": True})

    note = data.get("note") or chore.get("note")
    if note:
        embed["fields"].append({"name": "Note", "value": note, "inline": False})

    description = data.get("description") or chore.get("description")
    if description:
        embed["fields"].append({"name": "Description", "value": description, "inline": False})

    timestamp = chore.get("updatedAt") or chore.get("createdAt") or data.get("timestamp")
    if timestamp:
        embed["timestamp"] = timestamp

    sent = payload.get("timestamp")
    footer = f"Donetick · {fmt_ts(sent)}" if sent else "Donetick"
    embed["footer"] = {"text": footer}

    return embed


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path == "/healthz" else 404)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b"{}"

        log(f"[IN] {self.command} {self.path} ({length} bytes)")

        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            log(f"[IN] invalid JSON: {body[:500]}")
            self.send_response(400)
            self.end_headers()
            return

        log(f"[IN] payload: {json.dumps(payload, indent=2, default=str)}")

        embed = build_embed(payload)
        discord_body = json.dumps({"embeds": [embed]}).encode()
        log(f"[OUT] discord payload: {discord_body.decode()}")

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
                log(f"[OUT] discord response: {status}")
        except urllib.error.HTTPError as error:
            status = error.code
            log(f"[OUT] discord error {status}: {error.read().decode(errors='replace')}")
        except urllib.error.URLError as error:
            log(f"[OUT] discord request failed: {error.reason}")
            self.send_response(502)
            self.end_headers()
            return

        self.send_response(status if status < 400 else 502)
        self.end_headers()


if __name__ == "__main__":
    http.server.HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
