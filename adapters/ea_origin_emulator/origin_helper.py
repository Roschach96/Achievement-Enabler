#!/usr/bin/env python3
"""
Origin Helper workflow, reimplemented in Python.

Replicates:
  1. Parse __Installer/installerdata.xml (name, version, contentID, languages, reg key)
  2. Apply options: use default port / add Content section / add placeholder
     Entitlement / add achievements / has username visible
  3. Scrape isthereanydeal.com product page with BeautifulSoup to find the
     Origin.OFR id under the "EA Store" section
  4. Look up the real display name and achievement-set id for that offer
     via EA's public (unauthenticated) offer-catalog GraphQL query
  5. Write out anadius.cfg in the VDF-like format the emulator expects
"""

import argparse
import re
import shutil
import sys
import time
from pathlib import Path
from xml.etree import ElementTree as ET

import requests
from bs4 import BeautifulSoup


# ---------------------------------------------------------------------------
# Step 1: parse installerdata.xml
# ---------------------------------------------------------------------------

def parse_installer_xml(path):
    tree = ET.parse(path)
    root = tree.getroot()

    content_ids = [e.text for e in root.findall(".//contentIDs/contentID")]
    content_id = content_ids[0] if content_ids else "0"

    name_el = root.find('.//gameTitles/gameTitle[@locale="en_US"]')
    name = name_el.text if name_el is not None else None

    version_el = root.find(".//buildMetaData/gameVersion")
    version = version_el.get("version") if version_el is not None else None

    locales_el = root.find(".//installMetaData/locales")
    languages = None
    if locales_el is not None and locales_el.text:
        langs = sorted(locales_el.text.split(","))
        languages = ",".join(langs)

    # LanguageRegistryKey: pull from the HKEY... \Install Dir] path pattern
    reg_key = None
    raw_xml = ET.tostring(root, encoding="unicode")
    m = re.search(r"\[HKEY[^\\]+\\(.+?\\)Install Dir\]", raw_xml)
    if m:
        reg_key = m.group(1) + "Locale"

    return {
        "content_id": content_id,
        "name": name,
        "version": version,
        "languages": languages,
        "reg_key": reg_key,
    }


# ---------------------------------------------------------------------------
# Step 2: scrape isthereanydeal.com for the Origin.OFR id (BeautifulSoup)
# ---------------------------------------------------------------------------

def slugify_game_name(name):
    """
    Turn the full, unabbreviated game name from installerdata.xml into an
    ITAD-style slug: lowercase, spaces/punctuation -> hyphens.
    e.g. 'GRID Legends' -> 'grid-legends'
    Never shorten/abbreviate the name before slugifying.
    """
    s = name.lower()
    s = s.replace("™", "").replace("®", "")
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = s.strip("-")
    return s


def find_game_slug_via_search(name):
    """
    Fall back to ITAD's search when the naive slugify guess doesn't resolve
    (e.g. name has a colon, subtitle, or ITAD uses a different slug).
    Uses the full, unabbreviated name as the search term.
    """
    url = "https://isthereanydeal.com/search/"
    resp = requests.get(url, params={"q": name}, headers={"User-Agent": "Mozilla/5.0"})
    resp.raise_for_status()
    soup = BeautifulSoup(resp.text, "html.parser")
    for a in soup.select('a[href^="/game/"]'):
        href = a.get("href", "")
        m = re.match(r"^/game/([^/]+)/", href)
        if m:
            return m.group(1)
    return None


def find_products_under_store(soup, store_name):
    """
    Generic ITAD products-page scraper: returns the list of raw text
    labels for every <a class="product"> entry under the <h3> heading
    matching store_name (case-insensitive), e.g. store_name="EA Store"
    or store_name="Steam".

    ITAD's current (Svelte) markup groups each store as:
        <section><h3>Store Name<span class="mark">...</span></h3>
          <a class="product">...</a><a class="product">...</a>...
        </section>
    i.e. the product links are siblings of the <h3>, not wrapped in a
    separate container -- so a plain heading.lower() == store_name match
    needs the trailing "<span class=mark>" text stripped, and sibling
    walking must treat an <a> sibling itself as a candidate link (not
    just look inside it for descendant <a> tags).
    """
    results = []
    for heading in soup.find_all(["h3", "h2"]):
        # The heading's own direct text (excluding the color-swatch <span>)
        # is the store name -- use the first text node rather than
        # get_text(), which would also pull in swatch/markup text.
        heading_text = heading.find(string=True, recursive=True)
        heading_text = heading_text.strip() if heading_text else ""
        if heading_text.lower() != store_name.lower():
            continue

        # Section-scoped search first (covers the current markup, where
        # links are siblings of the heading inside a shared <section>),
        # falling back to sibling-walking for older/alternate layouts.
        container = heading.find_parent("section") or heading.parent
        candidates = container.find_all("a") if container else []
        if not candidates:
            for sib in heading.find_next_siblings():
                if sib.name in ("h2", "h3"):
                    break
                candidates += [sib] if sib.name == "a" else sib.find_all("a")

        for a in candidates:
            results.append(a.get_text(" ", strip=True))
    return results


def fetch_products_page(game_slug):
    url = f"https://isthereanydeal.com/game/{game_slug}/products/"
    resp = requests.get(url, headers={"User-Agent": "Mozilla/5.0"})
    resp.raise_for_status()
    return BeautifulSoup(resp.text, "html.parser")


