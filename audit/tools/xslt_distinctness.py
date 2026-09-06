#!/usr/bin/env python3
"""Fuzzy-match check that this project's XSLT crosswalks are original work.

Compares every stylesheet under an "ours" directory against every stylesheet
in one or more reference corpora (clones of MarcEdit's published XSLT
repositories and LC-derived stylesheet collections) using normalized
token-shingle similarity:

  1. strip XML comments and collapse all whitespace;
  2. lowercase and tokenize into name/attribute words and punctuation;
  3. form overlapping n-token shingles (default n=5);
  4. score each pair.

Any two XSLT stylesheets over the MARC vocabulary share a large amount of
pure syntax ("</xsl:template> <xsl:template match=...", "marc:subfield
@code" tests, and so on). Empirically, *unrelated* third-party stylesheets
score raw Jaccard up to ~0.16 on 5-token shingles just from that idiom, so
raw overlap cannot distinguish shared syntax from derivation. The tool
therefore computes two scores per pair:

  raw Jaccard        |A & B| / |A | B| over all shingles - a wholesale-copy
                     detector (a derived file scores 0.3+);
  rare Jaccard       the same measure restricted to non-generic shingles.
                     A shingle is "generic" when it occurs in at least
                     --generic-df distinct reference files (default 3):
                     something three unrelated stylesheets all contain is
                     shared idiom, not evidence of copying. Rare-shingle
                     overlap is what a real derivation cannot avoid: it
                     would share the donor's distinctive template bodies.

Containment |A & B| / min(|A|, |B|) is reported alongside each, catching a
small file lifted wholesale into a large one. The check fails when any
pair reaches --rare-threshold on rare Jaccard (default 0.05) or
--raw-threshold on raw Jaccard (default 0.30).

Usage:
  python3 tools/xslt_distinctness.py [--matrix]
      OURS_DIR CORPUS_DIR [CORPUS_DIR ...]
"""

import argparse
import re
import sys
from pathlib import Path

COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)
TOKEN_RE = re.compile(r"[A-Za-z0-9_.:@-]+|[^\sA-Za-z0-9_.:@-]")


def normalize(text: str) -> list[str]:
    """Comment-free, whitespace-collapsed, lowercased token stream."""
    text = COMMENT_RE.sub(" ", text)
    return [t.lower() for t in TOKEN_RE.findall(text)]


def shingles(tokens: list[str], n: int) -> set[tuple[str, ...]]:
    if len(tokens) < n:
        return {tuple(tokens)} if tokens else set()
    return {tuple(tokens[i : i + n]) for i in range(len(tokens) - n + 1)}


def load_corpus(root: Path, n: int) -> dict[str, set]:
    out = {}
    for path in sorted(root.rglob("*.xsl")) + sorted(root.rglob("*.xslt")):
        try:
            raw = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            print(f"warning: cannot read {path}: {exc}", file=sys.stderr)
            continue
        out[str(path.relative_to(root))] = shingles(normalize(raw), n)
    return out


def jaccard_containment(a: set, b: set) -> tuple[float, float]:
    if not a or not b:
        return 0.0, 0.0
    inter = len(a & b)
    return inter / len(a | b), inter / min(len(a), len(b))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("ours", type=Path, help="directory of this project's stylesheets")
    ap.add_argument("corpora", type=Path, nargs="+", help="reference corpora to compare against")
    ap.add_argument("--shingle", type=int, default=5, help="shingle size in tokens (default 5)")
    ap.add_argument("--generic-df", type=int, default=3,
                    help="shingles in >= this many reference files are generic idiom (default 3)")
    ap.add_argument("--rare-threshold", type=float, default=0.05,
                    help="fail when rare-shingle Jaccard reaches this (default 0.05)")
    ap.add_argument("--raw-threshold", type=float, default=0.30,
                    help="fail when raw Jaccard reaches this (default 0.30)")
    ap.add_argument("--matrix", action="store_true", help="print the full score matrix")
    args = ap.parse_args()

    mine = load_corpus(args.ours, args.shingle)
    if not mine:
        print(f"error: no stylesheets found under {args.ours}", file=sys.stderr)
        return 2

    corpora = []
    for corpus_dir in args.corpora:
        theirs = load_corpus(corpus_dir, args.shingle)
        if not theirs:
            print(f"warning: no stylesheets under {corpus_dir}", file=sys.stderr)
            continue
        corpora.append((corpus_dir, theirs))

    # document frequency of every shingle across all reference files
    df: dict = {}
    n_ref = 0
    for _, theirs in corpora:
        for sh in theirs.values():
            n_ref += 1
            for s in sh:
                df[s] = df.get(s, 0) + 1
    generic = {s for s, k in df.items() if k >= args.generic_df}
    print(f"reference corpus: {n_ref} stylesheets, "
          f"{len(df)} distinct shingles, {len(generic)} generic "
          f"(df >= {args.generic_df})")

    failures = []
    worst = {name: (0.0, 0.0, 0.0, "-") for name in mine}

    for corpus_dir, theirs in corpora:
        if args.matrix:
            print(f"\n== corpus: {corpus_dir} ({len(theirs)} stylesheets) ==")
        for my_name, my_sh in sorted(mine.items()):
            my_rare = my_sh - generic
            for their_name, their_sh in sorted(theirs.items()):
                raw_j, raw_c = jaccard_containment(my_sh, their_sh)
                rare_j, rare_c = jaccard_containment(my_rare, their_sh - generic)
                label = f"{corpus_dir.name}/{their_name}"
                if args.matrix:
                    print(f"  {my_name:34s} vs {label:55s} "
                          f"rare J={rare_j:.4f} C={rare_c:.4f} | raw J={raw_j:.4f}")
                if rare_j > worst[my_name][0] or (
                        rare_j == worst[my_name][0] and raw_j > worst[my_name][2]):
                    worst[my_name] = (rare_j, rare_c, raw_j, label)
                if rare_j >= args.rare_threshold or raw_j >= args.raw_threshold:
                    failures.append((my_name, label, rare_j, raw_j))

    print("\n== worst match per stylesheet (by rare-shingle Jaccard) ==")
    for name, (rare_j, rare_c, raw_j, label) in sorted(worst.items()):
        print(f"  {name:34s} rare J={rare_j:.4f} C={rare_c:.4f} "
              f"raw J={raw_j:.4f}  ({label})")

    if failures:
        print(f"\nFAIL: {len(failures)} pair(s) over threshold "
              f"(rare >= {args.rare_threshold} or raw >= {args.raw_threshold}):")
        for my_name, label, rare_j, raw_j in failures:
            print(f"  {my_name} ~ {label}: rare J={rare_j:.4f} raw J={raw_j:.4f}")
        return 1
    print(f"\nOK: all pairs below rare-Jaccard {args.rare_threshold} "
          f"and raw-Jaccard {args.raw_threshold}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
