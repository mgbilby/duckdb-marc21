# International interoperability — the standards map

What this extension speaks, at three levels of support:

* **built-in** — the extension reads and/or writes it directly (C++ readers
  and writers, SQL macros bundled in the extension);
* **by crosswalk** — a conversion ships with the repository (an XSLT
  stylesheet under `xslt/`, or a macro that renders the target format) and
  is exercised by the test suite;
* **by documented pattern** — a written, tested procedure using external
  tooling; nothing in this repository executes it for you.

Every crosswalk here is an *honest subset*: its header comment states
exactly what converts and what is deliberately dropped, so the output never
claims more than the input said.

## Standards matrix

| standard | support | via | notes |
|---|---|---|---|
| BIBFRAME 2.x | by crosswalk | see `xslt/` | RDF/XML output; the DuckDB community `rdf` extension can be loaded alongside to query it as a graph |
| CMARC (Taiwan) | structural reading built-in; UNIMARC-shaped core by crosswalk | `read_marc(..., encoding := 'utf8')` + the UNIMARC pair | no CMARC delta ships — the Chinese classification and the 9XX locals are the known gaps; see below |
| Dublin Core / DCTERMS | by crosswalk | `marc_dublin_core` macro; `xslt/marcxml-to-oai_dc.xsl`, `xslt/marcxml-to-rdfdc.xsl` and companions in `xslt/` | |
| EAD (3) | by crosswalk | see the `xslt/` crosswalk set | archival description |
| EDM (Europeana) | by crosswalk | `xslt/marcxml-to-edm.xsl` | RDF/XML; `edm:ProvidedCHO` + `ore:Aggregation`; the DuckDB community `rdf` extension can be loaded alongside to query the output as a graph |
| IBERMARC (Spain, retired) | by crosswalk | `xslt/ibermarc-to-marc21.xsl` | legacy migration: 017→016, 59X kept, leader/09 set to `a`, the rest copied in tag order |
| INTERMARC (BnF) | structural reading built-in; field-level by crosswalk | `read_marc(..., encoding := 'utf8')` + `xslt/intermarc-to-marc21.xsl` / `marc21-to-intermarc.xsl` | honest subset: headings with BnF function codes, titles, 260/280, 3XX notes, RAMEAU 6XX; no coded data — see below |
| ISO 2709 | built-in | `read_marc`, `read_marc_raw` | any ISO 2709 file parses structurally, whatever dialect assigned the tag meanings |
| JAPAN/MARC MARC21 (NDL) | built-in (it is MARC 21); NDL reading conventions by crosswalk | `read_marc(..., encoding := 'utf8')` + `xslt/japanmarc-normalize.xsl` | maps the yomi and parallel-script practices onto standard 880/`$6` linkage; changes linkage, never content |
| KORMARC (Korea, KS X 6006) | structural reading built-in; local fields by crosswalk | `read_marc` + `xslt/kormarc-to-marc21.xsl` / `marc21-to-kormarc.xsl` | MARC 21-structured already; the crosswalk handles 056 KDC ↔ 084 `$2 kdc`, 049/052/090 ↔ 852, 940 ↔ 246, 950 ↔ 037 `$c` |
| MAB2 (Germany/Austria, retired) | by crosswalk | `xslt/mab2-to-marc21.xsl` | legacy migration of the bibliographic core; expects MARC 21 slim-shaped input and does not interpret the MAB2 label — see below |
| MADS 2.x | by crosswalk | `xslt/marcxml-to-mads.xsl` | authority records (leader/06 = z) |
| MARC 21 (bib, auth, holdings) | built-in | `read_marc*`, `COPY (FORMAT marc/marcxml/mrk/marcjson)`, validation rulepacks | the home format; see [REFERENCE.md](REFERENCE.md) |
| MARC-in-JSON | built-in | `read_marcjson`, `COPY (FORMAT marcjson)`, `marc_parse_json` | object, array, NDJSON, FOLIO SRS envelopes |
| MARCXML (slim) | built-in | `read_marcxml`, `COPY (FORMAT marcxml)` | SRU/OAI envelopes handled |
| MODS 3.x | by crosswalk | `marc_mods_xml` macro; `xslt/marcxml-to-mods.xsl` and `xslt/mods-to-marcxml.xsl` (round trip) | |
| ONIX for Books 3.x | by crosswalk | `xslt/marcxml-to-onix3.xsl` | trade Product records, reference tags; honest subset (no supply-chain blocks) |
| RIS | by crosswalk | see the `xslt/` crosswalk set | citation-manager export |
| RUSMARC (Russia) | structural reading built-in; field-level by crosswalk | `read_marc(..., encoding := 'utf8')` + `xslt/rusmarc-to-marc21.xsl` / `marc21-to-rusmarc.xsl` (delta layers over the UNIMARC pair) | 686 BBK ↔ 084 `$2 rubbk`, 802 ↔ 022 `$2`, 801 source conventions, 9XX carried through; see below |
| schema.org | built-in | `marc_jsonld` macro (JSON-LD) | see the `xslt/` set for an XML-side rendering |
| UNIMARC | structural reading built-in; field-level by crosswalk | `read_marc(..., encoding := 'utf8')` + `xslt/unimarc-to-marc21.xsl` / `marc21-to-unimarc.xsl`; `marc_unimarc_label` / `marc_from_unimarc_label` | scope and caveats: [UNIMARC.md](UNIMARC.md) and below |

