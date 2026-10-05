#!/usr/bin/env python3
"""Delete stale approved Seerr requests and notify via Discord.

Seerr can leave an APPROVED request behind when its media is unmonitored or
removed in Radarr/Sonarr: the media row becomes UNKNOWN/DELETED while the
request stays APPROVED. Seerr's duplicate guard then rejects any new request
for that title with 409 "Request for this media already exists".

This job finds those stale requests, deletes them so the titles become
requestable again, and DMs the admin through the Requestrr Discord bot.
"""
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

SEERR_URL = os.environ.get(
    "SEERR_URL", "http://seerr.media.svc.cluster.local:5055/api/v1"
).rstrip("/")
SEERR_API_KEY = os.environ.get("SEERR_API_KEY", "")
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"
MIN_AGE_HOURS = float(os.environ.get("MIN_AGE_HOURS", "1"))

DISCORD_API = "https://discord.com/api/v10"
DISCORD_BOT_TOKEN = os.environ.get("DISCORD_BOT_TOKEN", "")
DISCORD_USER_ID = os.environ.get("DISCORD_USER_ID", "")
DISCORD_NOTIFY_ALWAYS = (
    os.environ.get("DISCORD_NOTIFY_ALWAYS", "false").lower() == "true"
)

# Seerr constants
REQUEST_APPROVED = 2
MEDIA_UNKNOWN = 1
MEDIA_DELETED = 7
MEDIA_STATUS_NAMES = {
    1: "UNKNOWN",
    2: "PENDING",
    3: "PROCESSING",
    4: "PARTIALLY_AVAILABLE",
    5: "AVAILABLE",
    6: "BLOCKLISTED",
    7: "DELETED",
}

PAGE_SIZE = 100
MAX_NOTIFICATION_ITEMS = 15
MAX_NOTIFICATION_LENGTH = 1990


def seerr_api(path, method="GET"):
    request = urllib.request.Request(
        f"{SEERR_URL}{path}",
        method=method,
        headers={"X-Api-Key": SEERR_API_KEY, "Accept": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
        return json.loads(body) if body else None


def find_stale_requests():
    stale = []
    skip = 0
    while True:
        page = seerr_api(
            f"/request?take={PAGE_SIZE}&skip={skip}&sort=added&filter=unavailable"
        )
        results = page.get("results", [])
        for request in results:
            if request.get("status") != REQUEST_APPROVED:
                continue
            media = request.get("media") or {}
            media_status = (
                media.get("status4k") if request.get("is4k") else media.get("status")
            )
            if media_status not in (MEDIA_UNKNOWN, MEDIA_DELETED):
                continue
            created_at = request.get("createdAt")
            try:
                created = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
                age_hours = (
                    datetime.now(timezone.utc) - created
                ).total_seconds() / 3600
            except (AttributeError, ValueError):
                age_hours = MIN_AGE_HOURS
            if age_hours < MIN_AGE_HOURS:
                continue
            stale.append(
                {
                    "id": request.get("id"),
                    "type": request.get("type"),
                    "tmdbId": media.get("tmdbId"),
                    "mediaStatus": media_status,
                    "createdAt": created_at,
                    "requestedBy": (request.get("requestedBy") or {}).get(
                        "displayName"
                    ),
                }
            )
        if len(results) < PAGE_SIZE:
            return stale
        skip += PAGE_SIZE


def discord_api(path, payload):
    request = urllib.request.Request(
        f"{DISCORD_API}{path}",
        method="POST",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bot {DISCORD_BOT_TOKEN}",
            "Content-Type": "application/json",
            "User-Agent": "seerr-cleanup (home-ops)",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
        return json.loads(body) if body else None


def send_discord_dm(content):
    if not DISCORD_BOT_TOKEN or not DISCORD_USER_ID:
        print(
            "Discord notification skipped: DISCORD_BOT_TOKEN or DISCORD_USER_ID "
            "is not set.",
            file=sys.stderr,
        )
        return
    channel = discord_api("/users/@me/channels", {"recipient_id": DISCORD_USER_ID})
    discord_api(
        f"/channels/{channel['id']}/messages",
        {"content": content[:MAX_NOTIFICATION_LENGTH]},
    )
    print("Discord notification sent.")


def build_message(stale, failures):
    if not stale:
        return "🧹 Seerr cleanup: no stale approved requests found."

    verb = "would delete" if DRY_RUN else "deleted"
    lines = [
        f"🧹 Seerr cleanup: {verb} {len(stale)} stale approved request(s)"
    ]
    for request in stale[:MAX_NOTIFICATION_ITEMS]:
        status = MEDIA_STATUS_NAMES.get(request["mediaStatus"], request["mediaStatus"])
        lines.append(
            f"• {request['type']} tmdb {request['tmdbId']} — "
            f"requested by {request['requestedBy']} — media {status} — "
            f"request #{request['id']}"
        )
    if len(stale) > MAX_NOTIFICATION_ITEMS:
        lines.append(f"…and {len(stale) - MAX_NOTIFICATION_ITEMS} more")
    if failures:
        lines.append(f"⚠️ {failures} request(s) failed to delete, check the job logs")
    return "\n".join(lines)


def main():
    if not SEERR_API_KEY:
        print("SEERR_API_KEY is not set.", file=sys.stderr)
        sys.exit(1)

    stale = find_stale_requests()
    if not stale:
        print("No stale approved requests found.")

    failures = 0
    for request in stale:
        status = MEDIA_STATUS_NAMES.get(request["mediaStatus"], request["mediaStatus"])
        print(
            "Stale approved request: "
            f"id={request['id']} type={request['type']} "
            f"tmdbId={request['tmdbId']} mediaStatus={status} "
            f"created={request['createdAt']} requestedBy={request['requestedBy']}"
        )
        if DRY_RUN:
            print(f"  dry-run: would delete request {request['id']}")
            continue
        try:
            seerr_api(f"/request/{request['id']}", method="DELETE")
            print(f"  deleted request {request['id']}")
        except urllib.error.HTTPError as error:
            failures += 1
            detail = error.read().decode(errors="replace")[:200]
            print(
                f"  failed to delete request {request['id']}: "
                f"HTTP {error.code} {detail}",
                file=sys.stderr,
            )

    if stale or DISCORD_NOTIFY_ALWAYS:
        try:
            send_discord_dm(build_message(stale, failures))
        except Exception as error:  # noqa: BLE001 - notification is best effort
            print(f"Failed to send Discord notification: {error}", file=sys.stderr)

    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
