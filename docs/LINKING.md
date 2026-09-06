# Linking headings: reconcile, fetch, write back

MarcEdit teaches two linked-data motions — *Validate Headings* (check every
1XX/6XX/7XX against an authority service) and *Build Links* (embed the
matching `$0`/`$1` URIs in the record). This extension does the same job in
three explicit steps, each a plain SQL statement, so the corpus, the
candidate list and the decision table are all tables you can inspect, diff
and re-run:

1. **queue** — `marc_reconcile_headings(path, base)` lists every distinct
   heading with its occurrence count and a lookup URL;
2. **fetch and shape** — the URLs are fetched by whatever you already use
   for HTTP, and `marc_idloc_candidates` / `marc_viaf_candidates` /
   `marc_wikidata_candidates` turn each response into candidate rows;
3. **write back** — `marc_set_linked_uri(fields, tagpat, heading, uri, code)`
   sets `$0` (or `$1`) on exactly the field occurrences whose heading
   matched; `marc_clear_linked_uris(fields, tagpat, code)` undoes it.

Step 2 is deliberately not a marc21 function. Per the composition doctrine
in [ECOSYSTEM.md](ECOSYSTEM.md), transport is generic plumbing: `httpfs`
(core) reads constant URLs, and the community `http_client` /
`http_request` extensions do per-row GETs in the same session. What marc21
owns is the cataloging half — heading extraction, NACO comparison,
response shaping, and the targeted write-back that knows which subfield
goes where in a MARC field. Nothing below requires an HTTP extension to
*load*; the fetch step only runs when you choose one.

## 1. Queue

```sql
LOAD marc21;
CREATE TABLE queue AS
SELECT * FROM marc_reconcile_headings('bibs.mrc', 'idloc');
-- heading | n_occurrences | url
```

`base` is `'idloc'`, `'viaf'` or `'wikidata'` (the URL builders in
[reconcile.sql](../src/macros/reconcile.sql) with their defaults) or any
literal URL prefix. `COPY queue TO 'urls.csv'` hands the list to any
fetcher; the heading text is what `marc_headings(fields)` extracted — the
same join the write-back compares against, so no re-derivation is needed.

## 2. Fetch and shape

Three interchangeable ways to get the JSON, from least to most in-session:

**a. Any client, files on disk.** Number the queue, fetch each `url` to
`responses/<n>.json` with curl, a script, a task scheduler — then join the
responses back on the number in the file name:

```sql
LOAD json;
CREATE TABLE queue_n AS
SELECT row_number() OVER (ORDER BY heading) AS n, * FROM queue;
COPY (SELECT n, url FROM queue_n) TO 'urls.csv';          -- drive the fetcher

CREATE TABLE candidates AS
SELECT q.heading, c.*
FROM read_json('responses/*.json', records := false, filename := true) r(j, filename)
JOIN queue_n q ON q.n = regexp_extract(r.filename, '(\d+)\.json$', 1)::BIGINT,
     unnest(marc_idloc_candidates(r.j)) AS c;
```

**b. httpfs, one constant URL at a time.** `read_json` binds its path at
plan time, so it cannot take `url` from a row — but it reads one remote
document fine:

```sql
LOAD httpfs; LOAD json;
SELECT unnest(marc_idloc_candidates(j))
FROM read_json('https://id.loc.gov/authorities/names/suggest2?q=Twain%2C%20Mark&count=5',
               records := false) t(j);
```

**c. Per-row fetches with the community `http_client` extension** (reference
only — not a dependency, and its function signatures are that extension's
own; check its documentation for the current shape):

```sql
INSTALL http_client FROM community; LOAD http_client; LOAD json;
CREATE TABLE responses AS
SELECT heading, http_get(url) AS resp FROM queue;        -- one GET per heading
CREATE TABLE candidates AS
SELECT heading, c.*
FROM responses, unnest(marc_idloc_candidates(resp.body::JSON)) AS c;
-- candidates: heading | label | uri | token
```

The shapers return `LIST(STRUCT(...))` per response, one per service:

| function | returns |
|---|---|
| `marc_idloc_candidates(j)` | `LIST(STRUCT(label, uri, token))` from one id.loc.gov response |
| `marc_viaf_candidates(j)` | `LIST(STRUCT(viaf_id, name_type, heading))` from one VIAF response |
| `marc_wikidata_candidates(j)` | `LIST(STRUCT(id, label, description, concepturi))` from one Wikidata response |