Pipeline shape for every XSLT crosswalk:

```sql
COPY (SELECT leader, fields FROM read_marc('bibs.mrc'))
TO 'bibs.xml' (FORMAT marcxml);
```

```sh
xsltproc xslt/marcxml-to-onix3.xsl bibs.xml > products.onx
xsltproc --stringparam data-provider "My Library" \
         --stringparam provider "My Aggregator" \
         --stringparam rights "http://creativecommons.org/publicdomain/zero/1.0/" \
         xslt/marcxml-to-edm.xsl bibs.xml > bibs.edm.rdf
```

## UNIMARC, in full

Three layers, each documented where it lives:

1. **Structure** — UNIMARC is ISO 2709, so `read_marc` parses it; always
   pass `encoding := 'utf8'` (UNIMARC declares its character sets in
   100 $a/26-29, not in leader/09). [UNIMARC.md](UNIMARC.md) is the honest
   map of which MARC 21 helpers do and do not apply.
2. **Record label** — `marc_unimarc_label(leader)` and
   `marc_from_unimarc_label(label)` convert between the MARC 21 leader and
   the UNIMARC record label (type-of-record, bibliographic level, encoding
   level and cataloguing-form codes all remapped; see
   `src/macros/international.sql` for the position table).
3. **Fields** — `xslt/unimarc-to-marc21.xsl` and
   `xslt/marc21-to-unimarc.xsl` convert field content in both
   directions, written from the IFLA *UNIMARC Manual: Bibliographic
   Format* and the IFLA/LC alignment documentation. Coverage includes
   010/011↔020/022, 100 $a↔008 fixed data, 101↔041+008, 102↔008/15-17
   (+044), the 2XX description block↔245/250/260/264/300/490, 3XX
   notes↔5XX, 4XX linking↔76X-78X (standard-subfield technique), 6XX
   subjects (including the $y/$z geographic/chronological swap), 675/676/
   680↔080/082/050, 70X/71X↔1XX/7XX names (entry element $b split/join),
   801↔040, 856↔856. Each stylesheet's header states the exclusions —
   notably the embedded-field `$1` linking technique and non-sorting
   NSB/NSE characters.

Round-trip fidelity for the core fields (245/100/020/650, 008 language)
is asserted by `test/xslt/intl/run.sh`.

