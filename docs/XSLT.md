# XSLT crosswalk library

`xslt/` holds an original set of XSLT 1.0 crosswalks for MARCXML (slim),
written for this project from the public Library of Congress mapping
specifications (see `xslt/DISTINCTNESS.md` for the originality check).
Every stylesheet accepts either a `marc:collection` or a bare
`marc:record` document element, and works with plain `xsltproc`.

| stylesheet | direction | output |
|---|---|---|
| `lib/marc-utils.xsl` | shared helpers | subfield joining, punctuation trimming, leader/008 slicing, `$6` linkage parsing, JSON escaping, ISBN-13 normalization, year extraction |
| `marc21-to-unimarc-skeleton.xsl` | MARC21 → UNIMARC-shaped MARCXML | documented subset: label, 001, 100/101, 200, 210, 215, 606 (subdivision re-lettering), 700/701 |
| `marcxml-to-dcterms.xsl` | MARCXML → qualified Dublin Core (DCMI Terms) | `qdcRecord` of `dcterms:*` (issued, extent, medium, spatial, temporal, isPartOf, tableOfContents, alternative, …) |
| `marcxml-to-ead.xsl` | MARCXML → EAD3 | collection-level `<ead>` skeleton: `control` from 001/003/008, `archdesc` did + scopecontent + controlaccess |
| `marcxml-to-html.xsl` | MARCXML → HTML | one card per record: 245 heading + tag/ind/subfield table |
| `marcxml-to-mods.xsl` | MARCXML → MODS 3.7 | `mods` / `modsCollection` |
| `marcxml-to-oai_dc.xsl` | MARCXML → simple Dublin Core | `oai_dc:dc` (collections get a neutral `dcRecords` wrapper) |
| `marcxml-to-rdfdc.xsl` | MARCXML → RDF/XML with DCMI Terms | `rdf:RDF` of `rdf:Description` |
| `marcxml-to-ris.xsl` | MARCXML → RIS | text citations: TY from leader, AU/A2/TI/T2/CY/PB/PY/SN/UR/KW/N1, ER terminator |
| `marcxml-to-schemaorg.xsl` | MARCXML → schema.org JSON-LD | NDJSON text, one object per record; same key set and `@type` table as the `marc_jsonld` SQL macro |
| `mods-to-marcxml.xsl` | MODS 3.x → MARCXML | `marc:collection` with synthesized leader + 008 |
| `oai_dc-to-marcxml.xsl` | simple Dublin Core (oai_dc) → MARCXML | `marc:collection`; leader/008 synthesized, `dc:identifier` discriminated to 020/022/856/024 |

## Usage

One-liners:

```sh
xsltproc xslt/marcxml-to-mods.xsl   records.xml > records.mods.xml
xsltproc xslt/marcxml-to-oai_dc.xsl records.xml > records.dc.xml
xsltproc xslt/marcxml-to-rdfdc.xsl  records.xml > records.rdf
xsltproc xslt/marcxml-to-html.xsl   records.xml > records.html
xsltproc xslt/mods-to-marcxml.xsl   records.mods.xml > roundtrip.xml
```

The natural pipeline with this extension: use `COPY (FORMAT marcxml)` to
get slim MARCXML out of any supported source, then transform:

```sql
-- in the duckdb shell, marc21 extension loaded
COPY (SELECT leader, fields FROM read_marc('input.mrc'))
  TO 'records.xml' (FORMAT marcxml);
```

```sh
xsltproc xslt/marcxml-to-mods.xsl records.xml > records.mods.xml
```

Because `read_marcxml()` reads slim MARCXML back in, `mods-to-marcxml.xsl`
also closes the loop for MODS sources:

```sh
xsltproc xslt/mods-to-marcxml.xsl records.mods.xml > back.xml
```
```sql
SELECT * FROM read_marcxml('back.xml');
```

Tests: `sh test/xslt/run.sh` (uses `test/data/sample.xml` and the
fixtures in `test/data/xslt/`; requires `xsltproc` and `xmllint`).

