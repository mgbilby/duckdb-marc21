#!/usr/bin/env python3
"""Source-similarity measurement between the duckdb-marc21 extension's
files and other MARC software, for the provenance audit (SIMILARITY.md).

Pairwise usage:
    python3 similarity_check.py [--label NAME] FILE_A FILE_B [FILE_B...]

FILE_A is a file from the audited repository; each FILE_B is a comparison
file (e.g. from a shallow clone of pymarc or YAZ).  When several FILE_B
are given they are concatenated, so a single translation unit can be
compared against a whole family of files (e.g. z3950.cpp vs all of YAZ's
ber_*.c).

Full-suite usage (no hardcoded paths; runnable from any directory or
repository):
    python3 similarity_check.py --audit --repo /path/to/duckdb-marc21 \
        --clones /path/to/clones

runs every comparison and control documented in SIMILARITY.md.  --repo is
the root of the audited extension checkout; --clones is a directory
containing shallow clones named pymarc, MARC-Charset, marc4j, yaz,
library-callnumber-lc, and avram-js.

Metrics (all in [0, 1]; higher = more similar):

  seq_ratio      difflib.SequenceMatcher ratio over whitespace-normalised
                 text.  Sensitive to any large-scale copying, including
                 moved blocks only weakly.
  line_overlap   Fraction of A's distinct non-trivial normalised lines
                 (>= 12 significant chars) that appear verbatim in B.
                 Catches copied lines even when reordered.
  tok_jaccard5   Jaccard similarity of 5-token shingles of the lexed
                 token streams (comments and string contents dropped,
                 numbers/identifiers kept verbatim).  Catches copied code
                 with changed formatting or comments.
  ident_jaccard  Jaccard similarity of identifier sets (length >= 4,
                 language keywords excluded).  Catches copied naming even
                 when logic is rewritten.
  comment_sh3    Jaccard similarity of 3-word shingles of the extracted
                 comment/doc text.  Catches copied prose.

Interpretation guidance (calibrate with known-independent pairs, e.g.
pymarc's marc8.py vs MARC::Charset's Charset.pm — two independent
implementations of the same spec): independent implementations of the
same specification typically score < 0.05 on tok_jaccard5 and
comment_sh3, and < 0.25 on ident_jaccard (shared spec vocabulary).
Values far above such a baseline indicate textual derivation.

Only the Python standard library is used.
"""

import argparse
import difflib
import json
import re
import sys

# --- lexing ----------------------------------------------------------------

COMMENT_RE = re.compile(
    r"""
    //[^\n]*            # C++ line comment
  | /\*.*?\*/           # C block comment
  | \#[^\n]*            # Python/Perl/shell line comment
  | ^=(?:head|cut|item|over|back|pod)[^\n]*  # POD directives (coarse)
    """,
    re.VERBOSE | re.DOTALL | re.MULTILINE,
)
STRING_RE = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', re.DOTALL)
TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|0[xX][0-9A-Fa-f]+|\d+|[^\sA-Za-z0-9_]")
WORD_RE = re.compile(r"[A-Za-z][A-Za-z0-9_]*")

KEYWORDS = frozenset(
    """auto bool break case catch char class const constexpr continue default
    delete do double else enum explicit extern false float for friend goto if
    inline int long namespace new noexcept nullptr operator private protected
    public register return short signed sizeof static struct switch template
    this throw true try typedef typename union unsigned using virtual void
    while uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t
    size_t char32_t std string vector def elif import from lambda pass raise
    with yield None True False self and or not in is elif except finally
    global assert del print my our sub use package shift return local
    unless foreach elsif eq ne die warn defined undef""".split()
)


def read(path):
    with open(path, "rb") as fh:
        return fh.read().decode("utf-8", "replace")


def strip_comments(text):
    """Return (code_without_comments_or_string_bodies, comment_text)."""
    comments = " ".join(m.group(0) for m in COMMENT_RE.finditer(text))
    code = COMMENT_RE.sub(" ", text)
    code = STRING_RE.sub('"S"', code)
    return code, comments


def norm_lines(text, min_sig=12):
    out = set()
    for line in text.splitlines():
        collapsed = re.sub(r"\s+", " ", line).strip()
        if len(re.sub(r"[^A-Za-z0-9]", "", collapsed)) >= min_sig:
            out.add(collapsed)
    return out