**Both sheets are built to be extended.** Each emits its record body from
named block templates — `iu-leader`, `iu-controlfields`, `iu-008`,
`iu-identifiers`, `iu-source`, `iu-classification`, `iu-main-entry`,
`iu-title-block`, `iu-notes`, `iu-subjects`, `iu-added-entries`,
`iu-linking-block`, `iu-electronic` going one way, and `mu2-label`,
`mu2-identifiers`, `mu2-coded`, `mu2-description`, `mu2-notes`,
`mu2-linking-block`, `mu2-subjects`, `mu2-classification`,
`mu2-responsibility`, `mu2-source`, `mu2-electronic` going the other —
plus an empty `iu-national` / `mu2-national` hook called last, and two
finer hooks (`iu-008-18-34` for the uncoded 008 positions, `iu-022-tail`
for extra subfields on the generated 022). A crosswalk for a
UNIMARC-derived national format therefore does not restate any of this:
it `xsl:import`s the sheet — import, not include, because XSLT 1.0 gives
the importing stylesheet the higher precedence that overriding needs —
and redefines only the blocks that differ. `rusmarc-to-marc21.xsl` and
`marc21-to-rusmarc.xsl` are worked examples. One consequence worth
knowing: a delta sheet resolves its `xsl:import` relative to itself, so
the imported UNIMARC sheet has to sit in the same directory — exporting a
delta on its own leaves it unable to run.

## National MARC dialects

The recurring pattern: a national format is ISO 2709 at the bottom (so
`read_marc`/`read_marc_raw` parse the *structure* today), a tag semantic
layer in the middle (which only a dialect-aware crosswalk understands),
and a character-encoding history at the edges (which may need external
conversion before ingest). Per dialect:

Every sheet named below is in the shipped crosswalk catalog, so it can be
fetched by alias rather than by path — `RUSMARC=>MARC`, `MARC=>RUSMARC`,
`KORMARC=>MARC`, `MARC=>KORMARC`, `INTERMARC=>MARC`, `MARC=>INTERMARC`,
`JAPANMARC=>MARC`, `IBERMARC=>MARC`, `MAB2=>MARC`:

```sql
SELECT marc_xslt_stylesheet('RUSMARC=>MARC');
```

### RUSMARC (Russia)

* **ISO 2709 relationship**: RUSMARC is the Russian adaptation of UNIMARC —
  same record label, same block structure, same core field semantics.
  `read_marc(..., encoding := 'utf8')` parses it, and
  `marc_unimarc_label` reads its label.
* **Conversion path**: `xslt/rusmarc-to-marc21.xsl` and
  `xslt/marc21-to-rusmarc.xsl`. Both are *delta layers*: they
  `xsl:import` the UNIMARC pair and override or extend only the Russian
  specifics, so every UNIMARC mapping listed above applies unchanged.
  What the delta adds: 686 (BBK and other national classification indexes)
  ↔ 084 with the system code carried in `$2` (`rubbk` for the
  Library-Bibliographical Classification); 802 ISSN centre code ↔ 022
  `$2`; the 801 source conventions (`$a` country, `$b` agency such as
  RuMoRGB, `$c` date, `$g` cataloguing rules such as `psbo`, reaching
  040 `$a`/`$c`/`$d`/`$e`); the 100 `$a` coded positions RUSMARC fills and
  the imported sheet leaves uncoded (target audience /17-19 → 008/22,
  government publication /20 → 008/28); and the 9XX national/local block,
  copied through verbatim in both directions because MARC 21 reserves 9XX
  for local use too.
* **Not supported**: 686 `$b` base-index semantics (emitted as a further
  084 `$a`), 100 `$a`/21 record modification, and any RUSMARC-only reading
  of 9XX — those fields survive but stay untyped. Legacy Cyrillic
  encodings must be converted to UTF-8 before ingest.

### INTERMARC (Bibliothèque nationale de France)

* **ISO 2709 relationship**: INTERMARC is ISO 2709-based; `read_marc`
  parses records structurally. But its blocks follow their own logic —
  1XX is the block of *main headings* (100 the first personal-author
  heading, 145 the conventional title), not coded data — and several of
  its zone numbers collide with MARC 21's: the physical description is in
  280, the general note in 300 (physical description in MARC 21), the
  language note in 302. Structural reading alone therefore misreads an
  INTERMARC record even where the tags look familiar.
