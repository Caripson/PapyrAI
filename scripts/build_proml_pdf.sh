#!/usr/bin/env bash
set -euo pipefail

# =========================================
# build_proml_pdf.sh  — Build a single PDF from Markdown
#
# Order:
#   0) Optional intro text (--intro)
#   1) Optional URL metadata intro (--url-meta)
#   2) Optional scraped URL content (--url)
#   3) README.md (root, case-insensitive)
#   4) docs/**/*.md (recursive, sorted)
#   5) root-level *.md (excluding README)
#   6) remaining folders recursively (*.md), deduped
#   7) Optional credits (--credits)
#
# Features:
# - Feed Pandoc each file separately with page breaks -> preserves relative image paths.
# - Tectonic snap workaround: md -> LaTeX written in repo-root, then tectonic to cache OUTDIR.
# - Strip badges & emojis by default (configurable).
# - Images verified by Lua filter: keep only if resolvable locally; else replace with alt text (or drop).
# - Optional intro text, URL metadata intro, scraped web content, and credits sections.
# - --no-images / NO_IMAGES=1 to remove all images.
# - Code blocks wrap lines, long URLs break; smaller monospace.
# - Syntax highlighting theme via HL_STYLE (or custom .theme).
#
# Usage:
#   ./scripts/build_proml_pdf.sh --baseURL <path> --ALL [--intro "<text>"] [--url-meta <https://...>] [--url <https://...>] [--credits "<text>"] [--exclude <glob> ...] [--no-images] <outfile.pdf>
#
# Env:
#   HL_STYLE=breezeDark|tango|pygments|/path/to/custom.theme
#   KEEP_BADGES=1   keep badges
#   KEEP_EMOJI=1    keep emojis
#   NO_IMAGES=1     remove all images
# =========================================

# ---- Defaults / Params ----
BASEURL=""
DO_ALL=false
declare -a EXCLUDES=()
OUTFILE=""
NO_IMAGES=false
INTRO_TEXT=""
URL_INPUT=""
URL_META_INPUT=""
CREDITS_TEXT=""

# ---- Config ----
HL_STYLE="${HL_STYLE:-breezeDark}"