## Loading and running crosswalks

The stylesheets ship *inside* the extension. `xslt/registry.tsv` is the
catalog — one row per transform: alias, repo-relative path, source format,
target format, one-line description — and the build reads it, every
stylesheet it names, and the shared helper library into the binary. An
installed extension therefore resolves a crosswalk with no files on disk,
in a plain `LOAD marc21` session and in WASM alike.

Three functions expose it:

| function | returns |
|---|---|
| `marc_xslt_functions()` | the catalog: `alias`, `path`, `source_format`, `target_format`, `description` |
| `marc_xslt_library()` | the shared `lib/marc-utils.xsl` text every sheet includes |
| `marc_xslt_stylesheet(alias_or_path)` | the stylesheet text (NULL when the key is not registered) |

Pick a crosswalk the way a cataloger would — by what it converts:

```sql
SELECT alias, target_format, description
FROM marc_xslt_functions()
WHERE source_format = 'MARC'
ORDER BY alias;
```

| alias | stylesheet | source → target |
|---|---|---|
| `BIBFRAME2=>MARC` | `xslt/bibframe2-to-marcxml.xsl` | BIBFRAME2 → MARC |
| `MARC=>BIBFRAME2` | `xslt/marcxml-to-bibframe2.xsl` | MARC → BIBFRAME2 |
| `MARC=>DCTERMS` | `xslt/marcxml-to-dcterms.xsl` | MARC → DCTERMS |
| `MARC=>EAD3` | `xslt/marcxml-to-ead.xsl` | MARC → EAD3 |
| `MARC=>EDM` | `xslt/marcxml-to-edm.xsl` | MARC → EDM |
| `MARC=>HTML` | `xslt/marcxml-to-html.xsl` | MARC → HTML |
| `MARC=>MADS` | `xslt/marcxml-to-mads.xsl` | MARC-AUTHORITY → MADS |
| `MARC=>MODS` | `xslt/marcxml-to-mods.xsl` | MARC → MODS |
| `MARC=>OAI_DC` | `xslt/marcxml-to-oai_dc.xsl` | MARC → OAI_DC |
| `MARC=>ONIX3` | `xslt/marcxml-to-onix3.xsl` | MARC → ONIX3 |
| `MARC=>RDFDC` | `xslt/marcxml-to-rdfdc.xsl` | MARC → RDF-DC |
| `MARC=>RIS` | `xslt/marcxml-to-ris.xsl` | MARC → RIS |
| `MARC=>SCHEMA.ORG` | `xslt/marcxml-to-schemaorg.xsl` | MARC → JSON-LD |
| `MARC=>UNIMARC` | `xslt/marc21-to-unimarc.xsl` | MARC → UNIMARC |
| `MARC=>UNIMARC-SKELETON` | `xslt/marc21-to-unimarc-skeleton.xsl` | MARC → UNIMARC |
| `MODS=>MARC` | `xslt/mods-to-marcxml.xsl` | MODS → MARC |
| `OAI_DC=>MARC` | `xslt/oai_dc-to-marcxml.xsl` | OAI_DC → MARC |
| `UNIMARC=>MARC` | `xslt/unimarc-to-marc21.xsl` | UNIMARC → MARC |

An alias is matched case-insensitively; the registry path works as a key
too, so `marc_xslt_stylesheet('xslt/marcxml-to-mods.xsl')` and
`marc_xslt_stylesheet('marc=>mods')` return the same text. An unregistered
key returns NULL.

### Exporting a stylesheet and the library

The extension hands out stylesheet *text*; writing it to a file is a plain
`COPY`. A stylesheet is full of newlines and quotation marks, so the CSV
writer must be told to do nothing to it — `QUOTE ''` and `ESCAPE ''` turn
off quoting and escaping, and `HEADER false` keeps the column name out of
the file. The writer still terminates the row with a newline, so trim the
text's own final newline and let the row terminator put exactly one back:
the file is then byte-for-byte the stylesheet.