* **Conversion path, one**: `xslt/intermarc-to-marc21.xsl` (and
  `marc21-to-intermarc.xsl` for the return trip). Covered subset: record
  label → leader; 001/005; 020 ISBN; 100/700 personal and 110/710
  corporate headings with the BnF numeric function codes in `$4` mapped to
  MARC 21 relator codes (0070 aut, 0205 ctb, 0220 com, 0230 cmp, 0340 edt,
  0440 ill, 0600 pht, 0730 trl); 145 → 240; 245 (shape-tolerant: MARC 21's
  own 245 subfield codes pass through, the French-family `$e`/`$f`/`$h`/`$i`
  convert); 260 → 264; 280 → 300; 300 → 500, 302 → 546, 310 → 506, other
  3XX → 500; and the RAMEAU 6XX block (600/601/605/606/607 →
  600/610/630/650/651, ind2 7 with `$2 rameau`).
* **Conversion path, two**: the BnF also publishes its catalogue in
  UNIMARC, converted from INTERMARC by the BnF itself. Where full fidelity
  matters, request UNIMARC, read with `encoding := 'utf8'` and apply
  `xslt/unimarc-to-marc21.xsl` — that route covers more than the
  subset above.
* **Not supported**: INTERMARC coded data (no 008 is generated — an 008
  invented from nothing would be a lie), the 4XX and 8XX blocks, the
  authority model, and any zone whose subfield table the BnF documentation
  could not be read for. Those are dropped, not guessed at.

### danMARC2 (Denmark)

* **ISO 2709 relationship**: danMARC2 exchange records are ISO 2709 with
  danMARC2's own field semantics; `read_marc` parses them and tag-level
  reports/editing work. The common *line format* (`*a`-style subfield
  markers in text) is not ISO 2709 and is not read.
* **Conversion path**: the Danish bibliographic infrastructure (DBC)
  maintains the authoritative danMARC2→MARC 21 mapping used for
  international exchange (e.g. WorldCat delivery); request MARC 21 from
  the source when possible. There is no danMARC2 crosswalk here — its 245
  and name-field subfield conventions differ from MARC 21 despite the
  familiar-looking tags, so MARC 21 semantic helpers will quietly misread
  them.
* **Not supported**: danMARC2 field semantics; the line format; Danish
  local character-set history (modern exports are UTF-8 — pass
  `encoding := 'utf8'`).

### KORMARC (Korea, KS X 6006)

* **ISO 2709 relationship**: KORMARC is deliberately MARC 21-structured —
  the standard tracks MARC 21's leader, tags and indicators, adding Korean
  requirements (local fields such as 049, Korean-specific coded values,
  script conventions). KORMARC files are **largely readable as-is**:
  `read_marc` parses them, and MARC 21 helpers give correct answers for
  the shared tags (245 is a title, 700 is an added entry).
* **Conversion path**: often none needed for analytics. When the local
  fields have to mean something to a MARC 21 consumer, apply
  `xslt/kormarc-to-marc21.xsl` (and `marc21-to-kormarc.xsl` for the
  return trip). Because the shared tags are already MARC 21, the sheets are
  a delta, not a translation: everything they do not name is copied
  through in tag order. What they do name — 056 한국십진분류기호 ↔ 084 with
  `$2 kdc`; 049 소장사항 and the 090/052 call numbers ↔ 852 (registration
  number in `$p`, separate location in `$c`, volume in `$3`, copy in `$t`,
  call number in `$h`/`$i`); 940 로컬표목-표제 → 246 ind1 3; 950
  로컬정보-가격 ↔ 037 `$c`; 008/15-17 and /35-37 filled with the Korean
  codes when the incoming record leaves them uncoded (parameters
  `country`, `language`); and a Hangul or Hanja title proper forcing 245
  ind2 to 0, since such a title cannot carry a leading article.
* **Watch the 052 collision**: KORMARC 052 is the National Library of Korea
  call number, MARC 21 052 is Geographic Classification. Reading KORMARC as
  MARC 21 *without* the crosswalk silently misreads that field; the
  crosswalk moves it into 852.
* **Not supported**: the KDC edition number 056 can carry, the 049 first
  indicator, and library-specific 09X/9XX conventions — those fields
  survive but stay untyped. No KORMARC rulepack ships here.

### CMARC (Taiwan)