def find_origin_ofr_ids(game_slug):
    """
    game_slug: ITAD slug, e.g. 'lost-in-random'
    Returns list of (ofr_id, region_label) tuples found under the EA Store
    heading on https://isthereanydeal.com/game/<slug>/products/
    """
    soup = fetch_products_page(game_slug)
    results = []
    for text in find_products_under_store(soup, "EA Store"):
        if "Origin.OFR" in text:
            ofr_id = text.split()[0]
            results.append((ofr_id, text))
    return results


def find_steam_appid(game_slug):
    """
    game_slug: ITAD slug, e.g. 'grid-legends'
    Returns the numeric Steam appid (as a string) from the first
    'app/<id>' entry under the Steam heading, or None if not found.
    e.g. 'app/1307710 GRID Legends AR, AU, ...' -> '1307710'
    """
    soup = fetch_products_page(game_slug)
    for text in find_products_under_store(soup, "Steam"):
        m = re.match(r"^app/(\d+)\b", text)
        if m:
            return m.group(1)
    return None


def pick_best_ofr(ofr_matches, prefer_region="US"):
    """
    Prefer entries whose region list includes prefer_region; among those,
    prefer the one covering the most regions (broadest availability).
    """
    matching = [(oid, label) for oid, label in ofr_matches if prefer_region in label]
    pool = matching or ofr_matches
    if not pool:
        return (None, None)

    def region_count(label):
        # region list is whatever follows the offer id and game name
        parts = label.split(",")
        return len(parts)

    return max(pool, key=lambda pair: region_count(pair[1]))


# ---------------------------------------------------------------------------
# Step 2b: parse SteamDB achievements HTML (pasted in manually, since the
# achievements list is rendered client-side by JS -- a plain requests.get()
# only returns "Loading..." with no data, exactly like the site did when
# fetched here). You still do the browser + F12 + copy(document.documentElement.outerHTML)
# step yourself and paste the result; this function replicates
# parseSteamAchievementsPage() from the userscript on that pasted HTML.
# ---------------------------------------------------------------------------

STEAM_ACH_PREFIX = "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps"


# Invisible/formatting Unicode characters that can end up in scraped DOM
# text (zero-width spaces, byte-order-mark, non-breaking space) but that
# BeautifulSoup's get_text(strip=True) does NOT remove, since it only
# strips ordinary whitespace. Even one achievement id carrying one of
# these silently breaks the numeric-id check below for every entry,
# since it's the SAME check applied uniformly -- so this is cleaned at
# the source, not just worked around in the sort key.
_INVISIBLE_CHARS_RE = re.compile(r"[\u200b\u200c\u200d\u200e\u200f\ufeff\xa0]")


def _clean_scraped_text(s):
    if s is None:
        return s
    return _INVISIBLE_CHARS_RE.sub("", s).strip()


def parse_steam_achievements_html(html):
    soup = BeautifulSoup(html, "html.parser")

    scope = soup.select_one(".scope-app")
    app_id = scope.get("data-appid") if scope else None

    achievements = []
    for el in soup.select(".achievements_list > .achievement"):
        api_el = el.select_one(".achievement_api")
        name_el = el.select_one(".achievement_name")
        if not (api_el and name_el):
            continue
        # The real markup has two <img> tags per achievement: a small
        # checkmark icon (.achievement_image_small) and the actual
        # achievement icon (.achievement_image). Only the latter's
        # data-name is meaningful for building the icon URL.
        img_el = el.select_one(".achievement_image") or el.select_one("img")
        ach_id = _clean_scraped_text(api_el.get_text(strip=True))
        name = _clean_scraped_text(name_el.get_text(strip=True))
        img = img_el.get("data-name") if img_el else None
        icon_url = f"{STEAM_ACH_PREFIX}/{app_id}/{img}" if img else None
        achievements.append({"id": ach_id, "name": name, "icon": icon_url})

    # Natural sort: split each id into runs of digits and non-digits, and
    # compare digit runs numerically. This handles BOTH plain numeric ids
    # ("1".."48") AND real-world prefixed ids like "Achievement_GOSCC_1"
    # (WILD HEARTS' actual raw Steam achievement API names -- confirmed by
    # the userscript's own DEFAULT_PREFIX = "Achievement_GOSCC_" constant).
    # A pure digits-only check misses this entirely: "Achievement_GOSCC_1"
    # isn't all-digits, so it would fall back to plain string comparison
    # and reproduce the exact 1,10,11,...,2,20,... ordering bug.
    _NATSORT_SPLIT_RE = re.compile(r"(\d+)")

    def _natural_sort_key(ach):
        parts = _NATSORT_SPLIT_RE.split(ach["id"])
        # Tag each token (1, int) for digit runs or (0, str) for text runs,
        # rather than a bare mixed list. Comparing two such tuples always
        # compares the tag first, so even if two ids split into different
        # shapes (e.g. one has an extra digit run), Python never ends up
        # comparing an int against a str directly and raising TypeError.
        return [(1, int(p)) if p.isdigit() else (0, p) for p in parts]

    achievements.sort(key=_natural_sort_key)
    return app_id, achievements




def _longest_common_prefix(strings):
    if not strings:
        return ""
    lo, hi = min(strings), max(strings)
    i = 0
    while i < len(lo) and lo[i] == hi[i]:
        i += 1
    return lo[:i]


