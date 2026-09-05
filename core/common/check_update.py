# check_update.py
#
# Checks the project's own GitHub repo for newer releases:
#   https://github.com/Roschach96/Achievement-Enabler
#
# Compares the running .bat file's own last-modified date (passed in via
# --current-mtime, an ISO-8601 UTC timestamp) against the publish date of
# every release, and reports every release published after that date that
# hasn't been explicitly skipped (--skip-file, one tag per line - the
# caller is responsible for appending to it when the user chooses "skip").
# Uses the public GitHub REST API only (no browser/Playwright needed).

import argparse
import json
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

REPO = "Roschach96/Achievement-Enabler"
REPO_URL = "https://github.com/{0}".format(REPO)
RELEASES_PAGE_URL = "{0}/releases".format(REPO_URL)
RELEASES_API_URL = "https://api.github.com/repos/{0}/releases?per_page=30".format(REPO)

DEFAULT_TEMP_DIR = Path.home() / "AppData" / "Local" / "Temp"
DEFAULT_OUT_FILE = DEFAULT_TEMP_DIR / "ae_update_check_result.cmd"
DEFAULT_CHANGELOG_FILE = DEFAULT_TEMP_DIR / "ae_update_changelog.txt"


def parse_iso8601(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


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


def load_skip_set(skip_file):
    if not skip_file or not skip_file.exists():
        return set()
    try:
        return {
            line.strip() for line in skip_file.read_text(encoding="utf-8").splitlines()
            if line.strip()
        }
    except OSError:
        return set()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--current-mtime", required=True,
                         help="ISO-8601 UTC timestamp of the running .bat file's last write time")
    parser.add_argument("--result-file", type=Path, default=DEFAULT_OUT_FILE)
    parser.add_argument("--changelog-file", type=Path, default=DEFAULT_CHANGELOG_FILE)
    parser.add_argument("--skip-file", type=Path, default=None,
                         help="Text file of previously-skipped release tags, one per line")
    args = parser.parse_args()

    args.result_file.parent.mkdir(parents=True, exist_ok=True)
    args.changelog_file.parent.mkdir(parents=True, exist_ok=True)

    try:
        current_dt = parse_iso8601(args.current_mtime)
    except ValueError as e:
        print("[WARN] Could not parse --current-mtime '{0}': {1}".format(args.current_mtime, e))
        return

    try:
        releases = fetch_releases()
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ValueError) as e:
        print("[WARN] Could not check {0} for updates: {1}".format(REPO_URL, e))
        return

    skip_set = load_skip_set(args.skip_file)

    newer = []
    for release in releases:
        if release.get("draft") or release.get("prerelease"):
            continue
        tag = release.get("tag_name") or "?"
        published_raw = release.get("published_at") or release.get("created_at")
        if not published_raw:
            continue
        try:
            published_dt = parse_iso8601(published_raw)
        except ValueError:
            continue
        if published_dt.date() <= current_dt.date():
            continue
        if tag in skip_set:
            continue
        newer.append({
            "tag": tag,
            "published": published_dt,
            "body": (release.get("body") or "").strip(),
            "url": release.get("html_url") or REPO_URL,
        })

    if not newer:
        print("[INFO] No newer, non-skipped releases were found.")
        return

    newer.sort(key=lambda r: r["published"])

    changelog_lines = []
    for r in newer:
        changelog_lines.append("{0}  (published {1})".format(r["tag"], r["published"].strftime("%Y-%m-%d")))
        changelog_lines.append(r["body"] if r["body"] else "(no release notes)")
        changelog_lines.append("")
    args.changelog_file.write_text("\n".join(changelog_lines), encoding="utf-8")

    tags_joined = " ".join(r["tag"] for r in newer)

    lines = [
        'set "UPDATE_AVAILABLE=1"',
        'set "UPDATE_COUNT={0}"'.format(len(newer)),
        'set "UPDATE_TAGS={0}"'.format(tags_joined),
        'set "REMOTE_URL={0}"'.format(RELEASES_PAGE_URL),
        'set "CHANGELOG_FILE={0}"'.format(args.changelog_file),
    ]
    args.result_file.write_text("\n".join(lines) + "\n", encoding="ascii")
    print("[INFO] {0} release(s) newer than this script were found.".format(len(newer)))


if __name__ == "__main__":
    main()