* **ISO 2709 relationship**: CMARC (中國機讀編目格式, National Central
  Library, Taiwan) is UNIMARC-derived, and the NCL maintains it to stay
  structurally compatible with UNIMARC. `read_marc(..., encoding :=
  'utf8')` parses it, and `marc_unimarc_label` reads its record label.
* **Which UNIMARC-pair templates apply.** The whole of
  `xslt/unimarc-to-marc21.xsl` applies to the UNIMARC-shaped core —
  in the named-block terms the sheet is now written in: `iu-leader`
  (record label), `iu-controlfields` and `iu-008` (100 `$a` general
  processing data, 101 language, 102 country), `iu-identifiers`
  (010/011), `iu-source` (801→040, 041, 044), `iu-classification`
  (675/676/680), `iu-main-entry` and `iu-added-entries` (70X/71X),
  `iu-title-block` (200/205/210/214/215/225), `iu-notes` (3XX),
  `iu-subjects` (600/601/606/607), `iu-linking-block` (4XX) and
  `iu-electronic` (856). `xslt/marc21-to-unimarc.xsl` applies the
  same way in reverse.
* **Known divergences**, i.e. what the UNIMARC pair does *not* carry:
  1. **The Chinese classification.** CMARC records classify with 中國圖書
     分類法 (the New Classification Scheme for Chinese Libraries), which
     the UNIMARC crosswalk's `iu-classification` block does not know: it
     maps 675 UDC, 676 DDC and 680 LCC only. A Chinese class number
     travels in whichever field the cataloguing agency put it in and is
     dropped by the crosswalk.
  2. **The 9XX national and local block**, which UNIMARC reserves for
     national use and the crosswalk drops. The pattern for keeping it is
     in `xslt/rusmarc-to-marc21.xsl`: a delta layer overrides
     `iu-national` and copies 9XX through untyped.
  3. **Script and romanization conventions** (parallel Chinese/pinyin
     forms), which the crosswalk carries as written but does not link:
     `xslt/japanmarc-normalize.xsl` is script-agnostic and will
     repair 880/`$6` linkage in a CMARC-derived record too.
  4. **Legacy encodings** of the Big5 and CCCII lineages — convert to
     UTF-8 externally before ingest.
* **No CMARC delta sheet ships here.** The two mappings a delta would need
  — which field carries the Chinese class number, and what the CMARC-only
  9XX fields mean — are exactly the ones the NCL's tag-level documentation
  would have to settle, and that documentation could not be read from this
  environment (the egress policy refuses the host). A delta written on a
  guess would be worse than none: the UNIMARC pair converts the core
  correctly today, and the fields above survive structural reading, so
  they stay queryable from the source table.

### CNMARC (China)

* **ISO 2709 relationship**: CNMARC (National Library of China) is
  UNIMARC-derived: the record label, block structure and core bibliographic
  fields (010, 100, 101, 200, 210, 215, 606, 690, 7XX, 801) follow the
  UNIMARC pattern. **The UNIMARC crosswalk therefore covers CNMARC's
  structure and core fields.** Where CNMARC diverges: Chinese-specific
  local fields (9XX block), the Chinese Library Classification in 690
  (not mapped — UNIMARC 675/676/680 are UDC/DDC/LCC), pinyin/script
  conventions, and Chinese subject-source codes in `$2`.
* **Conversion path**: convert the encoding first if needed (legacy GB
  2312/GBK — external conversion; modern exports are UTF-8), read with
  `encoding := 'utf8'`, apply `xslt/unimarc-to-marc21.xsl`; expect
  690 and 9XX to be dropped by the crosswalk (they survive structural
  reading, so keep them queryable from the source table).
* **Not supported**: CLC classification mapping, 9XX locals, legacy
  encodings. The shape a CNMARC delta would take is the one
  `xslt/rusmarc-to-marc21.xsl` demonstrates — import the UNIMARC
  sheet, override `iu-national` for the Chinese classification field and
  the 9XX block — but it needs the National Library of China's tag-level
  documentation to be written honestly, so none ships.

### Migrated-away legacy formats