```sql
COPY (SELECT rtrim(marc_xslt_stylesheet('MARC=>MODS'), chr(10)))
  TO 'work/marcxml-to-mods.xsl' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
COPY (SELECT rtrim(marc_xslt_library(), chr(10)))
  TO 'work/lib/marc-utils.xsl'  (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
```

Every stylesheet includes the helpers as `lib/marc-utils.xsl`, so export the
library once into a `lib/` subdirectory beside the sheets and any number of
crosswalks can run from that directory. Verify a copy at any time:

```sql
SELECT content = marc_xslt_stylesheet('MARC=>MODS')
FROM read_text('work/marcxml-to-mods.xsl');
```

### The xsltproc helper

This extension does not execute XSLT — it registers, catalogs and hands out
the stylesheets, and the transform itself runs in `xsltproc`, Saxon, or a
browser (the composition rule in [ECOSYSTEM.md](ECOSYSTEM.md)).
`marc_xslt_command()` prints the command line for a registered crosswalk,
with all three paths quoted for a POSIX shell:

```sql
SELECT marc_xslt_command('MARC=>MODS', 'records.xml', 'records.mods.xml');
-- xsltproc --output 'records.mods.xml' 'marcxml-to-mods.xsl' 'records.xml'
```

The sheet is named by its bare filename — `marc_xslt_sheet_file(alias)` —
because the command is meant to run in the directory holding the exported
sheet and its `lib/`. An unknown alias yields NULL rather than a command
that would fail at the shell. A whole batch is one query:

```sql
SELECT marc_xslt_command(alias, 'records.xml', 'records.' || lower(alias) || '.out')
FROM marc_xslt_functions() WHERE source_format = 'MARC';
```

End to end, from records to MODS:

```sql
COPY (SELECT leader, fields FROM read_marc('input.mrc')) TO 'work/records.xml' (FORMAT marcxml);
```

```sh
cd work && xsltproc --output 'records.mods.xml' 'marcxml-to-mods.xsl' 'records.xml'
```

### A local registry of your own crosswalks

The shipped catalog is read-only; local stylesheets belong in a table beside
it. A macro cannot do this job: scalar macros bind when the extension loads,
and a body that named `marc_xslt_user` would fail to bind for every database
that has not created that table. So the union is a two-statement recipe, run
once per database, and it stays yours:

```sql
CREATE TABLE marc_xslt_user (
    alias         VARCHAR PRIMARY KEY,
    path          VARCHAR,       -- where the sheet lives on disk
    source_format VARCHAR,
    target_format VARCHAR,
    description   VARCHAR
);

INSERT INTO marc_xslt_user VALUES
  ('MARC=>ALMA-LOAD', '/srv/xslt/marcxml-to-alma.xsl', 'MARC', 'ALMA',
   'Local vendor load profile: 9XX stripping and 949 stamping.');

CREATE VIEW marc_xslt_all AS
    SELECT alias, path, source_format, target_format, description, 'shipped' AS origin
    FROM marc_xslt_functions()
    UNION ALL
    SELECT alias, path, source_format, target_format, description, 'local' AS origin
    FROM marc_xslt_user;
```

`marc_xslt_all` is then the one list a cataloger picks from, and
`marc_xslt_stylesheet()` still answers for the shipped half while the local
half is already a path on disk. Keep local aliases distinct from the shipped
ones (a `WHERE alias NOT IN (SELECT alias FROM marc_xslt_functions())` check
on insert is enough) so a pick is never ambiguous.

### The same catalog in a browser

Because the catalog and the stylesheet text live in the extension binary,
a browser app that loads marc21 in duckdb-wasm gets the identical list from
the identical query, with no files to fetch: `marc_xslt_functions()` fills
the crosswalk picker, `marc_xslt_stylesheet()` supplies the sheet, and the
browser's own `XSLTProcessor` runs it client-side. `xsl:include` is
resolved against the document the browser parsed, so the app either serves
`marc_xslt_library()` at the `lib/marc-utils.xsl` the sheet asks for, or
splices that text into the sheet in place of the include before importing
it.

