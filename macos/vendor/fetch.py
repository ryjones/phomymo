#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Download the third-party libraries and web fonts the designer loads from CDNs.

The hosted site (src/web/index.html) pulls these from the network. The macOS
app serves the copies in this directory instead, so it works offline: the
app's scheme handler rewrites each URL listed in manifest.json to the local
file as it serves index.html.

Run this again after index.html changes a library version:

    python3 macos/vendor/fetch.py            # refresh files and manifest.json
    python3 macos/vendor/fetch.py --check    # verify files against manifest.json

Any CDN URL in index.html that this script does not know about is reported,
because the app would still load it from the network.
"""

import hashlib
import json
import re
import sys
import urllib.request
from pathlib import Path

VENDOR = Path(__file__).resolve().parent
INDEX = VENDOR.parent.parent / "src" / "web" / "index.html"
MANIFEST = VENDOR / "manifest.json"

# Google Fonts serves woff2 with per-script unicode-range subsets only to
# browsers it recognises.
BROWSER_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
)

# URL prefix as it appears in index.html -> local file name.
LIBRARIES = {
    "https://cdn.tailwindcss.com": "tailwindcss.js",
    "https://cdn.jsdelivr.net/npm/jsbarcode@": "JsBarcode.all.min.js",
    "https://cdnjs.cloudflare.com/ajax/libs/qrcode/": "qrcode.min.js",
    "https://cdnjs.cloudflare.com/ajax/libs/jspdf/": "jspdf.umd.min.js",
    "https://cdnjs.cloudflare.com/ajax/libs/pdf.js/": None,  # two files; named from the URL
}
FONTS_PREFIX = "https://fonts.googleapis.com/css2?"

# Local file name -> (component, license, npm package, licence file in that package).
# The licence text is fetched for the exact version being vendored and kept in
# LICENSES/, which ships inside the app next to the code it covers.
LIBRARY_LICENSES = {
    "tailwindcss.js": ("Tailwind CSS", "MIT", "tailwindcss", "LICENSE"),
    "JsBarcode.all.min.js": ("JsBarcode", "MIT", "jsbarcode", "MIT-LICENSE.txt"),
    "qrcode.min.js": ("qrcode", "MIT", "qrcode", "license"),
    "jspdf.umd.min.js": ("jsPDF", "MIT", "jspdf", "LICENSE"),
    "pdf.min.mjs": ("PDF.js", "Apache-2.0", "pdfjs-dist", "LICENSE"),
}
NPM_FILE = "https://cdn.jsdelivr.net/npm/{package}@{version}/{file}"
# Every family the site uses is under the SIL Open Font License in google/fonts.
FONT_LICENSE = "https://raw.githubusercontent.com/google/fonts/main/ofl/{directory}/OFL.txt"
CDN_HOSTS = ("cdn.tailwindcss.com", "cdn.jsdelivr.net", "cdnjs.cloudflare.com", "fonts.googleapis.com/css")


def download(url: str) -> bytes:
    return download_resolved(url)[0]


def download_resolved(url: str) -> tuple[bytes, str]:
    """Fetch a URL; also return where it ended up after redirects."""
    request = urllib.request.Request(url, headers={"User-Agent": BROWSER_UA})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read(), response.geturl()


def version_in(url: str) -> str:
    """The x.y.z in a CDN URL (cdn.tailwindcss.com only shows it after its redirect)."""
    match = re.search(r"(?<![\d.])\d+\.\d+\.\d+(?![\d.])", url)
    if not match:
        raise SystemExit(f"cannot tell which version {url} is")
    return match.group(0)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def urls_in_index() -> list[str]:
    html = INDEX.read_text(encoding="utf-8")
    found = re.findall(r"""(?:src|href)=["'](https://[^"']+)["']""", html)
    found += re.findall(r"""['"](https://[^'"]+\.mjs)['"]""", html)
    return list(dict.fromkeys(found))


def local_name(url: str) -> str | None:
    for prefix, name in LIBRARIES.items():
        if url == prefix or (prefix.endswith(("@", "/")) and url.startswith(prefix)):
            return name or url.rsplit("/", 1)[-1]
    return None


def fetch_library_license(name: str, version: str, files: dict[str, bytes], notice: list[str]) -> None:
    if name not in LIBRARY_LICENSES:
        return  # second file of a package already covered (the pdf.js worker)
    component, license_id, package, license_file = LIBRARY_LICENSES[name]
    local = f"LICENSES/{package}-{version}.txt"
    files[local] = download(NPM_FILE.format(package=package, version=version, file=license_file))
    notice.append(f"{component} {version}\n  License: {license_id} ({local})\n"
                  f"  Source:  https://www.npmjs.com/package/{package}/v/{version}\n")


def fetch_font_licenses(css_url: str, files: dict[str, bytes], notice: list[str]) -> None:
    for family in re.findall(r"family=([^:&]+)", css_url):
        name = family.replace("+", " ")
        directory = name.replace(" ", "").lower()
        local = f"LICENSES/font-{directory}-OFL.txt"
        files[local] = download(FONT_LICENSE.format(directory=directory))
        notice.append(f"{name} (web font)\n  License: SIL Open Font License 1.1 ({local})\n"
                      f"  Source:  https://fonts.google.com/specimen/{family}\n")


def fetch_fonts(css_url: str, files: dict[str, bytes]) -> str:
    """Download the stylesheet and every font it names; return the local CSS path."""
    css = download(css_url).decode("utf-8")
    for font_url in dict.fromkeys(re.findall(r"url\((https://fonts\.gstatic\.com/[^)]+)\)", css)):
        data = download(font_url)
        extension = font_url.rsplit(".", 1)[-1]
        name = f"fonts/{sha256(data)[:16]}.{extension}"
        files[name] = data
        # The stylesheet is served from /vendor/, so font paths are relative to it.
        css = css.replace(font_url, name)
        print(f"  {name}  {len(data):>7}  {font_url.rsplit('/', 2)[-2]}")
    files["fonts.css"] = css.encode("utf-8")
    return "fonts.css"


def refresh() -> int:
    files: dict[str, bytes] = {}
    replacements: dict[str, str] = {}
    notice: list[str] = []
    unknown = []

    for url in urls_in_index():
        if url.startswith(FONTS_PREFIX):
            print(f"fonts: {url[:80]}...")
            replacements[url] = "/vendor/" + fetch_fonts(url, files)
            fetch_font_licenses(url, files, notice)
            continue
        name = local_name(url)
        if name is None:
            if any(host in url for host in CDN_HOSTS):
                unknown.append(url)
            continue
        data, final_url = download_resolved(url)
        files[name] = data
        replacements[url] = "/vendor/" + name
        print(f"{name}  {len(data):>8}  {url}")
        fetch_library_license(name, version_in(final_url), files, notice)

    files["LICENSES/NOTICE.txt"] = (
        "Third-party software and fonts bundled with the Phomymo macOS app.\n"
        "Generated by macos/vendor/fetch.py; the full text of each license is in this directory.\n\n"
        + "\n".join(notice)
    ).encode("utf-8")

    # Drop files from an earlier run that are no longer referenced.
    for old in list(VENDOR.glob("*.js")) + list(VENDOR.glob("*.mjs")) + list(VENDOR.glob("*.css")) \
            + list((VENDOR / "fonts").glob("*")) + list((VENDOR / "LICENSES").glob("*")):
        if old.relative_to(VENDOR).as_posix() not in files:
            old.unlink()

    for name, data in files.items():
        path = VENDOR / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    manifest = {
        "replacements": replacements,
        "sha256": {name: sha256(data) for name, data in sorted(files.items())},
    }
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"\n{len(files)} files, {sum(map(len, files.values())) / 1e6:.1f} MB")

    for url in unknown:
        print(f"NOT VENDORED (add to LIBRARIES): {url}", file=sys.stderr)
    return 1 if unknown else 0


def check() -> int:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    failures = 0
    for name, expected in manifest["sha256"].items():
        path = VENDOR / name
        if not path.is_file() or sha256(path.read_bytes()) != expected:
            print(f"MISMATCH {name}", file=sys.stderr)
            failures += 1
    html = INDEX.read_text(encoding="utf-8")
    for url in manifest["replacements"]:
        if url not in html:
            print(f"STALE (index.html no longer references it): {url}", file=sys.stderr)
            failures += 1
    for url in urls_in_index():
        if url not in manifest["replacements"] and any(host in url for host in CDN_HOSTS):
            print(f"NOT VENDORED: {url}", file=sys.stderr)
            failures += 1
    print("ok" if failures == 0 else f"{failures} problem(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(check() if "--check" in sys.argv[1:] else refresh())