* **UKMARC** (British Library, retired 2004): ISO 2709 — old files parse
  structurally, but UKMARC's subfield conventions differ from MARC 21 in
  the description fields. The realistic path is not conversion but
  re-supply: the BL has been MARC 21 since 2004 and provides current
  records for its catalog. No UKMARC crosswalk ships here.
* **IBERMARC** (Spain, retired): IBERMARC is MARC-family, so its
  designators are MARC 21's except where the BNE's comparison tables say
  otherwise. `xslt/ibermarc-to-marc21.xsl` migrates a legacy file:
  it zeroes the leader lengths and sets leader/09 to `a` (the pipeline that
  read the file is UTF-8, whatever the tape was), moves the 017 control
  number to MARC 21's 016, keeps the 59X block the BNE retained as local
  fields, and copies everything else through in tag order. Designators
  MARC 21 no longer defines are copied through with their original tag
  rather than re-tagged, so a validator flags them and a human decides —
  the crosswalk invents no meaning. The better path where it exists is
  re-supply: the BNE catalogues in and supplies MARC 21.
* **MAB2** (Germany/Austria, retired): MAB2's exchange form
  is ISO 2709-*flavored* but with different conventions (single-character
  indicator, largely subfield-less fields), and it also circulates as
  MABxml. `xslt/mab2-to-marc21.xsl` migrates the bibliographic core —
  001, 002 (into 008/00-05), 025→035, 100/104/108→100/700,
  200/204/208→110/710, 331/335/359→245, 403→250, 410/412/425→264,
  433/434/435→300, 451/455→490, 501→500, 540→020, 542→022, 700→084 and the
  902-937 Schlagwort chain→650 `$2 swd`. Two things to know before running
  it: it expects **MARC 21 slim-shaped input** (read the ISO 2709 file with
  `read_marc(..., encoding := 'utf8')` and write it with
  `COPY (FORMAT marcxml)`, which leaves each MAB2 field number as a
  `datafield` tag — a MABxml file has to be brought into that shape
  first), and it does **not** interpret the MAB2 record label, so every
  record comes out as leader type `a`, bibliographic level `m`: a file of
  serials needs leader/07 and 008 re-coded afterwards. Everything else,
  including the coded fields and the local segment, is dropped rather than
  guessed at. Where the records can be re-obtained, the DNB and the
  German-speaking networks deliver MARC 21.
* **JAPAN/MARC** (National Diet Library): the JAPAN/MARC MARC21 format *is*
  MARC 21 — NDL data in UTF-8 reads directly, and no crosswalk is needed
  for it. What differs is a set of NDL practices around readings (ヨミ) and
  parallel script, and `xslt/japanmarc-normalize.xsl` expresses those
  as standard MARC 21 880/`$6` linkage: it pairs each 880 with its field,
  gives the pair one occurrence number (so a katakana reading and a romaji
  reading of the same title share it and differ only by script code),
  writes the reciprocal `$6 880-NN` into the regular field, keeps or
  derives the script identification code (`$1` for a kana or kanji form,
  `(B` for a romaji one), repeats the linked field's indicators on the 880,
  and leaves 880s marked occurrence 00 unpaired. It changes linkage, never
  content: no reading is generated, romanized or corrected, and the leader,
  control fields and unpaired fields are copied through untouched. Records
  from before the format change are UNIMARC-shaped: read structurally and
  apply the UNIMARC crosswalk for the core, with the same honesty caveats
  as CNMARC (JIS-lineage legacy encodings need external conversion).

## RDA and ISBD: content rules vs. carrier formats

RDA and ISBD are *content* standards — they say what to record and (for
ISBD) how to punctuate its display — while everything above is a *carrier*
format. A MARC 21, UNIMARC or BIBFRAME record can each carry RDA-compliant
or pre-RDA data. What the extension provides on this axis:

