#!/usr/bin/env bash
set -euo pipefail

# =========================================
# build_proml_pdf.sh
#
# Bygger EN PDF av dina Markdown-filer i ordningen:
#   1) README.md (i repo-root, case-insensitive)
#   2) docs/**/*.md (rekursivt, sorterat)
#   3) *.md i repo-root (exkl. README)
#   4) återstående mappar rekursivt (alla *.md), dubbletter filtreras
#
# CLI:
#   ./scripts/build_proml_pdf.sh --baseURL <path> --ALL [--exclude <glob> ...] <outfile.pdf>
#
# Exempel:
#   ./scripts/build_proml_pdf.sh --baseURL /home/johan/ProML --ALL \
#     --exclude CHANGELOG.md --exclude "DRAFT*.md" ProML.pdf
#
# Noteringar:
# - Kräver pandoc. PDF-motorer: tectonic (rekommenderad), wkhtmltopdf, xelatex, pdflatex.
# - Tectonic via snap kan strula med /tmp; vi kör tvåsteg (md->tex->pdf) till $HOME/.cache.
# =========================================

# ---- Defaults / Params ----
BASEURL=""
DO_ALL=false
declare -a EXCLUDES=()
OUTFILE=""

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
  local lbase
  lbase="$(lower "$base")"
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
  $(basename "$0") --baseURL <path> --ALL [--exclude <name|glob> ...] <outfile.pdf>

Options:
  --baseURL <path>     Repository root. Omittas -> försök 'git rev-parse' annars cwd.
  --ALL                Samla filer i ordningen README -> docs/** -> root-*.md -> övriga mappar.
  --exclude <pattern>  Case-insensitive glob på filnamn (basename). Kan upprepas eller komma-separeras.
  -h, --help           Visa hjälp.

Exempel:
  $(basename "$0") --baseURL /home/johan/ProML --ALL --exclude CHANGELOG.md ProML.pdf
EOF
}

# ---- Parse args ----
if [ "$#" -eq 0 ]; then usage; exit 1; fi
while (( "$#" )); do
  case "$1" in
    --baseURL) shift; [ $# -gt 0 ] || die "--baseURL needs a value"; BASEURL="$(normpath "$1")";;
    --ALL) DO_ALL=true;;
    --exclude) shift; [ $# -gt 0 ] || die "--exclude needs a value"; EXCLUDES+=("$1");;
    -h|--help) usage; exit 0;;
    --) shift; break;;
    -* ) die "Unknown option: $1";;
    *  )
      if [ -z "$OUTFILE" ]; then OUTFILE="$1"; else die "Unexpected extra argument: $1"; fi
      ;;
  esac
  shift || true
done

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
need pandoc || die "pandoc is required. Install: sudo apt-get update && sudo apt-get install -y pandoc"
PDF_ENGINE=""
if need tectonic; then PDF_ENGINE="tectonic"
elif need wkhtmltopdf; then PDF_ENGINE="wkhtmltopdf"
elif need xelatex; then PDF_ENGINE="xelatex"
elif need pdflatex; then PDF_ENGINE="pdflatex"
else echo "Warning: No PDF engine found (tectonic/wkhtmltopdf/xelatex/pdflatex). Pandoc may fail." >&2
fi

# ---- Collect files ----
declare -a FILES=()
declare -A SEEN=()

add_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  case "$(lower "$f")" in
    *.md) ;;
    *) return 0 ;;
  esac
  local base
  base="$(basename "$f")"
  if is_excluded "$base"; then return 0; fi
  local key
  key="$(lower "$(realpath -m "$f")")"
  if [[ -n "${SEEN[$key]:-}" ]]; then return 0; fi
  SEEN[$key]=1
  FILES+=("$f")
}

$DO_ALL || die "You must pass --ALL for this collection mode."

# 1) README i root (case-insensitive, första träff vinner)
shopt -s nullglob
for r in README.md Readme.md readme.md; do
  if [ -f "$r" ]; then add_file "$r"; break; fi
done

# 2) docs/**/*.md
if [ -d "docs" ]; then
  while IFS= read -r -d '' f; do add_file "$f"; done < <(LC_ALL=C find docs -type f -iname '*.md' -print0 | sort -z)
