#!/bin/bash
# The paper's source as arXiv takes it: the .tex, the tables it inputs and the figures it includes, nothing
# else (the bibliography is inline, so there is no .bib or .bbl). Compiled twice with pdfLaTeX in a clean
# folder first, so a package that is not in the archive or a missing file fails here, not on arXiv.
# Usage: paper/make_arxiv.sh [output.tar.gz]   (default: ~/Documents/velocity-paper-arxiv/velocity_mode_arxiv.tar.gz)
set -e
cd "$(dirname "$0")"
OUT="${1:-$HOME/Documents/velocity-paper-arxiv/velocity_mode_arxiv.tar.gz}"
mkdir -p "$(dirname "$OUT")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src/tables" "$TMP/src/figures"
cp velocity_mode.tex "$TMP/src/"
cp tables/*.tex "$TMP/src/tables/"
# only the figures the paper includes
grep -o 'figures/[A-Za-z0-9_]*\.pdf' velocity_mode.tex | sort -u | while read -r f; do cp "$f" "$TMP/src/$f"; done
mkdir -p "$TMP/build" && cp -R "$TMP/src/." "$TMP/build/"
( cd "$TMP/build" && pdflatex -interaction=nonstopmode -halt-on-error velocity_mode.tex > pass1.log \
  && pdflatex -interaction=nonstopmode -halt-on-error velocity_mode.tex > pass2.log ) \
  || { echo "pdfLaTeX failed:"; tail -30 "$TMP/build/velocity_mode.log"; exit 1; }
if grep -q "Reference.*undefined\|Citation.*undefined" "$TMP/build/velocity_mode.log"; then
  echo "undefined references:"; grep "undefined" "$TMP/build/velocity_mode.log"; exit 1
fi
pages=$(grep -o 'Output written on velocity_mode.pdf ([0-9]* pages' "$TMP/build/velocity_mode.log" | grep -o '[0-9]* pages')
( cd "$TMP/src" && COPYFILE_DISABLE=1 tar -czf "$OUT" velocity_mode.tex tables figures )
echo "arXiv source: $OUT ($(du -h "$OUT" | cut -f1), compiles to $pages)"