| function | returns |
|---|---|
| `marc_264_from_260(fields)` | RDA: fields with an RDA 264 _1/_4 pair generated from a 260, in place — the imprint upgrade |
| `marc_generate_33x(leader, fields)` | RDA: fields plus the 336/337/338 content, media and carrier types derived from the leader |
| `marc_isbd(leader, fields)` | ISBD: one record as a single ISBD-punctuated display string (areas 1, 2, 4, 5, 6, 8 with the prescribed `. — ` area separator and internal ` : `, ` / `, `, ` and ` ; ` marks), degrading gracefully on sparse records. A display builder, not a validator: it re-applies prescribed punctuation from the subfield structure and strips whatever terminal punctuation was already transcribed |
| `marc_rda_check(leader, fields)` | RDA: the AACR2-era issues in one record — GMDs, missing 33X, 260-only imprints, abbreviations, missing relators |
| `marc_rda_expand(fields)` | RDA: fields with AACR2 abbreviations rewritten to RDA transcribed forms |

Worked RDA cleanup: [RECIPES.md](RECIPES.md) §7.

## Provenance

Every crosswalk here was written from the target format's own published
documentation and the MARC 21 format on the other side; no other project's
conversion code or stylesheets were consulted. Per sheet, the specification
used and what could not be reached from the environment the sheet was
written in (an egress policy refuses many national library hosts) — each
stylesheet's header carries the same statement in full:

| sheet | written from | reachability |
|---|---|---|
| `ibermarc-to-marc21.xsl` | BNE *Tablas de conversión de IBERMARC a MARC 21* / *Tablas de comparación IBERMARC-MARC 21* (BNE and the Grupo de Trabajo MARC 21 of the Consejo de Cooperación Bibliotecaria); MARC 21 on the other side | the BNE host (`bne.es`) is refused by this environment's egress policy, so the tables could not be read field by field: the sheet acts only on what their published description states (IBERMARC is MARC-family, 017 is carried by 016, the 59X block was kept as local fields) and copies the rest through |
| `intermarc-to-marc21.xsl`, `marc21-to-intermarc.xsl` | BnF *Format INTERMARC de diffusion* and *INTERMARC bibliographique de diffusion*, the BnF cataloguing manual (Kitcat) for the zone definitions, and the BnF's INTERMARC/UNIMARC correspondence; MARC 21 on the other side | the BnF hosts (`bnf.fr`, `kitcat.bnf.fr`) are refused by this environment's egress policy, so the zone-level PDFs could not be read: the sheets cover the zones the published documentation states explicitly, use shape-tolerant rules for 245 and 260, and drop the rest rather than guessing |
| `japanmarc-normalize.xsl` | NDL *JAPAN/MARC MARC21フォーマット マニュアル* and the NDL 文字・読みの基準 (character and reading standards) for the reading conventions; MARC 21 Appendix A (control subfields) for the `$6` linkage and script identification codes | the NDL host (`ndl.go.jp`) is refused by this environment's egress policy, so the manual PDFs could not be read: the sheet implements the conventions the NDL's published format documentation states — a reading in a paired 880, `$6` as tag-occurrence/script, `$1` for kana and `(B` for romaji, indicators repeated from the linked field |
| `kormarc-to-marc21.xsl`, `marc21-to-kormarc.xsl` | published KORMARC documentation (한국문헌자동화목록형식, KS X 6006, National Library of Korea) for 049, 052, 056, 090, 940, 950 and the 9XX local block; MARC 21 for everything shared | the NLK field pages (`librarian.nl.go.kr`) are refused by this environment's egress policy, so the KORMARC side rests on the format's published field list rather than on a fetched copy of the standard |
| `mab2-to-marc21.xsl` | the DNB-published *Konkordanz MAB2 - MARC 21, Teil 1* and the MAB2 field directory (MAB2, 2. Ausgabe with supplements, DNB); MARC 21 on the other side | the DNB and network hosts are refused by this environment's egress policy, so the concordance could not be read line by line: every mapped field rests on the published MAB2 field directory, and fields whose identity could not be confirmed there are dropped rather than guessed at |
| `rusmarc-to-marc21.xsl`, `marc21-to-rusmarc.xsl` | published RUSMARC format documentation (National RUSMARC Development Service / Russian National Library) for 686 `$2`, 801, 802, the 9XX block and the 100 `$a` positions; MARC 21 on the other side; UNIMARC semantics inherited from the imported pair | the RUSMARC servers (`rusmarc.info`, `rusmarc.ru`, `nlr.ru`) are refused by this environment's egress policy, so the RUSMARC side rests on the format's published field list rather than on a fetched copy of the manual |
| `unimarc-to-marc21.xsl`, `marc21-to-unimarc.xsl` | IFLA *UNIMARC Manual: Bibliographic Format* (CC BY 4.0); LC UNIMARC↔MARC 21 conversion specifications | — |

