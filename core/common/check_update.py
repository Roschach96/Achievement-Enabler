# check_update.py
#
# Checks the project's own GitHub repo for newer releases:
#   https://github.com/Roschach96/Achievement-Enabler
#
# Compares --current-tag (the AE_VERSION string hardcoded at the top of
# _Achievement_Enabler.bat, e.g. "V5.7") against every release tag from the
# GitHub API by version number. Every release with a higher version counts
# as "newer".
#
# Tags in --skip-file (one tag per line - the caller appends
# to it when the user chooses "skip") are excluded. Uses the public GitHub
# REST API only (no browser/Playwright needed).

import argparse
import json
import re
import urllib.error
import urllib.request
from pathlib import Path

REPO = "Roschach96/Achievement-Enabler"
REPO_URL = "https://github.com/{0}".format(REPO)
RELEASES_PAGE_URL = "{0}/releases".format(REPO_URL)
RELEASES_API_URL = "https://api.github.com/repos/{0}/releases?per_page=30".format(REPO)

DEFAULT_TEMP_DIR = Path.home() / "AppData" / "Local" / "Temp"
DEFAULT_OUT_FILE = DEFAULT_TEMP_DIR / "ae_update_check_result.cmd"
DEFAULT_CHANGELOG_FILE = DEFAULT_TEMP_DIR / "ae_update_changelog.txt"


def parse_version(tag):
    """'V5.7' -> (5, 7). Returns None if the tag has no version number."""
    nums = re.findall(r"\d+", tag or "")
    if not nums:
        return None
    parts = [int(n) for n in nums]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()  # V5 == V5.0
    return tuple(parts)


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
    parser.add_argument("--current-tag", required=True,
                         help='Hardcoded AE_VERSION from the .bat, e.g. "V5.7"')
    parser.add_argument("--result-file", type=Path, default=DEFAULT_OUT_FILE)
    parser.add_argument("--changelog-file", type=Path, default=DEFAULT_CHANGELOG_FILE)
    parser.add_argument("--skip-file", type=Path, default=None,
                         help="Text file of previously-skipped release tags, one per line")
    args = parser.parse_args()

    args.result_file.parent.mkdir(parents=True, exist_ok=True)
    args.changelog_file.parent.mkdir(parents=True, exist_ok=True)

    try:
        releases = fetch_releases()
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ValueError) as e:
        print("[WARN] Could not check {0} for updates: {1}".format(REPO_URL, e))
        return

    skip_set = load_skip_set(args.skip_file)

    non_draft_releases = [
        r for r in releases if not r.get("draft") and not r.get("prerelease")
    ]

    current_ver = parse_version(args.current_tag)
    if current_ver is None:
        print("[WARN] Could not parse current version '{0}'.".format(args.current_tag))
        return

    newer = []
    for release in non_draft_releases:
        tag = release.get("tag_name") or "?"
        if tag in skip_set:
            continue
        ver = parse_version(tag)
        if ver is None or ver <= current_ver:
            continue
        newer.append({
            "ver": ver,
            "tag": tag,
            "body": (release.get("body") or "").strip(),
            "url": release.get("html_url") or REPO_URL,
        })
    newer.sort(key=lambda r: r["ver"], reverse=True)  # latest-first

    if not newer:
        print("[INFO] No newer, non-skipped releases were found.")
        return

    changelog_lines = []
    for r in reversed(newer):
        changelog_lines.append(r["tag"])
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
    print("[INFO] {0} release(s) newer than the installed tag were found.".format(len(newer)))


if __name__ == "__main__":
    main()
