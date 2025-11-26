# 🧠 PapyrAI

> **“From Markdown to masterpiece.”**  
> PapyrAI is a minimal, ultra-fast CLI tool that forges all your `.md` files into a single, elegant PDF —  
> perfect for AI documentation, research exports, or NotebookLM input.

---

## 🚀 Purpose

PapyrAI automates documentation export for modern AI, dev, and research projects.  
It merges your Markdown structure (`README.md`, `/docs`, and root notes) into one polished PDF,  
with page breaks, table of contents, syntax highlighting, and consistent style.

---

## ✨ Features

- 🧩 **Automatic structure detection**
  - `README.md` (or chosen root) first  
  - All `docs/**/*.md` files next  
  - Remaining `.md` files in repo root last  
  - Then all other folders recursively  

- 🧱 **Page breaks** between files (HTML + LaTeX compatible)
- 📑 **Auto-generated Table of Contents**
- 🎨 **Syntax highlighting** (`--highlight-style=kate`)
- 🧠 **Supports Tectonic / wkhtmltopdf / xelatex / pdflatex**
- 🪶 **No dependencies beyond Pandoc**
- 🗒️ **Optional intro, web-scraped section, and credits**
- 💡 **Perfect for NotebookLM, whitepapers, and versioned docs**
- 🧰 **Clean temp handling & exclusion filters** (`--exclude`)

---

## 🧰 Installation

### Ubuntu / WSL2
```bash
sudo apt-get update
sudo apt-get install -y pandoc wkhtmltopdf
sudo snap install tectonic    # optional, for better typography
```

### macOS
```bash
brew install pandoc tectonic
```

---

## ⚙️ Usage

```bash
./scripts/build_proml_pdf.sh --baseURL <path> --ALL [--intro "<text>"] [--url <https://...>] [--credits "<text>"] [--exclude <glob> ...] [--no-images] <outfile.pdf>
```

### Examples
```bash
# Standard run
./scripts/build_proml_pdf.sh --baseURL /path/to/project --ALL output.pdf

# Add intro and credits
./scripts/build_proml_pdf.sh --baseURL /path/to/project --ALL \
  --intro "Title: My Project" \
  --credits "Team: Docs squad" \
  output.pdf

# Pull a web page into the PDF
./scripts/build_proml_pdf.sh --baseURL /path/to/project --ALL --url https://example.com/blog/post output.pdf

# Only intro + URL + credits (utan lokala .md-filer)
EMPTY_DIR=$(mktemp -d)
./scripts/build_proml_pdf.sh --baseURL "$EMPTY_DIR" --ALL \
  --intro "Example intro text" \
  --url https://example.com/blog/post \
  --credits "Source: example.com" \
  output.pdf

# Alternativt, kvar i repo-roten men exkludera alla .md
./scripts/build_proml_pdf.sh --baseURL /path/to/project --ALL --exclude "*.md" \
  --intro "..." --url https://... --credits "..." out.pdf

# Exclude changelog and drafts
./scripts/build_proml_pdf.sh --baseURL /path/to/project --ALL --exclude CHANGELOG.md --exclude "DRAFT*.md" output.pdf

# Custom metadata
TITLE="ProML — AI Prompt Markup Language" AUTHOR="Johan Caripson" ./scripts/build_proml_pdf.sh --baseURL . --ALL output.pdf
```

---

## 🧪 Output Example

Given this repo structure:
```
README.md
docs/
  ├─ intro.md
  ├─ syntax.md
  └─ cli.md
CHANGELOG.md
tutorials/
  ├─ overview.md
  └─ examples.md
```

PapyrAI produces:
```
ProML.pdf
├─ Cover page (title, author, date)
├─ Table of Contents
├─ README.md content
├─ docs/ content (sorted)
├─ root-level markdown
└─ all other folders recursively
```

---

## 🛠 Script Reference

All logic lives in:

```
scripts/build_proml_pdf.sh
```

This script:
- Detects available PDF engines (`tectonic`, `wkhtmltopdf`, etc.)
- Collects and orders Markdown files
- Merges them with page breaks
- Builds a PDF via Pandoc (with fallback for Tectonic snap limitations)
- Cleans up temp files after build

---

## 🧾 License

MIT License © 2025 Johan Caripson  
See `LICENSE` for details.

---