fi

# 3) root-level *.md (exkl. README)
while IFS= read -r -d '' f; do
  case "$(basename "$f")" in
    README.md|Readme.md|readme.md) continue;;
  esac
  add_file "$f"
done < <(LC_ALL=C find . -maxdepth 1 -type f -iname '*.md' -print0 | sort -z)

# 4) övriga mappar rekursivt
while IFS= read -r -d '' f; do add_file "$f"; done < <(LC_ALL=C find . -mindepth 2 -type f -iname '*.md' -print0 | sort -z)

[ "${#FILES[@]}" -gt 0 ] || die "No markdown files collected."

echo "Including ${#FILES[@]} markdown files (base: $BASEURL):"
for f in "${FILES[@]}"; do echo " - $f"; done

# ---- Aggregate into single MD with page breaks ----
TMP_DIR="$(mktemp -d)"
AGG_MD="$TMP_DIR/_all.md"

TITLE="${TITLE:-$(basename "$BASEURL") — Documentation}"
AUTHOR="${AUTHOR:-}"
DATE="${DATE:-$(date +%Y-%m-%d)}"

cat > "$AGG_MD" <<'YAML'
---
title: PLACEHOLDER_TITLE
author: PLACEHOLDER_AUTHOR
date: PLACEHOLDER_DATE
toc: true
toc-depth: 3
numbersections: true
---
YAML

esc() { printf '%s' "$1" | sed 's/[&/\]/\\&/g'; }
sed -i.bak "s/PLACEHOLDER_TITLE/$(esc "$TITLE")/" "$AGG_MD"
sed -i.bak "s/PLACEHOLDER_AUTHOR/$(esc "$AUTHOR")/" "$AGG_MD"
sed -i.bak "s/PLACEHOLDER_DATE/$(esc "$DATE")/" "$AGG_MD"
rm -f "$AGG_MD.bak"

PAGEBREAK=$'\n\n<div style="page-break-after: always;"></div>\n\n\\newpage\n\n'
for i in "${!FILES[@]}"; do
  cat "${FILES[$i]}" >> "$AGG_MD"
  if [ "$i" -lt $((${#FILES[@]} - 1)) ]; then
    printf "%s" "$PAGEBREAK" >> "$AGG_MD"
  fi
done

# ---- Build PDF ----
# För Tectonic (snap): kör tvåsteg md->tex->pdf i en egen cache-katalog vi äger
echo
echo "Building PDF → $OUTFILE (engine: ${PDF_ENGINE:-<pandoc default>})"
set -x

RESOURCE_PATH="$BASEURL:$BASEURL/docs:docs:."

if [ "$PDF_ENGINE" = "tectonic" ]; then
  OUTDIR="${XDG_CACHE_HOME:-$HOME/.cache}/docforge-tex-$$"
  mkdir -p "$OUTDIR"
  TEX="$OUTDIR/combined.tex"

  pandoc \
    --from=markdown+footnotes+pipe_tables+table_captions+backtick_code_blocks+autolink_bare_uris \
    --to=latex \
    --standalone \
    --resource-path="$RESOURCE_PATH" \
    --highlight-style=kate \
    -o "$TEX" \
    "$AGG_MD"

  tectonic --outdir="$OUTDIR" "$TEX"

  mv "$OUTDIR/combined.pdf" "$OUTFILE"
else
  pandoc \
    --from=markdown+footnotes+pipe_tables+table_captions+backtick_code_blocks+autolink_bare_uris \
    --resource-path="$RESOURCE_PATH" \
    --highlight-style=kate \
    ${PDF_ENGINE:+--pdf-engine="$PDF_ENGINE"} \
    -o "$OUTFILE" \
    "$AGG_MD"
fi

set +x
echo "✅ Done: $OUTFILE"
echo "🧹 Temp dir: $TMP_DIR (du kan ta bort den när du vill)"