def shingles(seq, k):
    return {tuple(seq[i : i + k]) for i in range(len(seq) - k + 1)}


def jaccard(a, b):
    if not a and not b:
        return 0.0
    union = len(a | b)
    return len(a & b) / union if union else 0.0


# --- metrics ---------------------------------------------------------------

def compare(text_a, text_b):
    norm_a = re.sub(r"\s+", " ", text_a)
    norm_b = re.sub(r"\s+", " ", text_b)
    seq_ratio = difflib.SequenceMatcher(None, norm_a, norm_b, autojunk=True).ratio()

    lines_a, lines_b = norm_lines(text_a), norm_lines(text_b)
    line_overlap = len(lines_a & lines_b) / len(lines_a) if lines_a else 0.0
    shared_lines = sorted(lines_a & lines_b, key=len, reverse=True)

    code_a, com_a = strip_comments(text_a)
    code_b, com_b = strip_comments(text_b)

    toks_a = TOKEN_RE.findall(code_a)
    toks_b = TOKEN_RE.findall(code_b)
    tok_jaccard5 = jaccard(shingles(toks_a, 5), shingles(toks_b, 5))

    idents = lambda toks: {
        t.lower() for t in toks if WORD_RE.fullmatch(t) and len(t) >= 4 and t.lower() not in KEYWORDS
    }
    ident_jaccard = jaccard(idents(toks_a), idents(toks_b))
    shared_idents = sorted(idents(toks_a) & idents(toks_b))

    words = lambda com: [w.lower() for w in WORD_RE.findall(com)]
    comment_sh3 = jaccard(shingles(words(com_a), 3), shingles(words(com_b), 3))

    return {
        "seq_ratio": round(seq_ratio, 4),
        "line_overlap": round(line_overlap, 4),
        "tok_jaccard5": round(tok_jaccard5, 4),
        "ident_jaccard": round(ident_jaccard, 4),
        "comment_sh3": round(comment_sh3, 4),
        "shared_lines": shared_lines[:8],
        "shared_idents": shared_idents[:40],
        "n_lines_a": len(lines_a),
        "n_lines_b": len(lines_b),
    }


def run_pair(label, file_a, files_b, as_json=False, details=True):
    text_a = read(file_a)
    text_b = "\n".join(read(p) for p in files_b)
    result = compare(text_a, text_b)
    result["a"] = file_a
    result["b"] = files_b
    if label:
        result["label"] = label

    if as_json:
        json.dump(result, sys.stdout, indent=1)
        print()
        return result

    name = label or "{} vs {}".format(file_a, files_b[0])
    print("== {}".format(name))
    print("   A: {} ({} sig. lines)".format(file_a, result["n_lines_a"]))
    for p in files_b:
        print("   B: {}".format(p))
    for key in ("seq_ratio", "line_overlap", "tok_jaccard5", "ident_jaccard", "comment_sh3"):
        print("   {:<14} {:.4f}".format(key, result[key]))
    if details and result["shared_lines"]:
        print("   shared lines (longest first, up to 8):")
        for line in result["shared_lines"]:
            print("     | {}".format(line[:100]))
    if details and result["shared_idents"]:
        print("   shared identifiers (up to 40): {}".format(" ".join(result["shared_idents"])))
    return result


