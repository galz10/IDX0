#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RELEASES_JSON=""
OUTPUT_PATH=""
TITLE="IDX0"
INCLUDE_PRERELEASE=0

usage() {
  cat <<'USAGE'
Generate a Sparkle-compatible appcast XML feed from release metadata.

Usage:
  ./scripts/generate-appcast.sh --releases-json <path> --output <path> [options]

Options:
  --releases-json <path>       JSON array of release entries.
  --output <path>              Output appcast.xml file path.
  --title <text>               Feed title. Default: IDX0
  --include-prerelease         Include prerelease entries (default excludes them)
  -h, --help                   Show help text

Entry schema (JSON array):
  version (required)
  downloadURL (or download_url) (required)
  length (required)
  pubDate (or published_at) (required, RFC3339)
  prerelease (optional, default false)
  signature (optional)
  minimumSystemVersion (optional)
  notesURL (or notes_url) (optional)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --releases-json)
      RELEASES_JSON="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="${2:-}"
      shift 2
      ;;
    --title)
      TITLE="${2:-}"
      shift 2
      ;;
    --include-prerelease)
      INCLUDE_PRERELEASE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$RELEASES_JSON" || -z "$OUTPUT_PATH" ]]; then
  echo "error: --releases-json and --output are required" >&2
  usage
  exit 1
fi

if [[ ! -f "$RELEASES_JSON" ]]; then
  echo "error: releases json not found: $RELEASES_JSON" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

python3 - "$RELEASES_JSON" "$OUTPUT_PATH" "$TITLE" "$INCLUDE_PRERELEASE" <<'PY'
from __future__ import annotations

import datetime as dt
import email.utils
import json
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

releases_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
title = sys.argv[3]
include_prerelease = sys.argv[4] == "1"

raw = json.loads(releases_path.read_text(encoding="utf-8"))
if not isinstance(raw, list):
    raise SystemExit("error: releases json must be an array")


def field(entry: dict, *names: str):
    for name in names:
        value = entry.get(name)
        if value is not None:
            return value
    return None


def parse_iso8601(value: str) -> dt.datetime:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    parsed = dt.datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def semver_key(version: str):
    v = version.strip().lstrip("vV")
    if not v:
        return ([], 1, "")
    main, _, suffix = v.partition("-")
    nums = []
    for token in main.split("."):
        token = token.strip()
        if token.isdigit():
            nums.append(int(token))
        else:
            nums.append(0)
    is_prerelease = 1 if suffix else 0
    # Lower is_prerelease should sort first for stable releases.
    return (nums, -is_prerelease, suffix)


entries = []
for item in raw:
    if not isinstance(item, dict):
        continue

    version = str(field(item, "version") or "").strip()
    download_url = str(field(item, "downloadURL", "download_url") or "").strip()
    length = field(item, "length")
    pub_date_raw = field(item, "pubDate", "published_at")
    prerelease = bool(field(item, "prerelease") or False)

    if not version or not download_url or length is None or not pub_date_raw:
        continue

    if not include_prerelease and prerelease:
        continue

    try:
        length_int = int(length)
    except Exception:
        continue

    if length_int <= 0:
        continue

    try:
        pub_date = parse_iso8601(str(pub_date_raw))
    except Exception:
        continue

    notes_url = field(item, "notesURL", "notes_url")
    signature = field(item, "signature")
    minimum_system_version = field(item, "minimumSystemVersion", "minimum_system_version")
    build_version = field(item, "buildVersion", "build_version")

    if not build_version:
        digits = re.findall(r"\d+", version)
        build_version = "".join(digits[:4]) or version

    entries.append(
        {
            "version": version,
            "download_url": download_url,
            "length": str(length_int),
            "pub_date": pub_date,
            "pub_date_http": email.utils.format_datetime(pub_date),
            "notes_url": str(notes_url) if notes_url else None,
            "signature": str(signature) if signature else None,
            "minimum_system_version": str(minimum_system_version) if minimum_system_version else None,
            "build_version": str(build_version),
            "prerelease": prerelease,
        }
    )

if not entries:
    raise SystemExit("error: no qualifying releases found for appcast generation")

entries.sort(key=lambda e: (semver_key(e["version"]), e["pub_date"]), reverse=True)

rss = ET.Element(
    "rss",
    {
        "version": "2.0",
        "xmlns:sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle",
        "xmlns:dc": "http://purl.org/dc/elements/1.1/",
    },
)
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = f"{title} Updates"
ET.SubElement(channel, "description").text = f"Latest releases for {title}"

for entry in entries:
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"{title} {entry['version']}"
    ET.SubElement(item, "pubDate").text = entry["pub_date_http"]

    enclosure_attrs = {
        "url": entry["download_url"],
        "length": entry["length"],
        "type": "application/octet-stream",
        "sparkle:version": entry["build_version"],
        "sparkle:shortVersionString": entry["version"],
    }

    if entry["signature"]:
        enclosure_attrs["sparkle:edSignature"] = entry["signature"]

    if entry["minimum_system_version"]:
        enclosure_attrs["sparkle:minimumSystemVersion"] = entry["minimum_system_version"]

    ET.SubElement(item, "enclosure", enclosure_attrs)

    if entry["notes_url"]:
        ET.SubElement(item, "sparkle:releaseNotesLink").text = entry["notes_url"]

ET.indent(rss, space="  ")
xml_text = ET.tostring(rss, encoding="utf-8", xml_declaration=True)
output_path.write_bytes(xml_text)
PY

echo "==> Wrote appcast: $OUTPUT_PATH"