`test/sql/marc_xslt.test` holds the registry to its promises: the catalog
against `xslt/registry.tsv` row for row, every stylesheet in the tree
registered, every alias resolving to a document, the byte-exact export and
the command shape.

## Coverage

### marcxml-to-mods.xsl (MODS 3.7)

| MARC | MODS |
|---|---|
| 001/003, 008/00-05, 040 | `recordInfo` |
| 008/35-37, 041$a | `language`/`languageTerm` (deduplicated against 008) |
| 010/020/022/024/035 | `identifier` typed; `$z` marked `invalid="yes"` |
| 050/082/084 | `classification` (lcc/ddc/`$2`) |
| 100/110/111, 700/710/711 | `name` (type + `usage="primary"` for 1XX), `namePart`, date `namePart`, roles from `$e`/`$4` |
| 130/240 | `titleInfo type="uniform"` |
| 245 (ind2 nonfiling) | `titleInfo` with `nonSort`/`title`/`subTitle`/`partNumber`/`partName`; `$c` → `note type="statement of responsibility"` |
| 246 | `titleInfo type="alternative"` (displayLabel from `$i`) |
| 260, 264 (ind2 1 publication, ind2 4 copyright), 250, 310, 008/06-14, Leader/07 | `originInfo`: place/publisher/dateIssued, `dateIssued encoding="marc"` (+start/end points for ranged 008 date types), `copyrightDate`, `edition`, `frequency`, `issuance` |
| 300, 856$q | `physicalDescription`: `extent`, `internetMediaType` |
| 440/490/800/810/811/830 | `relatedItem type="series"` |
| 520 / 505 / 521 | `abstract` / `tableOfContents` / `targetAudience` |
| 600/610/611/630/648/650/651 | structured `subject` (name/titleInfo/topic/temporal/geographic heading + `$x$y$z$v` subdivisions in order; authority from ind2 or `$2`) |
| 655 | `genre` with authority |
| 760–787 | `relatedItem` typed (773 host, 776 otherFormat, 780 preceding, 785 succeeding, …) with title, `$x$z$w` identifiers, `$g` part |
| 856$u, 852 | `location/url` (displayLabel, `usage="primary display"` for ind2 0), `physicalLocation` |
| 880 linked to 245 | paired `titleInfo` sharing `altRepGroup`; other 880s → `note type="alternate-script"` |
| Leader/06-07 | `typeOfResource` (+`collection="yes"`) |
| other 5XX | `note` (typed for 504/511/518/546/561) |

### marcxml-to-oai_dc.xsl

245/246 → `dc:title`; 1XX → `dc:creator`; 7XX → `dc:contributor`;
600–653 → `dc:subject` (subdivisions joined with `--`); 500/505/520 →
`dc:description`; 260/264$b → `dc:publisher`; imprint `$c` else
008/07-10 → `dc:date`; Leader/06-07 (DCMI vocabulary) + 655 → `dc:type`;
300$a + 856$q → `dc:format`; 001, 010/020/022/024, 856$u →
`dc:identifier`; 008/041 → `dc:language`; series + 760–787`$t` →
`dc:relation`; 651$a/650$z/752 → `dc:coverage`; 506/540 → `dc:rights`.

### marcxml-to-rdfdc.xsl

Same source fields, refined targets: `dcterms:title`/`alternative`
(includes 880-linked 245), `creator`/`contributor`, `subject` plus
`spatial` (651$a, 650$z) and `temporal` (648$a, 650$y), `abstract`,
`tableOfContents`, `description`, `publisher`, `issued`, `extent`,
`type` as an `rdf:resource` pointing into the DCMI type vocabulary,
ISBN/ISSN as `urn:` identifiers, `isPartOf` (440/490/830/773),
`replaces`/`isReplacedBy` (780/785), `accessRights`/`rights`. First
856$u becomes `rdf:about`.