# ---- Helpers ----
need() { command -v "$1" >/dev/null 2>&1; }
die() { echo "Error: $*" >&2; exit 1; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
normpath() {
  python3 - "$1" <<'PY'
import os,sys
p=sys.argv[1]
print(os.path.abspath(os.path.expanduser(p)))
PY
}

# returns 0 (true) if BASENAME matches any exclude pattern (case-insensitive glob)
is_excluded() {
  local base="$1"
  local lbase; lbase="$(lower "$base")"
  local pat raw lp
  for pat in "${EXCLUDES[@]}"; do
    IFS=',' read -ra parts <<< "$pat"
    for raw in "${parts[@]}"; do
      lp="$(lower "$(echo "$raw" | xargs)")"
      shopt -s nocasematch
      if [[ "$lbase" == $lp ]]; then
        shopt -u nocasematch
        return 0
      fi
      shopt -u nocasematch
    done
  done
  return 1
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0") --baseURL <path> --ALL [--intro "<text>"] [--url-meta <https://...>] [--url <https://...>] [--credits "<text>"] [--exclude <name|glob> ...] [--no-images] <outfile.pdf>

Options:
  --baseURL <path>     Repository root. If omitted -> 'git rev-parse' or cwd.
  --ALL                README -> docs/** -> root-*.md -> rest (recursive).
  --exclude <pattern>  Case-insensitive glob on basename. Repeat or comma-separate.
  --no-images          Drop all images (same as NO_IMAGES=1).
  --intro "<text>"     Prepend an intro section.
  --url-meta <https://...>
                        Fetch <title>/<meta> from a page and prepend as intro.
  --url <https://...>  Fetch a web page and include its content (HTML -> Markdown).
  --credits "<text>"   Append a credits section.
  -h, --help           Show help.

Env:
  HL_STYLE=<pandoc-theme|/path/to/theme> (default: ${HL_STYLE})
  KEEP_BADGES=1   keep badges
  KEEP_EMOJI=1    keep emojis (else stripped for LaTeX glyphs)
  NO_IMAGES=1     drop all images
EOF
}

# ---- Parse args ----
if [ "$#" -eq 0 ]; then usage; exit 1; fi
while (( "$#" )); do
  case "$1" in
    --baseURL) shift; [ $# -gt 0 ] || die "--baseURL needs a value"; BASEURL="$(normpath "$1")";;
    --ALL) DO_ALL=true;;
    --exclude) shift; [ $# -gt 0 ] || die "--exclude needs a value"; EXCLUDES+=("$1");;
    --no-images) NO_IMAGES=true;;
    --intro) shift; [ $# -gt 0 ] || die "--intro needs a value"; INTRO_TEXT="$1";;
    --url-meta) shift; [ $# -gt 0 ] || die "--url-meta needs a value"; URL_META_INPUT="$1";;
    --url) shift; [ $# -gt 0 ] || die "--url needs a value"; URL_INPUT="$1";;
    --credits) shift; [ $# -gt 0 ] || die "--credits needs a value"; CREDITS_TEXT="$1";;
    -h|--help) usage; exit 0;;
    --) shift; break;;
    -* ) die "Unknown option: $1";;
    *  )
      if [ -z "$OUTFILE" ]; then OUTFILE="$1"; else die "Unexpected extra argument: $1"; fi
      ;;
  esac
  shift || true
done
if [ "${NO_IMAGES:-false}" = false ] && [ "${NO_IMAGES:-0}" = "1" ]; then NO_IMAGES=true; fi

[ -n "${OUTFILE}" ] || die "Missing output filename (e.g., myfile.pdf)."
[[ "$(lower "$OUTFILE")" == *.pdf ]] || die "Output must end with .pdf"

# ---- Locate repo root ----
if [ -z "$BASEURL" ]; then
  if need git && git rev-parse --show-toplevel >/dev/null 2>&1; then
    BASEURL="$(git rev-parse --show-toplevel)"
  else
    BASEURL="$(pwd)"
  fi
fi
[ -d "$BASEURL" ] || die "Base path not found: $BASEURL"
cd "$BASEURL"

# ---- Tools ----
need pandoc || die "pandoc is required. Install: sudo apt-get install -y pandoc"
PDF_ENGINE=""
if need tectonic; then PDF_ENGINE="tectonic"
elif need wkhtmltopdf; then PDF_ENGINE="wkhtmltopdf"
elif need xelatex; then PDF_ENGINE="xelatex"
elif need pdflatex; then PDF_ENGINE="pdflatex"
else echo "Warning: No PDF engine found (tectonic/wkhtmltopdf/xelatex/pdflatex). Pandoc may fail." >&2
fi

# ---- Common prune set ----
PRUNE_DIRS="-name .git -o -name .venv -o -name .pytest_cache -o -name .ruff_cache -o -name .e2e-cache -o -name node_modules"

# ---- Collect files ----
declare -a FILES=()
declare -A SEEN=()

add_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  case "$(lower "$f")" in *.md) ;; *) return 0 ;; esac
  local base; base="$(basename "$f")"
  if is_excluded "$base"; then return 0; fi
  local key; key="$(lower "$(realpath -m "$f")")"
  [[ -n "${SEEN[$key]:-}" ]] && return 0
  SEEN[$key]=1; FILES+=("$f")
}

$DO_ALL || die "You must pass --ALL for this collection mode."

# 1) README in root
shopt -s nullglob
for r in README.md Readme.md readme.md; do
  if [ -f "$r" ]; then add_file "$r"; break; fi
done

# 2) docs/**/*.md
if [ -d "docs" ]; then
  while IFS= read -r -d '' f; do add_file "$f"; done < <(
    LC_ALL=C find docs \
      -type d \( $PRUNE_DIRS \) -prune -o \
      -type f -iname '*.md' -print0 | sort -z
  )
fi

# 3) root-level *.md (excluding README)
while IFS= read -r -d '' f; do
  case "$(basename "$f")" in README.md|Readme.md|readme.md) continue;; esac
  add_file "$f"
done < <(
  LC_ALL=C find . -maxdepth 1 \
    -type d \( $PRUNE_DIRS \) -prune -o \
    -type f -iname '*.md' -print0 | sort -z
)

# 4) remaining folders recursively
while IFS= read -r -d '' f; do add_file "$f"; done < <(
  LC_ALL=C find . -mindepth 2 \
    -type d \( $PRUNE_DIRS \) -prune -o \
    -type f -iname '*.md' -print0 | sort -z
)

EXTRA_SECTION_COUNT=0
[ -n "$INTRO_TEXT" ] && EXTRA_SECTION_COUNT=$((EXTRA_SECTION_COUNT + 1))
[ -n "$URL_META_INPUT" ] && EXTRA_SECTION_COUNT=$((EXTRA_SECTION_COUNT + 1))
[ -n "$URL_INPUT" ] && EXTRA_SECTION_COUNT=$((EXTRA_SECTION_COUNT + 1))
[ -n "$CREDITS_TEXT" ] && EXTRA_SECTION_COUNT=$((EXTRA_SECTION_COUNT + 1))
TOTAL_SECTIONS=$(( ${#FILES[@]} + EXTRA_SECTION_COUNT ))
[ "$TOTAL_SECTIONS" -gt 0 ] || die "No markdown content collected (no .md files and no --intro/--url-meta/--url/--credits provided)."

# ---- TMP & BREAK ----
TMP_DIR="$(mktemp -d)"
BREAK_MD="$TMP_DIR/___BREAK___.md"
printf '\n\n<div style="page-break-after: always;"></div>\n\n\\newpage\n\n' > "$BREAK_MD"

# ---- Optional intro / url-meta / url / credits sections ----
make_intro_md() {
  [ -n "$INTRO_TEXT" ] || return 1
  local f="$TMP_DIR/intro.md"
  {
    echo "# Introduction"
    echo
    printf '%s\n' "$INTRO_TEXT"
  } > "$f"
  echo "$f"
}

make_url_meta_md() {
  [ -n "$URL_META_INPUT" ] || return 1
  case "$URL_META_INPUT" in http://*|https://*) ;; *) die "--url-meta must start with http:// or https://";; esac
  need curl || die "--url-meta requires 'curl' to fetch content"
  local f_html="$TMP_DIR/url_meta_fetch.html"
  local f_md="$TMP_DIR/url_meta_intro.md"

  curl -fsSL --retry 2 --retry-delay 1 --max-time 30 "$URL_META_INPUT" -o "$f_html" \
    || die "Failed to fetch metadata URL: $URL_META_INPUT"

  python3 - "$URL_META_INPUT" "$f_html" "$f_md" <<'PY'
import sys
from html.parser import HTMLParser
from pathlib import Path

url, html_path, out_path = sys.argv[1:4]
text = Path(html_path).read_text(encoding="utf-8", errors="ignore")


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


parser = MetaParser()
parser.feed(text)

title = " ".join(parser.title_parts).strip()
for key in ("og:title", "twitter:title"):
    if not title and key in parser.meta:
        title = parser.meta[key]

description = ""
for key in ("description", "og:description", "twitter:description"):
    val = parser.meta.get(key, "").strip()
    if val:
        description = val
        break

lines = []
lines.append(f"# {title or 'Imported Page'}")
if description:
    lines.extend(["", description])
lines.extend(["", f"_Source: {url}_"])
Path(out_path).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

  echo "$f_md"
}

make_credits_md() {
  [ -n "$CREDITS_TEXT" ] || return 1
  local f="$TMP_DIR/credits.md"
  {
    echo "# Credits"
    echo
    printf '%s\n' "$CREDITS_TEXT"
  } > "$f"
  echo "$f"
}

make_url_md() {
  [ -n "$URL_INPUT" ] || return 1
  case "$URL_INPUT" in http://*|https://*) ;; *) die "--url must start with http:// or https://";; esac
  need curl || die "--url requires 'curl' to fetch content"
  local f_html="$TMP_DIR/url_fetch.html"
  local f_md="$TMP_DIR/url_content.md"
  local host

  curl -fsSL --retry 2 --retry-delay 1 --max-time 30 "$URL_INPUT" -o "$f_html" \
    || die "Failed to fetch URL: $URL_INPUT"

  pandoc --from=html --to=gfm --wrap=none --quiet -o "${f_md}.body" "$f_html" \
    || die "Failed to convert fetched HTML to Markdown (pandoc). URL: $URL_INPUT"

  host="$(printf '%s\n' "$URL_INPUT" | sed -n 's#^[A-Za-z][A-Za-z0-9+.-]*://##p' | cut -d/ -f1)"
  {
    printf '# Imported from %s\n\n' "${host:-$URL_INPUT}"
    printf '_Source: %s_\n\n' "$URL_INPUT"
    cat "${f_md}.body"
  } > "$f_md"
  rm -f "${f_md}.body"

  echo "$f_md"
}

# ---- resource-path (all dirs, pruned) ----
RESOURCE_PATH="$BASEURL"
while IFS= read -r -d '' d; do
  RESOURCE_PATH="$RESOURCE_PATH:$d"
done < <(LC_ALL=C find "$BASEURL" -type d \( $PRUNE_DIRS \) -prune -o -type d -print0 | sort -z)

# ---- header.tex (graphicx + wrap code + url breaking + \graphicspath) ----
HEADER_TEX="$TMP_DIR/header.tex"
{
  echo "% Auto-generated by build_proml_pdf.sh"
  echo "\\usepackage{graphicx}"
  cat <<'LATEX'
\usepackage{fvextra}
\usepackage[hyphens]{url}
\usepackage{hyperref}
\hypersetup{breaklinks=true}
\Urlmuskip=0mu plus 1mu\relax
\DefineVerbatimEnvironment{Highlighting}{Verbatim}{
  breaklines, breakanywhere, commandchars=\\\{\}, fontsize=\small, numbers=left, numbersep=3pt
}
\RecustomVerbatimEnvironment{verbatim}{Verbatim}{
  breaklines, breakanywhere, fontsize=\small
}
\setlength{\emergencystretch}{3em}
LATEX

  # Collect image dirs and their parents, for \graphicspath
  mapfile -t IMGDIRS < <(
    LC_ALL=C find "$BASEURL" \
      -type d \( $PRUNE_DIRS \) -prune -o \
      -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.pdf' -o -iname '*.eps' \) \
      -printf '%h\n' | sort -u
  )
  declare -A SEEN_DIR=()
  ALLPATHS=()
  for d in "${IMGDIRS[@]}"; do
    rel="${d#$BASEURL}"; [ -z "$rel" ] && rel="/"
    rel="${rel%/}"
    parent="$(dirname "$rel")"; parent="${parent%/}"
    for p in "$parent" "$rel"; do
      [ -z "$p" ] && p="/"
      key="$p/"
      if [[ -z "${SEEN_DIR[$key]+x}" ]]; then
        SEEN_DIR[$key]=1
        ALLPATHS+=("$key")
      fi
    done
  done
  if [ "${#ALLPATHS[@]}" -gt 0 ]; then
    printf "\\graphicspath{"
    for p in "${ALLPATHS[@]}"; do printf "{%s}" "$p"; done
    echo "}"
  fi
} > "$HEADER_TEX"

# ---- Lua filter: verify local images (or drop/replace), strip HTML <img> ----
LUA_FILTER="$TMP_DIR/verify_images.lua"
if $NO_IMAGES || [ "${NO_IMAGES:-0}" = "1" ]; then
  cat > "$LUA_FILTER" <<'LUA'
function Image(el)
  if el.caption and #el.caption > 0 then
    return pandoc.Emph(el.caption)
  else
    return {}
  end
end
function RawInline(el)
  if el.format:lower() == "html" and el.text:match("<%s*img[%s/>]") then
    return {}
  end
end
LUA
else
  # Build list of search dirs: repo root + parents from graphicspath
  printf 'SEARCH_DIRS = {' > "$LUA_FILTER"
  printf '"%s",' "$BASEURL" >> "$LUA_FILTER"
  while IFS= read -r line; do
    case "$line" in
      *\\graphicspath*) ;;
      *"{"*"}"*)
        paths="$(printf '%s\n' "$line" | sed -n 's/.*\\graphicspath{\(.*\)}/\1/p' | tr -d '{}' )"
        for p in $paths; do
          pp="${p#/}"; pp="${pp%/}"
          if [ -n "$pp" ]; then printf '"%s/%s",' "$BASEURL" "$pp" >> "$LUA_FILTER"; else printf '"%s",' "$BASEURL" >> "$LUA_FILTER"; fi
        done
        ;;
    esac
  done < "$HEADER_TEX"
  printf '}\n' >> "$LUA_FILTER"

  cat >> "$LUA_FILTER" <<'LUA'
local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close(); return true else return false end
end

local function try_resolve(src)
  if exists(src) then return src end
  for _,d in ipairs(SEARCH_DIRS or {}) do
    local p = (d .. "/" .. src):gsub("/+", "/")
    if exists(p) then return p end
  end
  return nil
end

function Image(el)
  local src = el.src or ""
  if src:match("^https?://") then
    if el.caption and #el.caption > 0 then
      return pandoc.Emph(el.caption)
    end
    return {}
  end
  local resolved = try_resolve(src)
  if resolved then
    el.src = resolved
    return el
  end
  if el.caption and #el.caption > 0 then
    return pandoc.Emph(el.caption)
  end
  return {}
end

function RawInline(el)
  if el.format:lower() == "html" and el.text:match("<%s*img[%s/>]") then
    return {}
  end
end
LUA
fi

# ---- Cleaners (badges + emoji) per file ----
clean_one() {
  local src="$1"; local idx="$2"
  local out="$TMP_DIR/$(printf '%04d' "$idx")-$(basename "$src")"
  cp "$src" "$out"

  # Strip badges unless KEEP_BADGES=1
  if [ "${KEEP_BADGES:-0}" != "1" ]; then
    perl -0777 -pe '
      s{\[!\[[^\]]*?\]\((https?:\/\/[^\)\s]+)\)\]\([^\)]*?\)}{
        my $u=$1;
        ($u =~ m{shields\.io|badgen\.net|badge|/actions/workflows/.*badge|circleci\.com|codecov\.io|coveralls\.io|sonarcloud\.io|readthedocs|github\.com/.*/badge}i
         || $u =~ m{\.svg(\?|$)}i || $u =~ m{\.png(\?|$)}i) ? "" : $&
      }gex' -i "$out"
    perl -0777 -pe '
      s{!\[[^\]]*?\]\((https?:\/\/[^\)\s]+)\)}{
        my $u=$1;
        ($u =~ m{shields\.io|badgen\.net|badge|/actions/workflows/.*badge|circleci\.com|codecov\.io|coveralls\.io|sonarcloud\.io|readthedocs|github\.com/.*/badge}i
         || $u =~ m{\.svg(\?|$)}i || $u =~ m{\.png(\?|$)}i) ? "" : $&
      }gex' -i "$out"
    perl -0777 -pe '
      s{<img\b[^>]*\bsrc=["'\''](https?:\/\/[^"'\''\s>]+)["'\''][^>]*>}{
        my $u=$1;
        ($u =~ m{shields\.io|badgen\.net|badge|/actions/workflows/.*badge|circleci\.com|codecov\.io|coveralls\.io|sonarcloud\.io|readthedocs|github\.com/.*/badge}i
         || $u =~ m{\.svg(\?|$)}i || $u =~ m{\.png(\?|$)}i) ? "" : $&
      }gex' -i "$out"
    perl -0777 -pe '
      s{^[ \t]*\[[^\]]+?\]:[ \t]*(https?:\/\/\S+)[ \t]*$}{
        my $u=$1;
        ($u =~ m{shields\.io|badgen\.net|badge|/actions/workflows/.*badge|circleci\.com|codecov\.io|coveralls\.io|sonarcloud\.io|readthedocs|github\.com/.*/badge}i
         || $u =~ m{\.svg(\?|$)}i || $u =~ m{\.png(\?|$)}i) ? "" : $&
      }gexm' -i "$out"
  fi

  # Strip emojis unless KEEP_EMOJI=1
  if [ "${KEEP_EMOJI:-0}" != "1" ]; then
    perl -CS -Mutf8 -pe '
      s/[\x{1F300}-\x{1FAFF}]//g;
      s/[\x{1F600}-\x{1F64F}]//g;
      s/[\x{1F1E6}-\x{1F1FF}]//g;
      s/[\x{2600}-\x{27BF}]//g;
      s/\x{FE0F}//g;
      s/\x{200D}//g;
    ' -i "$out"
  fi

  # Collapse extra blank lines
  awk 'BEGIN{b=0} { if ($0 ~ /^[[:space:]]*$/) { if (!b) print; b=1 } else { print; b=0 } }' "$out" > "$out.tmp" && mv "$out.tmp" "$out"

  printf '%s\n' "$out"
}

