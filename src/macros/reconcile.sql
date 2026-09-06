-- ===========================================================================
-- Authority reconciliation against id.loc.gov, VIAF and Wikidata: URL
-- builders, a per-heading work queue, and shapers for each service's JSON
-- response (fixture-tested in test/sql/marc_reconcile.test against
-- test/data/sample_idloc.json / sample_viaf.json / sample_wikidata.json).
--
-- The fetch itself stays outside these macros on purpose: read_json binds
-- its path argument at plan time, so it cannot take a per-row URL from
-- marc_reconcile_headings.  The working pattern is fetch-then-shape:
--   1. build the queue:   SELECT * FROM marc_reconcile_headings('f.mrc', 'viaf');
--   2. fetch each url (httpfs lets read_json read a CONSTANT http(s) URL;
--      or save responses to files with any client), one JSON doc per
--      heading;
--   3. shape candidates:  SELECT unnest(marc_viaf_candidates(j)) FROM
--      read_json('responses/*.json', records := false) t(j);
-- and match candidates back to headings with marc_naco equality or
-- jaro_winkler_similarity.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- URL builders.  url_encode is core DuckDB; every builder returns a plain
-- VARCHAR so the queue can be exported (COPY ... TO 'urls.csv') for any
-- fetcher.
-- ---------------------------------------------------------------------------

-- id.loc.gov known-label lookup: resolves an EXACT authorized label to the
-- authority, answering with a redirect whose X-URI/X-PrefLabel headers (or
-- the .json body it lands on) carry the match.  scheme is the id.loc.gov
-- dataset path: 'names', 'subjects', 'childrensSubjects', 'genreForms', ...
CREATE OR REPLACE MACRO marc_idloc_label_url(label, scheme := 'names') AS
    'https://id.loc.gov/authorities/' || scheme || '/label/' || url_encode(label);

-- id.loc.gov suggest2 keyword search — the JSON-friendly fuzzy counterpart
-- of the known-label service (response shape: sample_idloc.json).
CREATE OR REPLACE MACRO marc_idloc_suggest_url(term, scheme := 'names', count_ := 5) AS
    'https://id.loc.gov/authorities/' || scheme || '/suggest2?q=' || url_encode(term)
        || '&count=' || count_;

-- VIAF SRU search with a JSON response (shape: sample_viaf.json).  index_
-- picks the SRU index: local.mainHeadingEl (headings), local.names,
-- local.personalNames, cql.any, ...
CREATE OR REPLACE MACRO marc_viaf_search_url(term, index_ := 'local.mainHeadingEl',
                                             max_records := 5) AS
    'https://viaf.org/viaf/search?query='
        || url_encode(index_ || ' all "' || term || '"')
        || '&maximumRecords=' || max_records || '&httpAccept=application/json';

-- Wikidata wbsearchentities (shape: sample_wikidata.json).
CREATE OR REPLACE MACRO marc_wikidata_search_url(term, language := 'en', limit_ := 5) AS
    'https://www.wikidata.org/w/api.php?action=wbsearchentities&format=json&language='
        || language || '&uselang=' || language || '&type=item&limit=' || limit_
        || '&search=' || url_encode(term);

-- ---------------------------------------------------------------------------
-- The reconciliation queue: one row per distinct heading of the corpus with
-- its occurrence count and lookup URL.  base is 'idloc', 'viaf' or
-- 'wikidata' for the builders above (their defaults), or any literal URL
-- prefix to which the url-encoded heading is appended.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_reconcile_headings(path, base) AS TABLE
SELECT heading,
       count(*) AS n_occurrences,
       CASE base
           WHEN 'idloc'    THEN marc_idloc_suggest_url(heading)
           WHEN 'viaf'     THEN marc_viaf_search_url(heading)
           WHEN 'wikidata' THEN marc_wikidata_search_url(heading)
           ELSE base || url_encode(heading)
       END AS url
FROM (SELECT unnest(marc_headings(fields)) AS heading FROM read_marc(path))
GROUP BY heading, base
ORDER BY n_occurrences DESC, heading;

-- ---------------------------------------------------------------------------
-- Response shapers: each takes one service response as the STRUCT read_json
-- produces and returns LIST(STRUCT(...)) candidate rows — unnest to a
-- table.  Field paths follow each API's real response shape; the fixtures
-- under test/data/ pin them.
-- ---------------------------------------------------------------------------

-- id.loc.gov suggest2: hits[] of {suggestLabel, uri, aLabel, token, ...}.
CREATE OR REPLACE MACRO marc_idloc_candidates(j) AS
    list_transform(j.hits, lambda h: struct_pack(
        label := h.aLabel,
        uri   := h.uri,
        token := h.token));

-- VIAF SRU JSON: searchRetrieveResponse.records.record[].recordData
-- .VIAFCluster.  CAVEAT (real API): when exactly one record or one main
-- heading comes back VIAF serializes the would-be array as a bare object;
-- read_json only unifies that to a list when both forms appear in the same
-- scan.  The shaper (and fixture) use the list form — normalize
-- single-object responses upstream if the service hands you one.
CREATE OR REPLACE MACRO marc_viaf_candidates(j) AS
    list_transform(j.searchRetrieveResponse.records.record, lambda r: struct_pack(
        viaf_id   := r.recordData.VIAFCluster.viafID,
        name_type := r.recordData.VIAFCluster.nameType,
        heading   := r.recordData.VIAFCluster.mainHeadings.data[1].text));

-- Wikidata wbsearchentities: search[] of {id, label, description,
-- concepturi, match, ...}.
CREATE OR REPLACE MACRO marc_wikidata_candidates(j) AS
    list_transform(j.search, lambda e: struct_pack(
        id          := e.id,
        label       := e.label,
        description := e.description,
        concepturi  := e.concepturi));
