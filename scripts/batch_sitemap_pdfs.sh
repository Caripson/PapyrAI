#!/usr/bin/env bash
set -euo pipefail

# =========================================
# batch_sitemap_pdfs.sh — Build one PDF per URL in a sitemap.xml
# - Preserves the URL's path structure under the chosen output dir.
# - Uses page <title>/<meta> both for filename (sanitized, underscores for spaces)
#   and for PDF intro (--url-meta).
# - Uses build_proml_pdf.sh for each URL with --url-meta + --url.
# =========================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_SCRIPT="$SCRIPT_DIR/build_proml_pdf.sh"

SITEMAP_INPUT=""
OUTDIR=""
LIMIT=""
BASEURL=""

die() { echo "Error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1; }
normpath() {
  python3 - "$1" <<'PY'
import os,sys
p=sys.argv[1]
print(os.path.abspath(os.path.expanduser(p)))
PY
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0") --sitemap <sitemap.xml|https://...> --outdir <dir> [--limit <n>] [--baseURL <path>]

Options:
  --sitemap <path|url>  Sitemap file or URL (urlset or sitemapindex).
  --outdir <dir>        Where PDFs will be written (directories created as needed).
  --limit <n>           Only process the first N URLs (helpful for testing).
  --baseURL <path>      Base dir passed to build_proml_pdf.sh (defaults to a temp empty dir).
  -h, --help            Show help.
EOF
}

[ "$#" -gt 0 ] || { usage; exit 1; }
while (( "$#" )); do
  case "$1" in
    --sitemap) shift; [ $# -gt 0 ] || die "--sitemap needs a value"; SITEMAP_INPUT="$1";;
    --outdir) shift; [ $# -gt 0 ] || die "--outdir needs a value"; OUTDIR="$1";;
    --limit) shift; [ $# -gt 0 ] || die "--limit needs a value"; LIMIT="$1";;
    --baseURL) shift; [ $# -gt 0 ] || die "--baseURL needs a value"; BASEURL="$1";;
    -h|--help) usage; exit 0;;
    --) shift; break;;
    -* ) die "Unknown option: $1";;
    *  ) die "Unexpected argument: $1";;
  esac
  shift || true
done

[ -n "$SITEMAP_INPUT" ] || die "Missing --sitemap"
[ -n "$OUTDIR" ] || die "Missing --outdir"
need python3 || die "python3 is required"
[ -x "$BUILD_SCRIPT" ] || die "build_proml_pdf.sh not found/executable at $BUILD_SCRIPT"

OUTDIR="$(normpath "$OUTDIR")"
if [ -n "$BASEURL" ]; then
  BASEURL="$(normpath "$BASEURL")"
fi

if [ -n "$LIMIT" ]; then
  [[ "$LIMIT" =~ ^[0-9]+$ ]] || die "--limit must be an integer"
fi

mkdir -p "$OUTDIR"
TMP_ROOT="$(mktemp -d)"
SITEMAP_FILE="$TMP_ROOT/sitemap.xml"

cleanup() {
  rm -rf "$TMP_ROOT"
  if [ -n "${CLEAN_BASE:-}" ] && [ -d "$BASEURL" ]; then rm -rf "$BASEURL"; fi
}
trap cleanup EXIT

if [ -z "$BASEURL" ]; then
  BASEURL="$(mktemp -d)"
  CLEAN_BASE=1
fi

fetch_sitemap() {
  local src="$1"
  case "$src" in
    http://*|https://*)
      need curl || die "--sitemap as URL requires curl"
      curl -fsSL --retry 2 --retry-delay 1 --max-time 30 "$src" -o "$SITEMAP_FILE" \
        || die "Failed to fetch sitemap: $src"
      ;;
    *)
      [ -f "$src" ] || die "Sitemap file not found: $src"
      cp "$src" "$SITEMAP_FILE"
      ;;
  esac
}

fetch_sitemap "$SITEMAP_INPUT"

readarray -t URLS < <(
python3 - "$SITEMAP_FILE" "${LIMIT:-}" <<'PY'
import sys
from urllib.request import urlopen
from urllib.parse import urlparse
import xml.etree.ElementTree as ET

sitemap_path = sys.argv[1]
limit = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None

def fetch_xml(url):
  with urlopen(url, timeout=30) as resp:
    return resp.read()

def parse_urls_from_bytes(data):
  try:
    root = ET.fromstring(data)
  except ET.ParseError:
    return [], None
  tag = root.tag.split('}')[-1].lower()
  urls = []
  if tag == "urlset":
    for loc in root.findall('.//{*}loc'):
      if loc.text and loc.text.strip():
        urls.append(loc.text.strip())
  elif tag == "sitemapindex":
    for loc in root.findall('.//{*}loc'):
      if not (loc.text and loc.text.strip()):
        continue
      try:
        sub_data = fetch_xml(loc.text.strip())
        nested, _ = parse_urls_from_bytes(sub_data)
        urls.extend(nested)
      except Exception as exc:  # best-effort; warn and continue
        print(f"Warning: failed to read nested sitemap {loc.text.strip()}: {exc}", file=sys.stderr)
  return urls, tag

with open(sitemap_path, "rb") as fh:
  data = fh.read()

urls, _ = parse_urls_from_bytes(data)
seen = set()
deduped = []
for u in urls:
  if u not in seen:
    seen.add(u)
    deduped.append(u)

if limit is not None:
  deduped = deduped[:limit]

for u in deduped:
  print(u)
PY
)