# ---- Build ordered content list (intro/url-meta/url + files + credits) ----
declare -a RAW_SECTIONS=()
INTRO_MD=""; URL_META_MD=""; URL_MD=""; CREDITS_MD=""
if [ -n "$INTRO_TEXT" ]; then INTRO_MD="$(make_intro_md)"; fi
if [ -n "$URL_META_INPUT" ]; then URL_META_MD="$(make_url_meta_md)"; fi
if [ -n "$URL_INPUT" ]; then URL_MD="$(make_url_md)"; fi
if [ -n "$CREDITS_TEXT" ]; then CREDITS_MD="$(make_credits_md)"; fi

[ -n "$INTRO_MD" ] && RAW_SECTIONS+=("$INTRO_MD")
[ -n "$URL_META_MD" ] && RAW_SECTIONS+=("$URL_META_MD")
[ -n "$URL_MD" ] && RAW_SECTIONS+=("$URL_MD")
RAW_SECTIONS+=("${FILES[@]}")
[ -n "$CREDITS_MD" ] && RAW_SECTIONS+=("$CREDITS_MD")

echo "Including ${#RAW_SECTIONS[@]} markdown sections (base: $BASEURL):"
for f in "${RAW_SECTIONS[@]}"; do
  case "$f" in
    "$INTRO_MD") echo " - [intro]    $f";;
    "$URL_META_MD") echo " - [url-meta] $f";;
    "$URL_MD") echo " - [url]      $f";;
    "$CREDITS_MD") echo " - [credits]  $f";;
    *) echo " - $f";;
  esac