### mods-to-marcxml.xsl

Reverses the core of the forward mapping: leader (type/issuance) and
40-character 008 (creation date, date1, language) are synthesized;
001/003 from `recordIdentifier`; 010/020/022 (invalid → `$z`), 050/082/084,
100/110/111/700/710/711 with `$e`/`$4` roles, 240, 245 (ind2 from
`nonSort` length, `:` before subtitle, `$c` from the statement-of-
responsibility note), 246, 250, 264 (ind2 1; `copyrightDate` → ind2 4),
041 for multilingual records, 300, 310, 490, 5XX notes (typed notes back
to 504/511/546/561), 505, 520, 521, 600/610/611/630/648/650/651 with
subdivision codes and `$2`, 655, 773 (`$x$z$w$g`), 856 (`usage` → ind2 0).

## Deviations from full LC mapping coverage (honest list)

- **Punctuation**: trailing ISBD punctuation is trimmed with a simple
  recursive rule (strip `,;:/=` runs and one final period unless it ends
  an ellipsis or single-letter initial). The LC chop rules have more
  special cases (abbreviations like "etc."); those survive here with the
  period trimmed or kept per the simple rule. The reverse direction
  regenerates only the `:` before a 245 subtitle, not full ISBD.
- **880 handling** is title-centric: only 880s linked to 245 become
  paired `titleInfo` elements with a shared `altRepGroup`; other 880s are
  preserved as `note type="alternate-script"` rather than duplicated
  `name`/`originInfo`/etc. with `script` attributes. The reverse
  transform does not reconstruct 880s.
- **Fixed-field breadth**: 008 material-specific positions (audience,
  form of item, literary form, government publication…) and 006/007 are
  not mapped to `targetAudience`/`form`/`genre`; only dates and language
  are read. The synthesized 008 on the way back fills places 15-17 with
  `xx ` and leaves material positions blank.
- **Subjects**: `$e/$4` relators inside 6XX, `$g/$3` and linkage
  subfields are ignored; 630 keeps only `$a$d$f$p`; 653 is mapped in the
  DC outputs but not in MODS (no LC-defined structured home).
- **Names**: 100 `$b` numeration is folded into the single `namePart`
  rather than split; `affiliation`, `description`, `etal` are not
  produced. The reverse maps every non-primary name to 700/710/711 (no
  720s) and cannot restore `$q` versus `$a` distinctions.
- **originInfo**: only the first 260/264-ind2-1 field is mapped in full;
  production/distribution/manufacture statements (264 ind2 0/2/3) are
  not emitted (the copyright 264 ind2 4 is). `place` carries only the
  text form, no `code` placeTerm from 008/15-17.
- **relatedItem**: linking entries carry title, ISSN/ISBN/`$w` control
  numbers and `$g` parts only — no full name/originInfo sub-records; 490
  loses `$v` numbering on the way back (it returns as part of the title
  string when present in the MODS title).
- **Round-trip fidelity** is asserted for the core fields exercised in
  `test/xslt/run.sh` (titles, names, imprints, subjects, identifiers,
  series/host links, notes); a full MARC → MODS → MARC pass is lossy by
  design — MODS itself does not keep every MARC distinction.
- **DC outputs**: `dcRecords` (oai_dc collection wrapper) is a
  convenience element in no namespace; single records are schema-valid
  `oai_dc:dc`. In the RDF output, literals are untyped and agents are
  plain labels, not structured `foaf:Agent` nodes.

Every stylesheet lives directly in `xslt/`, including the shared
`marc-utils.xsl` each one includes — a flat directory, so exporting a sheet
and its library means copying two files into one place. Two groups have
their own documentation and their own runner under `test/xslt/`: BIBFRAME
2.x in both directions ([BIBFRAME.md](BIBFRAME.md)), and the international
set — field-level UNIMARC both ways, the national formats, ONIX 3,
Europeana EDM, MADS ([INTERNATIONAL.md](INTERNATIONAL.md)).
