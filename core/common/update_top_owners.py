import argparse
import asyncio
import importlib.util
import subprocess
import sys
from pathlib import Path


URL = "https://steamladder.com/ladder/games/"
DEFAULT_TXT_OUTPUT = Path("top_owners_ids.txt")
HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/123.0.0.0 Safari/537.36"
    )
}
REQUIRED_PACKAGES = {
    "bs4": "beautifulsoup4",
    "playwright": "playwright",
}


def install_package(package_name):
    print(f"[SETUP] Installing missing package: {package_name}")
    subprocess.check_call([sys.executable, "-m", "pip", "install", package_name])


def ensure_python_packages():
    for module_name, package_name in REQUIRED_PACKAGES.items():
        if importlib.util.find_spec(module_name) is None:
            install_package(package_name)


def clean_stale_playwright_browsers():
    import re
    import shutil
    try:
        result = subprocess.run(
            [sys.executable, "-m", "playwright", "install", "--dry-run"],
            capture_output=True, text=True
        )
        match = re.search(r'chromium v(\d+)', result.stdout)
        if not match:
            return
        expected = match.group(1)
        browser_path = Path.home() / "AppData" / "Local" / "ms-playwright"
        for folder in browser_path.glob("chromium*"):
            revision = folder.name.split("-")[1]
            if revision != expected:
                print(f"[SETUP] Removing stale Chromium revision {revision} (expected {expected})...")
                shutil.rmtree(folder, ignore_errors=True)
    except Exception:
        pass


def ensure_playwright_browser():
    print("[SETUP] Verifying Playwright Chromium browser...")
    subprocess.check_call([sys.executable, "-m", "playwright", "install", "chromium"])


ensure_python_packages()
clean_stale_playwright_browsers()
ensure_playwright_browser()

from bs4 import BeautifulSoup
from playwright.async_api import async_playwright


def scrape_steam_ids(limit):
    html = asyncio.run(scrape_steam_ids_with_playwright())

    soup = BeautifulSoup(html, "html.parser")

    steam_ids = []
    for link in soup.select('a[href^="/profile/"]'):
        href = link.get("href", "")
        digits = "".join(ch for ch in href if ch.isdigit())
        if len(digits) != 17:
            continue
        if digits in steam_ids:
            continue

        steam_ids.append(digits)
        if len(steam_ids) >= limit:
            break

    return steam_ids


async def scrape_steam_ids_with_playwright():
    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=[
                "--disable-blink-features=AutomationControlled",
                "--no-sandbox",
                "--disable-dev-shm-usage",
            ],
        )
        context = await browser.new_context(
            user_agent=HEADERS["User-Agent"],
            viewport={"width": 1280, "height": 800},
        )
        page = await context.new_page()
        try:
            response = await page.goto(URL, wait_until="domcontentloaded", timeout=30000)
            if response is None:
                raise RuntimeError("No response received (possible network block or browser crash)")
            if response.status >= 400:
                raise RuntimeError(f"SteamLadder returned HTTP {response.status}")

            try:
                await page.wait_for_selector('a[href^="/profile/"]', timeout=15000)
            except Exception:
                pass  # scrape whatever loaded
            return await page.content()
        finally:
            await browser.close()


def write_txt(output_path, steam_ids):
    output_path.write_text("\n".join(steam_ids) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(
        description="Scrape top Steam profile IDs from steamladder.com into a text file."
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=250,
        help="How many unique Steam IDs to save (default: 250).",
    )
    parser.add_argument(
        "--txt-output",
        type=Path,
        default=DEFAULT_TXT_OUTPUT,
        help="Path for the text file with one Steam ID per line.",
    )
    args = parser.parse_args()

    print(f"Updating Steam IDs from steamladder.com (limit: {args.limit})...")

    try:
        steam_ids = scrape_steam_ids(args.limit)

        if len(steam_ids) < 10:
            print(f"[ERROR] Not enough Steam IDs found ({len(steam_ids)})")
            return 1

        write_txt(args.txt_output, steam_ids)
        print(f"[OK] Wrote {len(steam_ids)} Steam IDs to {args.txt_output}")
        return 0
    except Exception as e:
        print(f"[ERROR] Failed to update Steam IDs: {e}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
