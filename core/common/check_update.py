# check_update.py
#
# Checks the project's own GitHub repo for newer releases:
#   https://github.com/Roschach96/Achievement-Enabler
#
# Uses the public GitHub REST API only (no browser/Playwright needed).
# Release tags are expected to look like "V5" / "v5" (matching the leading
# digits used in the script's own filename versioning, e.g.
# "_Achievement_Enabler_V5.bat" -> SCRIPT_VER=5).

import argparse
import json
import re
import urllib.error
import urllib.request
from pathlib import Path

REPO = "Roschach96/Achievement-Enabler"
REPO_URL = "https://github.com/{0}".format(REPO)
RELEASES_API_URL = "https://api.github.com/repos/{0}/releases?per_page=30".format(REPO)
TAG_VERSION_PATTERN = re.compile(r'^[vV]?(\d+)')

DEFAULT_TEMP_DIR = Path.home() / "AppData" / "Local" / "Temp"
DEFAULT_OUT_FILE = DEFAULT_TEMP_DIR / "ae_update_check_result.cmd"
DEFAULT_CHANGELOG_FILE = DEFAULT_TEMP_DIR / "ae_update_changelog.txt"


def fetch_releases():
    request = urllib.request.Request(
        RELEASES_API_URL,
        headers={
            "User-Agent": "AchievementEnablerUpdateCheck",
            "Accept": "application/vnd.github+json",
        },
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read().decode("utf-8"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--current-version", type=int, default=0)
    parser.add_argument("--result-file", type=Path, default=DEFAULT_OUT_FILE)
    parser.add_argument("--changelog-file", type=Path, default=DEFAULT_CHANGELOG_FILE)
    args = parser.parse_args()

    args.result_file.parent.mkdir(parents=True, exist_ok=True)
    args.changelog_file.parent.mkdir(parents=True, exist_ok=True)

    try:
        releases = fetch_releases()
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ValueError) as e:
        print("[WARN] Could not check {0} for updates: {1}".format(REPO_URL, e))
        return

    entries = {}
    release_urls = {}
    for release in releases:
        if release.get("draft") or release.get("prerelease"):
            continue
        tag_name = release.get("tag_name") or ""
        match = TAG_VERSION_PATTERN.match(tag_name.strip())
        if not match:
            continue
        ver = int(match.group(1))
        entries[ver] = (release.get("body") or "").strip()
        release_urls[ver] = release.get("html_url") or REPO_URL

    if not entries:
        print("[WARN] No releases with a recognizable version tag found at {0}".format(REPO_URL))
        return

    remote_ver = max(entries)
    remote_url = release_urls[remote_ver]

    lines = [
        'set "REMOTE_VER={0}"'.format(remote_ver),
        'set "REMOTE_URL={0}"'.format(remote_url),
    ]

    new_entries = sorted(
        (v, body) for v, body in entries.items()
        if args.current_version < v <= remote_ver
    )

    if new_entries:
        changelog_lines = []
        for v, body in new_entries:
            changelog_lines.append("V{0}:".format(v))
            changelog_lines.append(body if body else "(no release notes)")
            changelog_lines.append("")
        args.changelog_file.write_text("\n".join(changelog_lines), encoding="utf-8")
        lines.append('set "CHANGELOG_FILE={0}"'.format(args.changelog_file))

    args.result_file.write_text("\n".join(lines) + "\n", encoding="ascii")
    print("[INFO] Remote version: {0}".format(remote_ver))
    if new_entries:
        print("[INFO] {0} new changelog entr{1} found.".format(
            len(new_entries), "y" if len(new_entries) == 1 else "ies"
        ))


if __name__ == "__main__":
    main()