def compute_steam_prefix(ids):
    """
    Mirror the original userscript's getSteamPrefix() intent: if every Steam
    achievement API name shares a common leading prefix (e.g. "ach01",
    "ach02" -> "ach"), return that prefix so it can be factored out into
    "SteamIdPrefix" and stripped from each achievement key. Returns "" when
    factoring a prefix out would be unsafe (no common prefix, a key would
    become empty, or two keys would collide after stripping) -- in which
    case the achievement ids are written unchanged, exactly as before.
    """
    ids = [str(i) for i in ids]
    if len(ids) < 2:
        return ""

    prefix = _longest_common_prefix(ids)
    if not prefix:
        return ""

    # Never strip so much that any id would be left empty.
    if any(len(i) <= len(prefix) for i in ids):
        shortest = min(len(i) for i in ids)
        prefix = prefix[: shortest - 1] if shortest >= 1 else ""
    if not prefix:
        return ""

    # Suffixes must remain unique once the prefix is removed.
    suffixes = [i[len(prefix):] for i in ids]
    if len(set(suffixes)) != len(suffixes):
        return ""

    return prefix


# ---------------------------------------------------------------------------
# Step 7-9 / 12-13: open the browser to the right page for the user, and
# read/write the clipboard so copying the console command and reading its
# result back doesn't need manual paste-into-terminal.
# ---------------------------------------------------------------------------

import webbrowser


def read_pasted_block(prompt):
    """
    Prompt the user to paste multi-line text (e.g. a whole page's HTML)
    into the console, terminated by a line containing only 'EOF'. Returns
    the joined text (may be empty if they type EOF immediately).
    """
    print(prompt)
    print("(End with a line containing only EOF, or type EOF now to skip.)")
    lines = []
    while True:
        try:
            line = input()
        except EOFError:
            break
        if line.strip() == "EOF":
            break
        lines.append(line)
    return "\n".join(lines)


def _read_clipboard_windows():
    """
    Read clipboard text via the native Windows API (ctypes), which is far
    more reliable than tkinter for large clipboard content written by
    another process (like a browser dumping a whole page's HTML). Returns
    the unicode text, or None if unavailable / empty / not on Windows.
    """
    try:
        import ctypes
        from ctypes import wintypes
    except Exception:
        return None

    try:
        CF_UNICODETEXT = 13
        user32 = ctypes.windll.user32
        kernel32 = ctypes.windll.kernel32

        user32.OpenClipboard.argtypes = [wintypes.HWND]
        user32.OpenClipboard.restype = wintypes.BOOL
        user32.GetClipboardData.argtypes = [wintypes.UINT]
        user32.GetClipboardData.restype = wintypes.HANDLE
        user32.CloseClipboard.restype = wintypes.BOOL
        kernel32.GlobalLock.argtypes = [wintypes.HGLOBAL]
        kernel32.GlobalLock.restype = ctypes.c_void_p
        kernel32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]

        # Retry opening: the clipboard may briefly be locked by the
        # browser right after it wrote to it.
        opened = False
        for _ in range(10):
            if user32.OpenClipboard(None):
                opened = True
                break
            time.sleep(0.05)
        if not opened:
            return None

        try:
            handle = user32.GetClipboardData(CF_UNICODETEXT)
            if not handle:
                return None
            ptr = kernel32.GlobalLock(handle)
            if not ptr:
                return None
            try:
                text = ctypes.c_wchar_p(ptr).value
            finally:
                kernel32.GlobalUnlock(handle)
            return text
        finally:
            user32.CloseClipboard()
    except Exception:
        return None


def read_clipboard():
    """
    Returns clipboard text, or None if it couldn't be read.

    Order of attempts:
      1. Native Windows clipboard API (ctypes) -- most reliable for large
         HTML pasted by a browser; the tkinter path frequently returns
         stale or truncated data for big payloads on Windows.
      2. pyperclip, if installed (cross-platform).
      3. tkinter (bundled with standard Python), as a last resort.
    """
    text = _read_clipboard_windows()
    if text:
        return text

    try:
        import pyperclip
        val = pyperclip.paste()
        if val:
            return val
    except Exception:
        pass

    try:
        import tkinter
        r = tkinter.Tk()
        r.withdraw()
        try:
            text = r.clipboard_get()
        finally:
            r.destroy()
        return text
    except Exception:
        return None


def write_clipboard(text):
    """
    Puts text on the clipboard, returning True on success. Mirrors
    read_clipboard()'s approach: pyperclip first, then a zero-dependency
    tkinter fallback.
    """
    try:
        import pyperclip
        pyperclip.copy(text)
        return True
    except Exception:
        pass

    try:
        import tkinter
        r = tkinter.Tk()
        r.withdraw()
        try:
            r.clipboard_clear()
            r.clipboard_append(text)
            r.update()  # keep the clipboard content after the window is destroyed
        finally:
            r.destroy()
        return True
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Step 3: EA GraphQL calls (require auth) -- stubbed
# ---------------------------------------------------------------------------

GRAPHQL_URL = "https://service-aggregation-layer.juno.ea.com/graphql"

QUERY_OFFER_DETAILS = """
query getLegacyCatalogDefs($offerIds: [String!]!, $locale: Locale) {
  legacyOffers(offerIds: $offerIds, locale: $locale) {
    offerId: id
    contentId
    achievementSetOverride
    displayName
  }
}
"""


