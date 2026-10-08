#!/usr/bin/env python3
"""Render jellarr's config template with the Pocket ID OIDC client credentials.

The Jellyfin Security plugin needs the client secret from the Secret generated
by the PocketIDOIDCClient (kubernetes/apps/media/jellyfin/app/oidc). jellarr only
reads config from a file and has no env-var interpolation of its own, so this
runs as an init container and writes the rendered config into the /config
emptyDir that the jellarr container reads.

The jellarr image's working directory is /, so the default config path
(config/config.yml) resolves to /config/config.yml.
"""

import os
from pathlib import Path


def yaml_double_quoted(value: str) -> str:
    """Escape a value so it can be safely substituted inside a YAML
    double-quoted scalar (the template wraps the placeholders in quotes)."""
    return (
        value.strip()
        .replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )


template = Path("/templates/config.yml").read_text()

for placeholder, env_var in (
    ("__JELLYFIN_OIDC_CLIENT_ID__", "JELLYFIN_OIDC_CLIENT_ID"),
    ("__JELLYFIN_OIDC_CLIENT_SECRET__", "JELLYFIN_OIDC_CLIENT_SECRET"),
):
    template = template.replace(
        placeholder, yaml_double_quoted(os.environ[env_var])
    )

Path("/config/config.yml").write_text(template)
