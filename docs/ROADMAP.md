# marc21 roadmap

marc21 version numbers follow the DuckDB release the extension is built
against: **1.5.6** is built for DuckDB v1.5.6, and **2.0.0** will be the first
release built for DuckDB v2.0. A feature listed for 2.0.0 is not in the binary
that `INSTALL marc21 FROM community` gives you today.

## Current release: 1.5.6

- Built and tested against DuckDB v1.5.6.
- Every function marc21 registers (C++ functions, readers and SQL macros)
  carries catalog documentation in `duckdb_functions()`: a description, a
  runnable example, categories, and real argument names in place of
  `col0, col1, ...`. That is what the community-extensions page's "Added
  Functions" table and SQL-connected tools read.

## Planned for 2.0.0

| feature | status | notes |
|---|---|---|
| Build against DuckDB v2.0 | in source | `src/include/marc/compat.hpp` compiles both ways; CI builds v2.0 on manual dispatch until upstream cuts a stable v2.0 ci-tools branch |
| Multi-file readers | in source | list arguments, `union_by_name`, `hive_partitioning`, `filename`, `allow_empty` on every file reader ([DUCKDB2.md](DUCKDB2.md) §2) |
| `COPY ... FROM` for `marc`, `marcxml`, `mrk`, `marcjson` | in source | loading through `COPY` instead of `read_*` plus `INSERT INTO ... SELECT` |
| Top-k reconciliation with `NEAREST` joins | in source | the `marc_nearest_*` macros in `src/macros_v2/` ([DUCKDB2.md](DUCKDB2.md) §4) |
| Scan metrics in the profiler | in source | `marc_records_parsed`, `marc8_records`, `marc_utf8_records`, `marc_decode_errors` ([DUCKDB2.md](DUCKDB2.md) §5) |
| BibLaTeX export | planned | `marc_biblatex(leader, fields)`: one BibLaTeX `.bib` entry per record; see below |
| BibTeX export | planned | `marc_bibtex(leader, fields)`: one classic BibTeX `.bib` entry per record; see below |
| BibLaTeX import | planned | `read_bib(path)`: `.bib` files read as records in the `read_marc` shape; see below |
| BibTeX import | planned | the same `read_bib(path)`: one reader understands both dialects' entry types and field names |

### BibLaTeX and BibTeX conversion

Both share one `.bib` file syntax, so marc21 will support both from one
shared mapping: two export macros and one reader, not two separate
converters. The dialects differ in what the target can hold:

- **BibLaTeX** (usually processed by Biber) reads UTF-8 directly, so marc21's
  NFC Unicode values go out unchanged. It has native fields for what catalog
  records carry (`isbn`, `issn`, `url`, `date`, `location`) and entry types for
  most of what Leader/06-07 distinguishes. It is the lossless target.
- **Classic BibTeX** is what most journal and publisher templates still
  require. It has fewer entry types and fields and expects ASCII, so the
  `marc_bibtex` output degrades where it must: non-ASCII letters with a LaTeX
  form are escaped (`é` becomes `{\'e}`, `Ł` becomes `{\L}`), and titles are
  brace-protected so styles do not lowercase proper nouns. Characters with no
  LaTeX form (most non-Latin scripts) stay UTF-8 rather than being dropped,
  which needs a Unicode-aware toolchain such as `bibtexu`.

**Export** is a pair of SQL macros composed from functions marc21 already has,
sharing one set of helpers. The planned mapping:

| MARC source | BibLaTeX (`marc_biblatex`) | BibTeX (`marc_bibtex`) |
|---|---|---|
| Leader/06-07, plus 008 where theses and reports are coded | `@book`, `@periodical`, `@article` / `@inbook` for component parts, `@thesis`, `@report`, `@online`, `@dataset`, `@software`, `@music`, `@video`, `@audio` | `@book`, `@article`, `@inbook` / `@incollection`, `@phdthesis` / `@mastersthesis`, `@techreport`; `@misc` for anything else, periodicals included |
| 100/700, split by relator `$4` / `$e` (`edt` becomes the editor) | `author`, `editor` | `author`, `editor` |
| 245 `$a`, `$b`, ISBD punctuation trimmed | `title`, `subtitle` | `title` (`Title: Subtitle`) |
| 250 `$a` | `edition` | `edition` |
| 264 _1 (falling back to 260) `$a`, `$b`, `$c`; 008/07-10 for a clean year | `location`, `publisher`, `date` | `address`, `publisher`, `year` |
| 490 `$a`, `$v` | `series`, `number` | `series`, `number` |
| 020 / 022 through `marc_isbn13` / `marc_issn` | `isbn`, `issn` | `isbn`, `issn` (not standard BibTeX fields, but printed by common styles such as `plainnat`; others ignore them) |
| 856 `$u` | `url` | `url` (as above) |
| 008/35-37, through an ISO 639-2 to babel language-name table | `langid` | `language` |
| 650 `$a` | `keywords` | `keywords` |
| citation key | still to be decided: 001, or surname plus year with a suffix to keep keys unique | same rule in both |

**Import** is the larger job. A `.bib` file needs a real parser for braces,
`@string` abbreviations, `#` concatenation and LaTeX escapes, so it would be a
C++ reader alongside `read_marc` and the others. One reader covers both
dialects: it maps either one's field names back through the table above
(`year` or `date`, `address` or `location`, `journal` or `journaltitle`) and
decodes LaTeX escapes to Unicode, so a record reads the same whichever dialect
wrote it.

Until then, the [XSLT crosswalks](XSLT.md) give an indirect path. `MARC=>RIS`
produces RIS, and `marc_mods_xml` produces MODS, which bibutils `xml2bib`
converts to `.bib`. The other direction is bibutils `bib2xml` to MODS, the
`MODS=>MARC` stylesheet, then `read_marcxml`.