def get_game_info_from_ea(offer_ids, ea_app_version=None):
    """
    Calls EA's public offer-catalog GraphQL query (legacyOffers) for the
    given Origin.OFR offer id(s). Mirrors the userscript's getGameInfo(),
    which calls this with needs_auth=false -- this endpoint is public
    catalog metadata, not gated behind a signed-in session, so it works
    even without an access token.

    Returns a list of dicts: [{"offer_id", "content_id", "name",
    "achievements_id"}, ...] for each offer, or an empty list on failure.
    """
    version = ea_app_version or "13.128.0.5641"
    headers = {
        "User-Agent": f"EAApp/PC/{version}",
        "x-client-id": "EAX-JUNO-CLIENT",
        "Accept": "application/json",
        "content-type": "application/json",
    }
    payload = {
        "query": QUERY_OFFER_DETAILS,
        "variables": {"locale": "en", "offerIds": offer_ids},
    }

    try:
        resp = requests.post(GRAPHQL_URL, headers=headers, json=payload, timeout=15)
        data = resp.json().get("data") or {}
    except Exception as e:
        print(f"EA catalog lookup failed: {e}", file=sys.stderr)
        return []

    offers = data.get("legacyOffers") or []
    results = []
    for offer in offers:
        if offer is None:
            continue
        results.append({
            "offer_id": offer.get("offerId"),
            "content_id": offer.get("contentId"),
            "name": offer.get("displayName"),
            "achievements_id": offer.get("achievementSetOverride"),
        })
    return results


# ---------------------------------------------------------------------------
# Step 4: VDF-style config writer -- a direct port of the real userscript's
# own mapToVDF() serializer (see Origin_Helper_user.js), not a heuristic.
# Confirmed from the script's actual source:
#   var mapToVDF = (object, align=8, tab=4, level=0) => { ... }
# Key behaviors this reproduces exactly:
#   - alignment is computed PER BLOCK (per nesting level), not once for the
#     whole file: calculatedAlign = align*tab - level*tab, widened in
#     increments of `tab` only if that block's own widest flat key doesn't
#     fit -- so a long key in one block never shifts unrelated blocks.
#   - a nested block whose rendered contents are empty is omitted entirely
#     (no key line, no braces) -- this is why AchievementTotals /
#     SteamIdOverrides never appear when we have no data for them, exactly
#     matching the real tool's own behavior for an empty achievement map.
# ---------------------------------------------------------------------------

class EmptyLine:
    """Marker for a blank line between entries, matching the JS EmptyLine."""
    pass


def render_vdf(items, align=8, tab=4, level=0):
    """
    items: a list where each element is one of:
      - EmptyLine() (or the class itself)      -> blank line
      - (key, "string value")                   -> flat entry
      - (key, [nested items])                    -> nested block (omitted
                                                     entirely if it renders
                                                     to nothing)
    Returns the rendered text for this block (no trailing braces/key line --
    the caller wraps it), exactly mirroring the real mapToVDF()'s per-call
    contract.
    """
    indent = " " * (level * tab)

    # First pass: widest FLAT key directly in this block (nested-block
    # entries and blank-line markers don't count), matching the JS's
    # maxKeyLength scan.
    max_key_length = -1
    for item in items:
        if item is None or item is EmptyLine or isinstance(item, EmptyLine):
            continue
        key, value = item
        if isinstance(value, list):
            continue
        if len(key) > max_key_length:
            max_key_length = len(key)

    calculated_align = align * tab - len(indent)
    if max_key_length != -1:
        while calculated_align - (max_key_length + 2) < 1:
            calculated_align += tab

    out = []
    for item in items:
        if item is None or item is EmptyLine or isinstance(item, EmptyLine):
            out.append("\n")
            continue

        key, value = item
        if isinstance(value, list):
            section = render_vdf(value, align, tab, level + 1)
            if len(section) > 0:
                out.append(f'{indent}"{key}"\n{indent}{{\n{section}{indent}}}\n')
            continue

        spacing_repeat = calculated_align - (len(key) + 2)
        if spacing_repeat < 1:
            spacing_repeat = 1
        spacing = " " * spacing_repeat
        out.append(f'{indent}"{key}"{spacing}"{value}"\n')

    result = "".join(out)
    result = re.sub(r"^\n+", "", result)
    result = re.sub(r"\n{2,}$", "\n", result)
    result = re.sub(r"\n{3,}", "\n\n", result)
    return result


def build_vdf_document(root_items):
    """Top-level entry point, matching the real tool's mapToVDF(config)
    call where config is a Map with the single entry "Config2" -> the
    rest of the tree."""
    return render_vdf([("Config2", root_items)])