# The full comparison suite behind SIMILARITY.md.  Paths are relative to
# --repo (ours) and --clones (theirs); nothing is hardcoded to a checkout
# layout beyond the clone directory names.
AUDIT_SUITE = [
    ("marc8_tables.hpp vs pymarc marc8_mapping.py",
     "src/include/marc/marc8_tables.hpp", ["pymarc/pymarc/marc8_mapping.py"]),
    ("marc8_tables.hpp vs MARC::Charset Table+Code+Compiler",
     "src/include/marc/marc8_tables.hpp",
     ["MARC-Charset/lib/MARC/Charset/Table.pm", "MARC-Charset/lib/MARC/Charset/Code.pm",
      "MARC-Charset/lib/MARC/Charset/Compiler.pm"]),
    ("marc8_tables.hpp vs MARC4J CodeTable machinery",
     "src/include/marc/marc8_tables.hpp",
     ["marc4j/src/org/marc4j/converter/impl/CodeTable.java",
      "marc4j/src/org/marc4j/converter/impl/CodeTableGenerator.java"]),
    ("marc8.cpp vs pymarc marc8.py", "src/core/marc8.cpp", ["pymarc/pymarc/marc8.py"]),
    ("marc8.cpp vs MARC::Charset Charset.pm", "src/core/marc8.cpp", ["MARC-Charset/lib/MARC/Charset.pm"]),
    ("marc8.cpp vs MARC4J AnselToUnicode.java", "src/core/marc8.cpp",
     ["marc4j/src/org/marc4j/converter/impl/AnselToUnicode.java"]),
    ("z3950.cpp vs YAZ ber_*.c", "src/core/z3950.cpp",
     ["yaz/src/ber_any.c", "yaz/src/ber_bit.c", "yaz/src/ber_bool.c", "yaz/src/ber_int.c",
      "yaz/src/ber_len.c", "yaz/src/ber_null.c", "yaz/src/ber_oct.c", "yaz/src/ber_oid.c",
      "yaz/src/ber_tag.c"]),
    ("z3950.cpp vs YAZ odr core", "src/core/z3950.cpp",
     ["yaz/src/odr.c", "yaz/src/odr_cons.c", "yaz/src/odr_seq.c", "yaz/src/odr_tag.c",
      "yaz/src/odr_oid.c", "yaz/src/odr_int.c", "yaz/src/odr_util.c"]),
    ("callnum.cpp vs Library::CallNumber::LC (Perl)", "src/core/callnum.cpp",
     ["library-callnumber-lc/perl/Library-CallNumber-LC/lib/Library/CallNumber/LC.pm"]),
    ("callnum.cpp vs library-callnumber-lc (Python)", "src/core/callnum.cpp",
     ["library-callnumber-lc/python/callnumber/__init__.py"]),
    ("marc21_bibliographic.avram.json vs GBV avram-js marc21-bibliographic.json",
     "schemas/marc21_bibliographic.avram.json", ["avram-js/test/schemas/marc21-bibliographic.json"]),
]

AUDIT_CONTROLS = [
    ("CONTROL identity: marc8.cpp vs itself", ("repo", "src/core/marc8.cpp"), [("repo", "src/core/marc8.cpp")]),
    ("CONTROL same-project siblings: YAZ ber_bit.c vs ber_oct.c",
     ("clones", "yaz/src/ber_bit.c"), [("clones", "yaz/src/ber_oct.c")]),
    ("BASELINE independent implementations: pymarc marc8.py vs MARC::Charset Charset.pm",
     ("clones", "pymarc/pymarc/marc8.py"), [("clones", "MARC-Charset/lib/MARC/Charset.pm")]),
]


def run_audit(repo, clones, as_json=False):
    import os

    roots = {"repo": repo, "clones": clones}
    for label, a, bs in AUDIT_CONTROLS:
        run_pair(label, os.path.join(roots[a[0]], a[1]),
                 [os.path.join(roots[b[0]], b[1]) for b in bs], as_json, details=False)
    for label, a, bs in AUDIT_SUITE:
        run_pair(label, os.path.join(repo, a), [os.path.join(clones, b) for b in bs], as_json)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--label", default=None, help="name for this comparison")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of text")
    ap.add_argument("--audit", action="store_true",
                    help="run the full documented comparison suite (needs --repo and --clones)")
    ap.add_argument("--repo", default=None, help="root of the audited duckdb-marc21 checkout")
    ap.add_argument("--clones", default=None, help="directory holding the comparison clones")
    ap.add_argument("file_a", nargs="?", help="file from the audited repository")
    ap.add_argument("file_b", nargs="*", help="comparison file(s); concatenated")
    args = ap.parse_args()

    if args.audit:
        if not args.repo or not args.clones:
            ap.error("--audit requires --repo and --clones")
        run_audit(args.repo, args.clones, args.json)
        return
    if not args.file_a or not args.file_b:
        ap.error("need FILE_A and at least one FILE_B (or --audit)")
    run_pair(args.label, args.file_a, args.file_b, args.json)


if __name__ == "__main__":
    main()