done

# ---- Clean all & prepare inputs with breaks ----
declare -a CLEANED_SECTIONS=()
i=0
for f in "${RAW_SECTIONS[@]}"; do
  i=$((i+1))
  CLEANED_SECTIONS+=("$(clean_one "$f" "$i")")
done

declare -a INPUTS=()
for idx in "${!CLEANED_SECTIONS[@]}"; do
  INPUTS+=("${CLEANED_SECTIONS[$idx]}")
  if [ "$idx" -lt $(( ${#CLEANED_SECTIONS[@]} - 1 )) ]; then
    INPUTS+=("$BREAK_MD")
  fi
done

# ---- Build PDF ----
echo
echo "Building PDF → $OUTFILE (engine: ${PDF_ENGINE:-<pandoc default>})"
set -x

if [ "$PDF_ENGINE" = "tectonic" ]; then
  OUTDIR="${XDG_CACHE_HOME:-$HOME/.cache}/docforge-tex-$$"
  mkdir -p "$OUTDIR"
  TEX="$BASEURL/.__papyr_tmp_combined_$$.tex"

  pandoc \
    --file-scope \
    --from=markdown+footnotes+pipe_tables+table_captions+backtick_code_blocks+autolink_bare_uris \
    --to=latex \
    --standalone \
    --include-in-header="$HEADER_TEX" \
    --lua-filter="$LUA_FILTER" \
    --resource-path="$RESOURCE_PATH" \
    --highlight-style="$HL_STYLE" \
    -o "$TEX" \
    "${INPUTS[@]}"

  ( cd "$BASEURL" && tectonic --outdir="$OUTDIR" "$TEX" )
  mv "$OUTDIR/$(basename "${TEX%.tex}.pdf")" "$OUTFILE"
  rm -f "$TEX"
else
  pandoc \
    --file-scope \
    --from=markdown+footnotes+pipe_tables+table_captions+backtick_code_blocks+autolink_bare_uris \
    --include-in-header="$HEADER_TEX" \
    --lua-filter="$LUA_FILTER" \
    --resource-path="$RESOURCE_PATH" \
    --highlight-style="$HL_STYLE" \
    ${PDF_ENGINE:+--pdf-engine="$PDF_ENGINE"} \
    -o "$OUTFILE" \
    "${INPUTS[@]}"
fi

set +x
echo "✅ Done: $OUTFILE"
echo "🧹 Temp dir: $TMP_DIR (you can remove it whenever)"