[ "${#URLS[@]}" -gt 0 ] || die "No <loc> entries found in sitemap"

derive_rel_dir() {
  local url="$1"
  python3 - "$url" <<'PY'
import sys
from urllib.parse import urlparse, unquote

url = sys.argv[1]
p = urlparse(url)
segments = [s for s in unquote(p.path).split('/') if s not in ("", ".", "..")]

def clean(seg):
  seg = seg.strip()
  if not seg:
    return ""
  out = []
  for ch in seg:
    if ch.isalnum() or ch in "-._":
      out.append(ch)
    else:
      out.append("_")
  cleaned = "".join(out).strip("._")
  while "__" in cleaned:
    cleaned = cleaned.replace("__", "_")
  return cleaned or ""

cleaned = [c for c in (clean(s) for s in segments) if c]
if not cleaned:
  cleaned = [p.netloc or "root"]

print("/".join(cleaned))
PY
}

filename_from_url() {
  local url="$1"
  python3 - "$url" <<'PY'
import sys
from html.parser import HTMLParser
from urllib.parse import urlparse, unquote
from urllib.request import urlopen

url = sys.argv[1]

class MetaParser(HTMLParser):
  def __init__(self):
    super().__init__()
    self.in_title = False
    self.title_parts = []
    self.meta = {}

  def handle_starttag(self, tag, attrs):
    tag = tag.lower()
    if tag == "title":
      self.in_title = True
    if tag == "meta":
      data = {k.lower(): (v or "").strip() for k, v in attrs}
      name = data.get("name") or data.get("property")
      content = data.get("content")
      if name and content and name.lower() not in self.meta:
        self.meta[name.lower()] = content.strip()

  def handle_endtag(self, tag):
    if tag.lower() == "title":
      self.in_title = False

  def handle_data(self, data):
    if self.in_title:
      self.title_parts.append(data)

def sanitize_filename(text, fallback):
  text = (text or "").strip()
  text = "_".join(text.split())  # collapse whitespace to single underscores
  if not text:
    text = fallback
  out = []
  for ch in text:
    if ch.isalnum() or ch in "-._":
      out.append(ch)
    else:
      out.append("_")
  cleaned = "".join(out).strip("._")
  while "__" in cleaned:
    cleaned = cleaned.replace("__", "_")
  return cleaned or fallback or "page"

p = urlparse(url)
slug_candidates = [s for s in unquote(p.path).split("/") if s not in ("", ".", "..")]
fallback_slug = slug_candidates[-1] if slug_candidates else (p.netloc or "page")

raw_title = ""
try:
  with urlopen(url, timeout=30) as resp:
    content = resp.read().decode(resp.headers.get_content_charset() or "utf-8", errors="ignore")
  parser = MetaParser()
  parser.feed(content)
  raw_title = " ".join(parser.title_parts).strip()
  for key in ("og:title", "twitter:title"):
    if not raw_title and key in parser.meta:
      raw_title = parser.meta[key]
except Exception:
  raw_title = ""

safe_name = sanitize_filename(raw_title, sanitize_filename(fallback_slug, "page"))
print(safe_name)
print(raw_title or "")
PY
}

unique_outfile() {
  local dir="$1" base="$2"
  local candidate="$dir/$base.pdf"
  local n=2
  while [ -e "$candidate" ]; do
    candidate="$dir/${base}__${n}.pdf"
    n=$((n+1))
  done
  printf '%s\n' "$candidate"
}

echo "Found ${#URLS[@]} URLs in sitemap"
i=0
for url in "${URLS[@]}"; do
  i=$((i+1))
  rel_dir="$(derive_rel_dir "$url")"
  target_dir="$OUTDIR/$rel_dir"
  mkdir -p "$target_dir"

  mapfile -t meta < <(filename_from_url "$url")
  file_base="${meta[0]}"
  display_title="${meta[1]}"

  outfile="$(unique_outfile "$target_dir" "$file_base")"
  echo "[$i/${#URLS[@]}] $url"
  echo "  -> $outfile"
  [ -n "$display_title" ] && echo "  title: $display_title"

  "$BUILD_SCRIPT" --baseURL "$BASEURL" --ALL --url-meta "$url" --url "$url" "$outfile"
done

echo "✅ Batch complete. Output in: $OUTDIR"
