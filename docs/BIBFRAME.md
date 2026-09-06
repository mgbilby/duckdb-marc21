# BIBFRAME 2 compatibility

Two symmetrical XSLT 1.0 crosswalks in `xslt/` and one SQL macro
turn MARC 21 bibliographic records into BIBFRAME 2.x descriptions (and, for
the crosswalks' own output, back again):

| piece | direction | output |
|---|---|---|
| `marc_bibframe_jsonld(leader, fields)` | in SQL | one JSON-LD text per record, two-node `@graph` (Work + Instance) |
| `xslt/bibframe2-to-marcxml.xsl` | BIBFRAME 2 → MARCXML | `collection` of records, for the forward stylesheet's own subset |
| `xslt/marcxml-to-bibframe2.xsl` | MARCXML → BIBFRAME 2 | `rdf:RDF` of sibling `bf:Work` / `bf:Instance` (/ `bf:Item`) resources |

All three are original, compact implementations. The **mapping semantics**
are derived from public-domain U.S. government sources — the Library of
Congress BIBFRAME 2 ontology (`id.loc.gov/ontologies/bibframe`), the
id.loc.gov value vocabularies, and the documented conversion logic of LC's
`marc2bibframe2` and `bibframe2marc` converter projects — but none of the
LC converter code (some 200 stylesheets and a large rule compiler) is
vendored or ported wholesale. Where LC's converters are exhaustive, these
are deliberately a well-tested core subset.

## The model

BIBFRAME splits a MARC bibliographic record into linked resources:

- **Work** — the conceptual entity: creators, subjects, language,
  classification, content type.
- **Instance** — the published embodiment: title as issued, publication
  statement, identifiers, extent, media/carrier, online access.
- **Item** — a held copy: location and shelf mark.

Choices made here (matching `marc2bibframe2` practice unless noted):

- One Work and one Instance per record, always; an Item only when the
  record carries an 852. Multiple 852s collapse to one Item (first wins).
- The 245 title is emitted on **both** Work and Instance, as LC's
  converter does; `bf:responsibilityStatement` (245$c) is Instance-only.
- 336/337/338 split across the model: content (336) is a Work property,
  media (337) and carrier (338) are Instance properties.
- URIs: the XSLT mints `{$baseuri}{001}#Work|#Instance|#Item` from the
  `baseuri` stylesheet parameter (default `http://example.org/`), falling
  back to `generate-id()` when there is no 001. The SQL macro emits
  relative `{001}#work` / `{001}#instance` ids (stem `record` without a
  001) — resolve them against whatever base your consumer chooses.
- The 001 is preserved as a `bf:Local` identifier under
  `bf:adminMetadata`, which is what lets the reverse crosswalk restore it.

## Coverage contract

What maps (identically in the XSLT and the macro unless noted):

| MARC | BIBFRAME |
|---|---|
| 008/35-37 | `bf:language` as `id.loc.gov/vocabulary/languages/{code}` (only when three lowercase letters) |
| 020 / 022 / 010 / 035 | `bf:identifiedBy` → `bf:Isbn` / `bf:Issn` / `bf:Lccn` / `bf:OclcNumber` (`rdf:value`). The macro normalizes through `marc_isbn13` / `marc_issn` / `marc_lccn` / `marc_oclc` (raw value as fallback) and only maps `(OCoLC)`-prefixed 035s; the XSLT keeps values as transcribed |
| 050 / 082 | `bf:ClassificationLcc` ($a portion, $b item portion) / `bf:ClassificationDdc` ($a) |
| 1XX / 7XX (X00/X10/X11) | `bf:Contribution`; agent class `bf:Person` / `bf:Organization` / `bf:Meeting` from the tag, label from $a$b$c$d$q; role from each $4 as an `id.loc.gov/vocabulary/relators/` URI, else $e as a `bf:Role` label; 1XX additionally typed `bflc:PrimaryContribution` (the macro takes the first $4 or $e only) |
| 245 $a $b | `bf:Title` with `bf:mainTitle` / `bf:subtitle`, trailing ISBD `/ : ; ,` stripped |
| 245 $c | Instance `bf:responsibilityStatement` |
| 260 / 264 | `bf:provisionActivity` → `bf:Publication` with `bf:place`/`bf:agent`/`bf:date` from $a/$b/$c; a 264 with ind2=1 wins over 260, then any 264; the date reduces to a four-digit year when one is present |
| 300 $a | `bf:extent` label |
| 336 / 337 / 338 $b | `bf:content` / `bf:media` / `bf:carrier` as `id.loc.gov/vocabulary/{contentTypes,mediaTypes,carriers}/{code}` URIs |
| 600/610/611/630/648/650/651/653 | `bf:subject`: `bf:Topic` (651→`bf:Place`, 648→`bf:Temporal`), label from $a$b$c$d$q$t$v$x$y$z joined with `--`, an `http…` $0 becomes the subject's URI |
| 852 (XSLT only) | `bf:Item` with `bf:heldBy` ($a$b) and `bf:shelfMark` ($h$i$j$k) |
| 856 $u | Instance `bf:electronicLocator` |
| Leader/06 | Work subclass: `a,t`→`bf:Text`, `c,d`→`bf:NotatedMusic`, `e,f`→`bf:Cartography`, `g`→`bf:MovingImage`, `i,j`→`bf:Audio`, `k`→`bf:StillImage`, `m`→`bf:Multimedia`, `r`→`bf:Object`, `o,p`→`bf:MixedMaterial`; anything else stays plain `bf:Work` |

What does **not** map (dropped silently): 130/240 uniform titles, 210/222/
246 variant titles, 250 editions, 4XX/8XX series, all 5XX notes, 041
multiple languages, 76X-78X linking entries, 880 alternate scripts, 655
genres, events, holdings beyond the single 852, and everything not listed
above. Keys/elements with no source data are absent — never null or empty.

The reverse stylesheet is a **subset inverse**, not a general BIBFRAME
reader: it consumes the sibling-resource shape the forward stylesheet
produces (finding the Instance through `bf:hasInstance`, falling back on
`bf:instanceOf`) and rebuilds 001, a 40-character 008 (date type `s`, year
from the publication date, language from the language URI), 010/020/022/
035 (the OCLC number regains its `(OCoLC)` prefix), 050/082, 1XX/7XX with
$4 or $e, 245 (ISBD colon restored before a subtitle), 264 _1, 300, 336-
338 with $b and the matching `$2 rda…` source, 6XX (labels split on `--`
into $a plus repeated $x, URIs back to $0), 852, 856, and a plausible
leader (`00000n{06}{07} a2200000 a 4500`, Leader/06 inverted from the Work
subclass with `bf:Audio`→`j`, Leader/07 `s` when the Instance carries an
ISSN, else `m`). Forward-then-reverse is stable, but not byte-identical:
nonfiling indicators, subdivision subfield codes ($v/$y/$z become $x) and
most trailing punctuation are not recoverable.

## SQL usage

`marc_bibframe_jsonld(leader, fields)` is registered at extension load
(`src/macros/bibframe.sql`) and is built purely from string functions, so
it works — like `marc_jsonld` — even when the json extension is absent.
Its output is JSON text the json extension's operators consume directly.

```sql
-- NDJSON-style export: one BIBFRAME 2 JSON-LD document per line
COPY (SELECT marc_bibframe_jsonld(leader, fields)::VARCHAR AS line
      FROM read_marc('bibs.mrc'))
TO 'bibs.bf.jsonld' (FORMAT csv, HEADER false, QUOTE '');

-- inspect pieces with the json extension loaded
SELECT j->'@graph'->0->>'@id'                              AS work,
       j->'@graph'->0->'bf:title'->>'bf:mainTitle'         AS title,
       j->'@graph'->1->'bf:provisionActivity'->>'bf:date'  AS published
FROM (SELECT marc_bibframe_jsonld(leader, fields) AS j
      FROM read_marc('bibs.mrc'));
```

## XSLT usage

```sh
# MARC (any supported source) -> slim MARCXML -> BIBFRAME 2 RDF/XML
duckdb -c "LOAD marc21;
           COPY (SELECT leader, fields FROM read_marc('bibs.mrc'))
           TO 'bibs.xml' (FORMAT marcxml);"
xsltproc --stringparam baseuri "https://data.example.edu/bib/" \
         xslt/marcxml-to-bibframe2.xsl bibs.xml > bibs.bf.rdf

# and back (for descriptions produced by the forward stylesheet)
xsltproc xslt/bibframe2-to-marcxml.xsl bibs.bf.rdf > bibs.rt.xml
```

Tests: `sh test/xslt/bibframe/run.sh` (fixtures in `test/data/bibframe/`)
exercises both directions plus the `baseuri` parameter and the round trip;
`test/sql/marc_bibframe.test` covers the macro with string-function
assertions that do not require the json extension.
