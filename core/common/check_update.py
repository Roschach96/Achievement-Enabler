# TODO: this still points at the original ColdClient semi-auto forum thread
# and version-string format. Repoint URL/VER_PATTERN/CHANGELOG_BLOCK_PATTERN
# at wherever "Achievement Enabler" itself is actually published before
# relying on this for real update notifications.
import argparse
import html as html_module
import importlib.util
import re
import subprocess
import sys
from pathlib import Path

URL = "https://cs.rin.ru/forum/viewtopic.php?p=3447840#p3447840"
VER_PATTERN = re.compile(r'Achievement Enabler from Game Folder V(\d+)\.7z', re.IGNORECASE)
CHANGELOG_BLOCK_PATTERN = re.compile(
    r'Achievement Enabler Changelog.*?<div class="quotecontent"[^>]*>\s*'
    r'<div style="display: none;">(?P<body>.*?)</div></div>',
    re.IGNORECASE | re.DOTALL,
)
ENTRY_SPLIT_PATTERN = re.compile(r'(?m)^V(\d+):$')
DEFAULT_TEMP_DIR = Path.home() / "AppData" / "Local" / "Temp"
DEFAULT_OUT_FILE = DEFAULT_TEMP_DIR / "ae_update_check_result.cmd"
DEFAULT_CHANGELOG_FILE = DEFAULT_TEMP_DIR / "ae_update_changelog.txt"


def ensure_playwright():
    if importlib.util.find_spec("playwright") is None:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "playwright"])
    subprocess.check_call([sys.executable, "-m", "playwright", "install", "chromium"])


def html_to_text(fragment):
    text = re.sub(r'(?i)<br\s*/?>', '\n', fragment)
    text = re.sub(r'<[^>]+>', '', text)
    text = html_module.unescape(text)
    return text


def extract_changelog(html):
    m = CHANGELOG_BLOCK_PATTERN.search(html)
    if not m:
        return {}

    text = html_to_text(m.group("body"))
    parts = ENTRY_SPLIT_PATTERN.split(text)
    # parts = [prefix, 'ver1', body1, 'ver2', body2, ...]
    entries = {}
    for i in range(1, len(parts) - 1, 2):
        ver_num = int(parts[i])
        body = parts[i + 1].strip("\n")
        body = re.sub(r'\n{3,}', '\n\n', body).strip()
        entries[ver_num] = body
    return entries


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--current-version", type=int, default=0)
    parser.add_argument("--result-file", type=Path, default=DEFAULT_OUT_FILE)
    parser.add_argument("--changelog-file", type=Path, default=DEFAULT_CHANGELOG_FILE)
    args = parser.parse_args()

    args.result_file.parent.mkdir(parents=True, exist_ok=True)
    args.changelog_file.parent.mkdir(parents=True, exist_ok=True)

    ensure_playwright()
    from playwright.sync_api import sync_playwright

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=True,
            args=[
                "--disable-blink-features=AutomationControlled",
                "--no-sandbox",
                "--disable-dev-shm-usage",
            ],
        )
        page = browser.new_page(
            user_agent=(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/131.0 Safari/537.36"
            )
        )
        try:
            page.goto(URL, wait_until="domcontentloaded", timeout=30000)
            try:
                page.wait_for_load_state("networkidle", timeout=15000)
            except Exception:
                pass
            page.wait_for_timeout(2000)
            html = page.content()
        finally:
            browser.close()

    ver_match = VER_PATTERN.search(html)
    ver = ver_match.group(1) if ver_match else None

    if not ver:
        debug_file = args.result_file.parent / "gbe_update_debug.html"
        debug_file.write_text(html, encoding="utf-8", errors="ignore")
        found_text = "Achievement Enabler" in html
        print("[WARN] Update link pattern not found on page.")
        print("[DEBUG] 'Achievement Enabler' present in fetched HTML: {0}".format(found_text))
        print("[DEBUG] Fetched HTML length: {0}".format(len(html)))
        print("[DEBUG] Full page saved to: {0}".format(debug_file))
        return

    remote_ver = int(ver)
    lines = [
        'set "REMOTE_VER={0}"'.format(ver),
        'set "REMOTE_URL={0}"'.format(URL),
    ]

    changelog = extract_changelog(html)
    new_entries = sorted(
        (v, body) for v, body in changelog.items()
        if args.current_version < v <= remote_ver
    )

    if new_entries:
        changelog_lines = []
        for v, body in new_entries:
            changelog_lines.append("V{0}:".format(v))
            changelog_lines.append(body)
            changelog_lines.append("")
        args.changelog_file.write_text("\n".join(changelog_lines), encoding="utf-8")
        lines.append('set "CHANGELOG_FILE={0}"'.format(args.changelog_file))

    args.result_file.write_text("\n".join(lines) + "\n", encoding="ascii")
    print("[INFO] Remote version: {0}".format(ver))
    if new_entries:
        print("[INFO] {0} new changelog entr{1} found.".format(
            len(new_entries), "y" if len(new_entries) == 1 else "ies"
        ))


if __name__ == "__main__":
    main()