## Sources

Specifications referenced (none reproduced) in the crosswalks and macros:

* *MARC 21 Format for Bibliographic/Authority/Holdings Data*, Library of
  Congress — <https://www.loc.gov/marc/>
* *ISO 2709:2008 — Format for information exchange*, ISO
* *MARCXML*, Library of Congress — <https://www.loc.gov/standards/marcxml/>
* *MARC-in-JSON* as implemented by pymarc/marc4j and FOLIO SRS
* *UNIMARC Manual: Bibliographic Format* (3rd ed. updated), IFLA — CC BY
  4.0 — <https://www.ifla.org/publications/unimarc-formats-and-related-documentation/>
* *UNIMARC to MARC 21 / MARC 21 to UNIMARC Conversion Specifications*,
  Library of Congress, Network Development and MARC Standards Office —
  <https://www.loc.gov/marc/unimarctomarc21.html>
* *ISBD: International Standard Bibliographic Description, Consolidated
  Edition*, IFLA — CC BY 4.0 — <https://www.ifla.org/references/best-practice-for-national-bibliographic-agencies-in-a-digital-age/resource-description-and-standards/isbd/>
* *BIBFRAME 2.x*, Library of Congress — <https://www.loc.gov/bibframe/>
* *MODS* and *MADS*, Library of Congress — <https://www.loc.gov/standards/mods/>,
  <https://www.loc.gov/standards/mads/> (LC standards documents, public domain)
* *DCMI Metadata Terms*, Dublin Core Metadata Initiative —
  <https://www.dublincore.org/specifications/dublin-core/dcmi-terms/>
* *EAD3*, Library of Congress / Society of American Archivists —
  <https://www.loc.gov/ead/>
* *ONIX for Books 3.x* and code lists, EDItEUR —
  <https://www.editeur.org/93/Release-3.0-Downloads/>
* *Definition of the Europeana Data Model* and *EDM Mapping Guidelines*,
  Europeana Foundation — <https://pro.europeana.eu/page/edm-documentation>
* *schema.org* vocabulary — <https://schema.org/>
* *RIS format*, Clarivate (EndNote documentation)
* *KORMARC*, KS X 6006, National Library of Korea —
  <https://www.nl.go.kr/>
* *danMARC2*, Danish Agency for Culture and Palaces —
  <https://kat-format.dk/danMARC2/>
* *INTERMARC*, Bibliothèque nationale de France —
  <https://www.bnf.fr/fr/intermarc-format-bibliographique>
* *RUSMARC* (Российский коммуникативный формат представления
  библиографических данных), National RUSMARC Development Service /
  Russian National Library — <http://www.rusmarc.info/>,
  <https://nlr.ru/rusmarc>
* *CNMARC*, National Library of China
* *Chinese MARC (CMARC)*, National Central Library, Taiwan
* *UKMARC* (historical), British Library
* *MAB2* (historical) and the *Konkordanz MAB2 — MARC 21*, Deutsche
  Nationalbibliothek — <https://www.dnb.de/>
* *IBERMARC* (historical) and the *Tablas de conversión de IBERMARC a
  MARC 21*, Biblioteca Nacional de España — <https://www.bne.es/>
* *JAPAN/MARC MARC21 Format*, National Diet Library —
  <https://www.ndl.go.jp/en/data/data_service/jnb/>

**Attribution.** The UNIMARC crosswalks and the ISBD display macro were
written from IFLA publications, which IFLA licenses under CC BY 4.0
(*UNIMARC Manual: Bibliographic Format*, IFLA; *ISBD Consolidated
Edition*, IFLA). The stylesheet and macro headers carry this attribution;
the repository NOTICE file should carry it as well.