def build_achievements_kv(options):
    """
    Builds the achievements_kv list (AchievementsSet / AchievementNames /
    SteamAppId / SteamIdPrefix) from options -- pulled out of build_config()
    so it can also be used on its own when patching just the Achievements
    block of an already-existing anadius.cfg, without rebuilding every
    other section.
    """
    achievements_kv = []
    if options.get("add_achievements"):
        ea_offer_info = options.get("ea_offer_info")
        real_achievements_id = ea_offer_info.get("achievements_id") if ea_offer_info else None
        achievements_set_value = real_achievements_id or "PASTE_ACHIEVEMENT_SET_ID_HERE"

        steam_achievements = options.get("steam_achievements")
        if steam_achievements:
            app_id, achievements = steam_achievements
            achievements_kv.append(("AchievementsSet", achievements_set_value))

            # The real Origin Helper always nests achievement id->name pairs
            # under a separate "AchievementNames" block (see mapToVDF /
            # achievementsSection.set("AchievementNames", ...) in the
            # userscript) -- never flat under Achievements directly. We
            # mirror that structure even though our names come from
            # SteamDB rather than EA's own (authenticated) achievements
            # API, since we have no way to fetch that without a live
            # session tied to this specific achievement set.
            #
            # If every Steam achievement id shares a common leading prefix
            # (e.g. "ach01", "ach02"), factor it out into SteamIdPrefix and
            # store the stripped suffix as each key. When there's no safe
            # common prefix (e.g. GRID's plain numeric ids), prefix is ""
            # and the ids are written unchanged.
            prefix = compute_steam_prefix([ach["id"] for ach in achievements])
            names_kv = []
            for ach in achievements:
                key = ach["id"][len(prefix):] if prefix else ach["id"]
                names_kv.append((key, ach["name"]))
            achievements_kv.append(("AchievementNames", names_kv))

            # AchievementTotals (per-achievement progress totals) and
            # SteamIdOverrides (id pairs that don't fit prefix+id) both
            # require data we don't have -- EA's own authenticated
            # achievement totals, and a true EA<->Steam id pairing,
            # respectively. Passing an empty list here matches the real
            # tool's own behavior for an empty map: render_vdf omits an
            # empty nested block entirely, so nothing is written.

            if app_id:
                achievements_kv.append(("SteamAppId", app_id))
            if prefix:
                achievements_kv.append(("SteamIdPrefix", prefix))
        else:
            achievements_kv.append(("AchievementsSet", achievements_set_value))

    return achievements_kv


def insert_achievements_block(existing_text, achievements_kv):
    """
    Given the raw text of an already-existing anadius.cfg that has NO
    "Achievements" block at all (a hand-made cfg, or one from a different
    tool that never included one), inserts a freshly-rendered block just
    before the file's own final closing brace ("Config2"'s own) -- leaving
    every other section completely untouched, same as
    replace_achievements_block does when a block already exists.

    Returns the modified text, or None if the file doesn't even have a
    recognizable final closing brace (caller should fall back to a full
    rewrite only in that unlikely case).
    """
    stripped = existing_text.rstrip()
    if not stripped.endswith("}"):
        return None

    # The LAST "}" in the file is Config2's own closing brace (anadius.cfg
    # is always a single top-level "Config2" { ... } block) -- insert right
    # before it, matching the same blank-line separation used between every
    # other top-level section.
    last_brace_idx = len(stripped) - 1
    before = stripped[:last_brace_idx].rstrip("\n").rstrip()
    new_block = render_vdf([("Achievements", achievements_kv)], level=1).rstrip("\n")

    return before + "\n\n" + new_block + "\n}\n"


def replace_achievements_block(existing_text, achievements_kv):
    """
    Given the raw text of an already-existing anadius.cfg and a freshly
    built achievements_kv list, replaces ONLY the "Achievements" block in
    that text (from its "Achievements" line through its own matching
    closing brace) with a newly-rendered version -- leaving every other
    section (Game, Emulator, User, Content, Entitlements) completely
    untouched, including any manual edits the user has made to them (a
    real DenuvoToken, custom Entitlements entries, etc.).

    Returns the spliced text, or None if the existing file doesn't have a
    recognizable "Achievements" block to replace (caller should fall back
    to a full rewrite in that case).
    """
    # Match "Achievements" on its own line regardless of indentation style -
    # a literal 4-space marker would miss a tab-indented file (real anadius
    # configs aren't always space-indented), causing a false "not found"
    # that led insert_achievements_block() to append a SECOND Achievements
    # block instead of replacing the real one.
    marker_match = re.search(r'(?m)^[ \t]*"Achievements"[ \t]*$', existing_text)
    if not marker_match:
        return None
    start_idx = marker_match.start()

    brace_open_idx = existing_text.find("{", start_idx)
    if brace_open_idx == -1:
        return None

    depth = 0
    end_idx = None
    for i in range(brace_open_idx, len(existing_text)):
        c = existing_text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                end_idx = i
                break
    if end_idx is None:
        return None

    new_block = render_vdf([("Achievements", achievements_kv)], level=1).rstrip("\n")
    return existing_text[:start_idx] + new_block + existing_text[end_idx + 1:]


