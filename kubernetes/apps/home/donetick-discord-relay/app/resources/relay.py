#!/usr/bin/env python3
"""Reshapes Donetick webhook events into Discord's expected payload and forwards them."""
import http.server
import json
import os
import urllib.error
import urllib.request

DISCORD_WEBHOOK_URL = os.environ["DISCORD_WEBHOOK_URL"]


def format_message(payload):
    event_type = payload.get("type", "unknown")
    data = payload.get("data") or {}
    lines = [f"**Donetick — {event_type}**"]
    lines += [f"{key}: {value}" for key, value in data.items()]
    return "\n".join(lines)


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

        discord_body = json.dumps({"content": format_message(payload)}).encode()
        request = urllib.request.Request(
            DISCORD_WEBHOOK_URL,
            data=discord_body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                status = response.status
        except urllib.error.HTTPError as error:
            status = error.code

        self.send_response(status if status < 400 else 502)
        self.end_headers()

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    http.server.HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