So `unnest` makes a candidate table whatever the source.

## 3. Decide, then write back

Decide in SQL. The safe default is exact NACO equality between the queued
heading and the candidate label; keep looser matches for review:

```sql
CREATE TABLE links AS
SELECT heading, uri
FROM candidates
WHERE marc_naco(label) = marc_naco(heading)
QUALIFY row_number() OVER (PARTITION BY heading ORDER BY uri) = 1;   -- one URI per heading

-- review pile: near misses, never auto-applied
SELECT heading, label, uri, jaro_winkler_similarity(marc_naco(label), marc_naco(heading)) AS sim
FROM candidates
WHERE marc_naco(label) <> marc_naco(heading)
QUALIFY sim > 0.92
ORDER BY sim DESC;
```

Then one `UPDATE` applies every decision. `marc_set_linked_uri` matches a
field when its joined heading — the `marc_heading_join` rule: single-letter
`$a`–`$z` subfields except `$w`, space-joined, so existing `$0`–`$9` never
interfere — NACO-equals the `heading` argument, and sets `$0` on each such
occurrence. An existing `$0` is replaced in place (duplicates collapsed);
otherwise the new subfield lands at the end of the field, where cataloging
practice puts it. Unmatched fields and records are untouched:

```sql
CREATE TABLE bibs AS SELECT * FROM read_marc('bibs.mrc');

-- list_reduce needs its accumulator to share the list's element type, so
-- the fields ride inside the same struct shape as the (heading, uri) rows.
UPDATE bibs SET fields = (
    SELECT list_reduce(
               list(struct_pack(h := l.heading, u := l.uri, f := bibs.fields)),
               lambda acc, x: struct_pack(h := x.h, u := x.u,
                                          f := marc_set_linked_uri(acc.f, '6..', x.h, x.u, '0')),
               struct_pack(h := NULL::VARCHAR, u := NULL::VARCHAR, f := bibs.fields)).f
    FROM links l);

COPY (SELECT leader, fields FROM bibs) TO 'bibs-linked.mrc' (FORMAT marc);
```

Use `'1..'`, `'7..'` or `'...'` as the tag pattern for main entries, added
entries or everything; use code `'1'` for real-world-object URIs
(Wikidata `concepturi` belongs in `$1`, an authority URI in `$0`). Scope
the `UPDATE` with a `WHERE` (an `EXISTS` over `marc_headings(fields)`) when
the corpus is large and few records carry the headings.

To rebuild links from scratch, or to strip links a vendor supplied:

```sql
UPDATE bibs SET fields = marc_clear_linked_uris(fields, '6..', '0');
```

Preview any of these before running them the way every editing function
allows: `SELECT marc_diff(leader, fields, leader, marc_set_linked_uri(...))`
shows exactly which fields would change.

### Why the match is NACO, not string equality

Headings arrive with terminal punctuation (`Cooking.`), the candidate label
without; one side may carry diacritics the other lost in transit. The NACO
comparison form (`marc_naco`, [idnorm.cpp](../src/core/idnorm.cpp)) folds
diacritics, case, commas and punctuation, so `Twain, Mark, 1835-1910.`
links from a candidate labelled `Twain, Mark, 1835-1910` and `Łódź` from
`Lodz`. It is still equality on the folded form — `Cooking` never links
`Cooking, American`. A heading whose NACO form is empty (all punctuation)
links nothing.

## OAI-PMH harvesting: paging the whole set

`marc_readoai(base, ...)` reads one ListRecords page. Full harvests follow
the repository's resumption tokens with the macros in
[oai.sql](../src/macros/oai.sql):

| function | returns |
|---|---|
| `marc_oai_page_url(base, resumption_token)` | the ListRecords URL for one resumptionToken; the protocol allows no other argument beside it, so the builder takes none |
| `marc_oai_token(url)` | one row: that response's resumptionToken (NULL at the end of the list) plus completeListSize, cursor and expirationDate, read through `read_text` |
| `marc_oai_url(base, [metadata_prefix], [set_], [from_], [until_])` | the first-page ListRecords URL for a metadata prefix, set and date window |
| `marc_readoai_page(base, resumption_token)` | one row per subfield: the ListRecords page that resumptionToken names |