def build_config(xml_info, options, ofr_id=None):
    game_kv = [
        ("Name", xml_info["name"]),
        ("Version", xml_info["version"]),
        None,
        ("ContentId", xml_info["content_id"]),
    ]
    if options.get("has_denuvo_dll"):
        game_kv += [
            None,
            ("DenuvoToken", "PASTE_A_VALID_DENUVO_TOKEN_HERE"),
            ("DenuvoExeHash", "DENUVO_EXE_HASH"),
            ("DenuvoDllHash", "DENUVO_DLL_HASH"),
        ]
    if xml_info["languages"]:
        game_kv += [None, ("Languages", xml_info["languages"]), ("Language", "en_US")]
        if xml_info["reg_key"]:
            game_kv.append(("LanguageRegistryKey", xml_info["reg_key"]))

    emulator_kv = []
    if options.get("use_default_port"):
        emulator_kv.append(("ServerPort", "default"))

    user_kv = []
    if options.get("has_username"):
        real_user = options.get("real_user")
        if real_user:
            user_kv += [
                ("Username", real_user["username"]),
                ("PersonaId", real_user["persona_id"]),
                ("UserId", real_user["user_id"]),
            ]
        else:
            # placeholder demo values from the original script
            user_kv += [
                ("Username", "anadius"),
                ("PersonaId", "1144668899"),
                ("UserId", "1000200030000"),
            ]

    content_kv = []
    if options.get("add_content_section") and ofr_id:
        ea_offer_info = options.get("ea_offer_info")
        real_name = ea_offer_info.get("name") if ea_offer_info else None
        content_kv.append((ofr_id, [
            ("Name", real_name or xml_info["name"]),
            ("Version", xml_info["version"]),
            ("State", "INSTALLED"),
        ]))

    entitlements_kv = []
    if options.get("add_entitlement"):
        entitlements_kv.append(("PUT_ORIGIN_DLC_ID_HERE", [
            ("Group", "GAME_GROUP_NAME"),
            ("Version", "0"),
            ("Type", "DEFAULT"),
            ("EntitlementTag", "THIS_IS_WHAT_MAKES_THE_DLCS_WORK"),
        ]))

    achievements_kv = build_achievements_kv(options)

    return build_vdf_document([
        None,
        ("Game", game_kv),
        None,
        ("Emulator", emulator_kv),
        None,
        ("User", user_kv),
        None,
        ("Content", content_kv),
        None,
        ("Entitlements", entitlements_kv),
        None,
        ("Achievements", achievements_kv),
    ])


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("xml_path", nargs="?", default=None, help="Path to installerdata.xml")
    ap.add_argument("--itad-slug", default=None, help="Override: isthereanydeal.com game slug (default: derived from the XML's game name)")
    ap.add_argument("--region", default="US", help="Preferred region to match in the OFR listing")
    ap.add_argument("--out", default="anadius.cfg")

    ap.add_argument("--use-default-port", action="store_true", default=True)
    ap.add_argument("--add-content-section", action="store_true", default=True)
    ap.add_argument("--add-entitlement", action="store_true", default=True)
    ap.add_argument("--add-achievements", action="store_true", default=True)
    ap.add_argument("--has-username", action="store_true", default=False)

    ap.add_argument(
        "--interactive-achievements",
        action="store_true",
        help="Prompt to paste SteamDB achievements page HTML (from browser console)",
    )
    ap.add_argument(
        "--no-prompt",
        action="store_true",
        help="Disable interactive prompts (for scripted/CI use); requires xml_path and --itad-slug",
    )

    args = ap.parse_args()
    interactive = not args.no_prompt

    # The User section always uses this placeholder profile -- nothing in
    # anadius.cfg needs a live EA session: the Content name / AchievementsSet
    # come from EA's public catalog endpoint, and these three values are the
    # only thing a live session would otherwise be used to look up.
    FAKE_USER = {
        "username": "anadius",
        "persona_id": "1144668899",
        "user_id": "1000200030000",
    }


    # --- xml path: from arg, or auto-detect near the script, or ask ---
    xml_path = args.xml_path
    if xml_path is None and interactive:
        script_dir = Path(__file__).resolve().parent
        candidates = list(script_dir.glob("**/installerdata.xml"))
        if len(candidates) == 1:
            xml_path = str(candidates[0])
            print(f"Found installerdata.xml: {xml_path}")
        elif len(candidates) > 1:
            print("Multiple installerdata.xml found:")
            for i, c in enumerate(candidates, 1):
                print(f"  {i}. {c}")
            choice = input("Pick a number: ").strip()
            xml_path = str(candidates[int(choice) - 1])
        else:
            xml_path = input("Path to __Installer\\installerdata.xml: ").strip().strip('"')
    if not xml_path:
        raise SystemExit("No installerdata.xml path given.")

    xml_info = parse_installer_xml(xml_path)
    print(f"\nParsed: {xml_info['name']}  v{xml_info['version']}  (ContentId {xml_info['content_id']})")

    # --- ITAD slug: always derive from the full, unabbreviated game name
    # in installerdata.xml first. Only fall back to search or manual entry
    # if that guess doesn't resolve to a real ITAD page.
    itad_slug = args.itad_slug
    ofr_matches = []
    if itad_slug is None and xml_info["name"]:
        guess = slugify_game_name(xml_info["name"])
        print(f"Using game name from XML: '{xml_info['name']}' -> ITAD slug guess '{guess}'")
        try:
            ofr_matches = find_origin_ofr_ids(guess)
            if ofr_matches:
                itad_slug = guess
        except Exception as e:
            print(f"Warning: slug guess '{guess}' failed ({e}).", file=sys.stderr)

        if not ofr_matches:
            print(f"Slug guess didn't resolve; searching ITAD for '{xml_info['name']}'...")
            try:
                found_slug = find_game_slug_via_search(xml_info["name"])
                if found_slug:
                    print(f"Found ITAD slug via search: {found_slug}")
                    itad_slug = found_slug
                    ofr_matches = find_origin_ofr_ids(found_slug)
            except Exception as e:
                print(f"Warning: ITAD search failed ({e}).", file=sys.stderr)

    if itad_slug is None and interactive:
        itad_slug = input(
            "isthereanydeal.com game slug (from the URL, e.g. 'lost-in-random'): "
        ).strip()
        try:
            ofr_matches = find_origin_ofr_ids(itad_slug)
        except Exception as e:
            print(f"Warning: could not fetch ITAD page ({e}).", file=sys.stderr)

    if not itad_slug:
        raise SystemExit("No ITAD slug available (XML has no name, and none given).")

    ofr_id = None
    if not ofr_matches:
        print("No Origin.OFR id found on ITAD page.", file=sys.stderr)
    else:
        ofr_id, label = pick_best_ofr(ofr_matches, args.region)
        print(f"Picked {ofr_id}  ({label})")

    if not ofr_id and interactive:
        ofr_id = input("Paste the Origin.OFR id manually: ").strip()

    options = {
        "use_default_port": args.use_default_port,
        "add_content_section": args.add_content_section,
        "add_entitlement": args.add_entitlement,
        "add_achievements": args.add_achievements,
        "has_username": args.has_username,
    }

    if (options["add_content_section"] or options["add_achievements"]) and ofr_id:
        print("Looking up EA catalog info for this offer...")
        try:
            ea_offers = get_game_info_from_ea([ofr_id])
        except Exception as e:
            ea_offers = []
            print(f"Warning: EA catalog lookup failed ({e}).", file=sys.stderr)

        matching_offer = None
        for offer in ea_offers:
            if offer.get("content_id") == xml_info["content_id"]:
                matching_offer = offer
                break
        if matching_offer is None and ea_offers:
            matching_offer = ea_offers[0]

        if matching_offer:
            options["ea_offer_info"] = matching_offer
            print(f"Got catalog info: name={matching_offer.get('name')!r}, "
                  f"achievements_id={matching_offer.get('achievements_id')!r}")
        else:
            print("No catalog info returned for this offer -- using placeholders.")

    do_ach = args.interactive_achievements or (interactive and not args.no_prompt)

    # steam_appid is populated inside the achievements step below (via ITAD),
    # but initialized here unconditionally so it's always defined -- e.g. for
    # writing the metadata file near the end of main(), even on a run where
    # the achievements step itself is skipped entirely.
    steam_appid = None

    # User section always uses the placeholder anadius profile -- no
    # get_token, no EA App requirement, no prompt.
    options["has_username"] = True
    options["real_user"] = dict(FAKE_USER)

    # Step 7-9 / 12-13: SteamDB achievements. Derive the Steam appid from
    # ITAD's Steam listing, open the SteamDB achievements page directly,
    # then have the user copy the page HTML and paste it in here.
    if do_ach and options["add_achievements"]:
        print("\n--- Step: SteamDB achievements ---")
        steam_appid = None
        try:
            steam_appid = find_steam_appid(itad_slug)
        except Exception as e:
            print(f"Warning: could not look up Steam appid on ITAD ({e}).", file=sys.stderr)

        if not steam_appid and interactive:
            steam_appid = input(
                "Steam appid (from steamdb.info/app/<id>/stats/), or press Enter to skip: "
            ).strip() or None

        html = None
        if steam_appid:
            steamdb_url = f"https://steamdb.info/app/{steam_appid}/stats/"
            js_snippet = "copy(document.documentElement.outerHTML)"
            copied = write_clipboard(js_snippet)

            print(f"Opening {steamdb_url}")
            print("\nOn that page:")
            print("  1. Press F12, open the Console tab.")
            if copied:
                print(f"  2. Paste (Ctrl+V) -- the command is already on your clipboard: {js_snippet}")
            else:
                print(f"  2. Type or paste this command: {js_snippet}")
            print("  3. Press Enter to run it (this copies the whole page to your clipboard).")
            print("     (If the console shows a paste warning, type  allow pasting  first,")
            print("      press Enter, then paste the command again and press Enter.)")
            webbrowser.open(steamdb_url)

            if interactive:
                max_retries = 3
                attempt = 0
                while True:
                    attempt += 1
                    prompt = "\nOnce the command has run (the SteamDB tab becomes responsive again), come back here and press Enter..."
                    if attempt >= max_retries:
                        prompt = (
                            "\nOnce the command has run (the SteamDB tab becomes responsive again), "
                            "come back here and press Enter..."
                        )
                    input(prompt)
                    html = read_clipboard()

                    # If the clipboard still holds the command itself, it
                    # hasn't run yet -- offer to try again rather than
                    # parsing the snippet (which yields 0 achievements).
                    if html and html.strip() == js_snippet:
                        print("The clipboard still contains the command, not the page HTML --")
                        print("it looks like the command hasn't run yet.")
                        if attempt >= max_retries:
                            print("Max retry attempts reached -- switching to manual paste.")
                            html = read_pasted_block(
                                "\nPaste the copied page HTML here, then press Enter:"
                            )
                            break
                        again = input("Try again? (Enter = retry / n = paste manually): ").strip().lower()
                        if again == "n":
                            html = read_pasted_block(
                                "\nPaste the copied page HTML here, then press Enter:"
                            )
                            break
                        continue

                    if html and html.strip():
                        preview = html.strip().replace("\n", " ")[:60]
                        print(f"Read {len(html)} chars from clipboard: {preview!r}")
                        break

                    # Empty / unreadable clipboard -> manual paste fallback.
                    print("Couldn't read the page HTML from the clipboard.")
                    html = read_pasted_block(
                        "\nPaste the copied page HTML here, then press Enter:"
                    )
                    break
        elif interactive:
            print("(Skipping -- no Steam appid available.)")

        if html and html.strip():
            app_id, achievements = parse_steam_achievements_html(html)
            print(f"Parsed {len(achievements)} achievements (appid {app_id}).")
            options["steam_achievements"] = (app_id, achievements)

    # Game root folder (one level up from __Installer\installerdata.xml,
    # since that's where anadius.cfg itself belongs -- __Installer is often
    # locked down / needs admin rights to write to). Computed here (rather
    # than only later, at write time) so the dbdata.dll search below can use
    # it before build_config() runs.
    xml_dir = Path(xml_path).resolve().parent
    default_dir = xml_dir.parent if xml_dir.name.lower() == "__installer" else xml_dir

    # DenuvoToken/DenuvoExeHash/DenuvoDllHash only make sense for a
    # Denuvo-protected game -- detected here by whether dbdata.dll exists
    # anywhere under the game root. If it doesn't, all three are omitted
    # from the Achievements... er, Game section entirely, rather than
    # writing placeholder lines nobody will ever fill in.
    options["has_denuvo_dll"] = any(default_dir.rglob("dbdata.dll"))
    if options["has_denuvo_dll"]:
        print("Found dbdata.dll under the game folder -- including Denuvo placeholder fields.")
    else:
        print("No dbdata.dll found under the game folder -- skipping Denuvo fields entirely.")

    cfg_text = build_config(xml_info, options, ofr_id=ofr_id)

    out_path = Path(args.out)
    if not out_path.is_absolute():
        out_path = default_dir / out_path

    # If anadius.cfg already exists at the target location, only patch its
    # Achievements block in place -- leaving Game/Emulator/User/Content/
    # Entitlements exactly as they are, including any manual edits (a real
    # DenuvoToken filled in, custom Entitlements entries, etc.) that a full
    # rewrite would otherwise silently discard. Falls back to a full
    # rewrite if the existing file doesn't have a recognizable Achievements
    # block to splice into.
    if out_path.exists():
        bak_path = out_path.with_name(out_path.name + ".BAK")
        try:
            # Rename first (not copy) so .BAK keeps the true original's own
            # modification date -- a rename doesn't touch file metadata,
            # whereas copying the original to .BAK would give the backup a
            # fresh "just copied" timestamp instead of preserving when it
            # was actually last changed. Then copy .BAK back to out_path so
            # there's something at the real anadius.cfg path to read/patch.
            out_path.rename(bak_path)
            shutil.copyfile(bak_path, out_path)
            print(f"Backed up existing {out_path.name} to {bak_path.name} (preserving its modification date) before modifying it.")
        except OSError as e:
            print(f"Warning: could not back up existing {out_path} to .BAK ({e}) -- continuing anyway.")

        try:
            existing_text = out_path.read_text(encoding="utf-8")
        except OSError as e:
            existing_text = None
            print(f"Warning: could not read existing {out_path} ({e}) -- writing a full new file instead.")

        if existing_text is not None:
            achievements_kv = build_achievements_kv(options)
            patched = replace_achievements_block(existing_text, achievements_kv)
            if patched is not None:
                cfg_text = patched
                print(f"Existing {out_path.name} found -- only its Achievements block will be updated.")
            else:
                patched = insert_achievements_block(existing_text, achievements_kv)
                if patched is not None:
                    cfg_text = patched
                    print(f"Existing {out_path.name} has no Achievements block -- adding one, everything else left as-is.")
                else:
                    print(f"Existing {out_path.name} isn't a recognizable anadius.cfg -- writing a full new file instead.")

    # Try the intended location first; if it's not writable (permissions,
    # locked folder, etc.), fall back to next to this script instead of
    # crashing -- the file is still produced, just somewhere reachable.
    write_targets = [out_path]
    script_dir_fallback = Path(__file__).resolve().parent / out_path.name
    if script_dir_fallback != out_path:
        write_targets.append(script_dir_fallback)

    written_to = None
    last_error = None
    for target in write_targets:
        try:
            with open(target, "w", encoding="utf-8", newline="\r\n") as f:
                f.write(cfg_text)
            written_to = target
            break
        except OSError as e:
            last_error = e
            print(f"Couldn't write to {target} ({e}).", file=sys.stderr)

    if written_to is None:
        print(f"\nFailed to write {out_path.name} anywhere. Last error: {last_error}", file=sys.stderr)
        if interactive:
            manual_path = input("Enter a folder to save it to instead (or press Enter to give up): ").strip().strip('"')
            if manual_path:
                target = Path(manual_path) / out_path.name
                try:
                    with open(target, "w", encoding="utf-8", newline="\r\n") as f:
                        f.write(cfg_text)
                    written_to = target
                except OSError as e:
                    print(f"Still couldn't write there either ({e}). Giving up.", file=sys.stderr)

    if written_to:
        print(f"\nWrote {written_to}")
    else:
        raise SystemExit("Could not save anadius.cfg anywhere writable.")

    # Small metadata file alongside anadius.cfg, purely for downstream
    # consumers that don't want to re-derive these values themselves --
    # e.g. an orchestrator wiring this script into a larger pipeline. Not
    # read back by this script itself, and never required for anadius.cfg
    # generation to work; if this write fails for any reason, it's silently
    # skipped rather than treated as an error.
    try:
        meta_lines = [
            f"steam_appid={steam_appid or ''}",
            f"content_id={xml_info.get('content_id') or ''}",
            f"display_name={options.get('ea_offer_info', {}).get('name') or xml_info.get('name') or ''}",
        ]
        meta_path = written_to.parent / "_origin_helper_meta.txt"
        with open(meta_path, "w", encoding="utf-8") as f:
            f.write("\n".join(meta_lines) + "\n")
    except Exception:
        pass


if __name__ == "__main__":
    try:
        main()
    except SystemExit as e:
        if e.code not in (None, 0):
            print(f"\nError: {e.code}")
    except Exception:
        import traceback
        traceback.print_exc()
    finally:
        if sys.stdin.isatty() or "idlelib" not in sys.modules:
            try:
                input("\nPress Enter to exit...")
            except EOFError:
                pass