SQL has no recursion over HTTP — a recursive CTE cannot hand a value from
one iteration to `read_marcxml`'s path in the next — so the loop is
driven from outside, two statements per page. A shell driver:

```sh
BASE=https://oai.example.org/oai
duckdb harvest.db -c "LOAD marc21; LOAD httpfs;
  CREATE TABLE IF NOT EXISTS harvest AS SELECT * FROM marc_readoai('$BASE', set_ := 'books') LIMIT 0;
  INSERT INTO harvest SELECT * FROM marc_readoai('$BASE', set_ := 'books');"
TOKEN=$(duckdb harvest.db -noheader -csv -c "LOAD marc21; LOAD httpfs;
  SELECT coalesce(token, '') FROM marc_oai_token(marc_oai_url('$BASE', set_ := 'books'));")
while [ -n "$TOKEN" ]; do
  duckdb harvest.db -c "LOAD marc21; LOAD httpfs;
    INSERT INTO harvest SELECT * FROM marc_readoai_page('$BASE', '$TOKEN');"
  TOKEN=$(duckdb harvest.db -noheader -csv -c "LOAD marc21; LOAD httpfs;
    SELECT coalesce(token, '') FROM marc_oai_token(marc_oai_page_url('$BASE', '$TOKEN'));")
done
```

Each page is fetched twice (records, then token). When that matters, save
each page once — `COPY (SELECT content FROM read_text(url)) TO 'page-N.xml'`
or the http extension of your choice — and parse the stored file with
`read_marcxml` and its text with `marc_oai_extract_token(xml)`. Deleted
record stubs yield no rows (the reader's usual envelope handling); a
repository that resends an expired token returns an OAI error document,
which shows up as zero records *and* a NULL token — check
`complete_list_size`/`cursor` against your row count before trusting the end
of the list.

## Distance-based clustering (compose, do not rebuild)

`marc_cluster_headings(path, method)` clusters by key collision
(`fingerprint`, `ngram`), which is what makes it fast at corpus scale.
MarcEdit's clustering also offers Levenshtein and a composite coefficient.
Those are generic string-distance algorithms DuckDB already ships
(`levenshtein`, `jaro_winkler_similarity`, `damerau_levenshtein`, and the
community `rapidfuzz` extension for more), so the right shape is a
self-join over the fingerprint groups rather than a new method — the key
groups bound the pairs to compare, the distance decides within and across
them:

```sql
WITH h AS (
    SELECT heading, marc_fingerprint(heading) AS key, count(*) AS n
    FROM (SELECT unnest(marc_headings(fields)) AS heading FROM read_marc('bibs.mrc'))
    GROUP BY heading
),
pairs AS (
    SELECT a.heading AS variant, b.heading AS candidate, a.n AS n_variant, b.n AS n_candidate,
           levenshtein(marc_naco(a.heading), marc_naco(b.heading)) AS edits,
           jaro_winkler_similarity(marc_naco(a.heading), marc_naco(b.heading)) AS jw
    FROM h a JOIN h b
      ON a.heading <> b.heading
     AND b.n >= a.n                                   -- propose the commoner form
     AND substr(a.key, 1, 1) = substr(b.key, 1, 1)    -- cheap blocking on the key
)
SELECT variant, candidate, n_variant, n_candidate, edits, jw
FROM pairs
WHERE edits <= 2 OR jw >= 0.95
ORDER BY jw DESC, edits;
```

Feed the accepted rows to `marc_replace_values` (or the task recorder's
find/replace) exactly as a key-collision cluster would be normalized. For
record-level linkage rather than heading cleanup, `marc_dedupe_candidates`
already applies Jaro-Winkler over match keys.

## Transliteration: out of scope

MarcEdit's transliteration webinar (romanizing Arabic, Cyrillic, ... into
paired 880 fields) relies on an ICU-style transliterator engine. No DuckDB
core or community extension provides one, and the rules are not MARC
knowledge, so marc21 does not build it. Transliterate before ingest with
ICU's `uconv -x` (e.g. `Cyrillic-Latin`, `Any-Latin`) or a library binding
of ICU's `Transliterator`, or in a client language around the DuckDB
connection; the 880/`$6` pairing that *is* MARC knowledge already works —
`marc_add_field` a linked 880 whose `$6` names the paired tag and
occurrence, exactly as [UNIMARC.md](UNIMARC.md) recommends handling ISO
5426 conversion outside the extension.
