-- ===========================================================================
-- Top-k candidate matching as a NEAREST join — DuckDB v2.0 and up ONLY.
--
-- v2.0 adds a join clause that asks for the k best partners of every left
-- row instead of every partner:
--     <left> [INNER|LEFT OUTER] JOIN <target> [APPROX|EXACT]
--         NEAREST <k> BY (DISTANCE|SIMILARITY) <ranking expression>
-- BY DISTANCE keeps the k smallest values, BY SIMILARITY the k largest;
-- candidates whose ranking expression is NULL are dropped rather than ranked
-- last, and the clause binds as a lateral top-k (ORDER BY ranking LIMIT k)
-- against the target.  That is exactly the shape marc21's deduplication and
-- reconciliation story wants: "the five catalog records this incoming record
-- could be" instead of the full record x record product that
-- marc_dedupe_candidates (src/macros.sql) has to score and then throw away.
--
-- This file is additive and loads only on v2.0: every macro here is new, the
-- v1.5-compatible marc_dedupe_* / marc_cluster_* / marc_reconcile_* surface
-- is untouched and keeps working unchanged on both versions.
--
-- Three things about the clause shape the macros below:
--
--   * k IS A LITERAL.  The grammar takes a NumberLiteral there and the
--     parser rejects anything that is not a positive integer constant, so k
--     cannot be a macro parameter — a table macro has to bake its k in.  The
--     macros pick a workflow-appropriate k and expose everything else
--     (paths, minimum similarity) as parameters; marc_nearest_matches_sql /
--     marc_nearest_matches_k below are the escape hatch for another k, built
--     the way marc_alma_update_bib defers http_put: compose the statement as
--     text and let query() parse it at use time.
--
--   * EXACT, NOT APPROX.  APPROX is accepted and is informational today,
--     but it is a licence for the engine to return approximate neighbours.
--     There is no approximate index for jaro_winkler_similarity over
--     normalized headings, and a deduplication report that silently starts
--     missing pairs is worse than a slow one, so these macros say EXACT.
--
--   * THE SCORE IS NOT PROJECTED.  The ranking expression ranks; it does not
--     become a column.  Each macro therefore repeats it in the select list
--     to report the similarity it matched on.
--
-- Ranking runs on marc_nearest_key: the NACO-normalized 245 $a $b, i.e. the
-- title half of marc_matchkey (src/core/idnorm.cpp) without its ISBN/year
-- tail and without the 40-character truncation.  Sharing the normalization
-- with the match key is what lets the same row carry both signals.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- The ranking key: 245 $a and $b joined with a blank, NACO-normalized
-- (diacritics folded, comma to space, punctuation dropped, uppercased).  A
-- record with no 245 $a yields NULL — '||' propagates NULL, unlike concat()
-- — which is deliberate: NULL-ranked candidates are dropped by the NEAREST
-- clause instead of being ranked against every query record at similarity 0.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_nearest_key(fields) AS
    marc_naco(marc_subfield(fields, '245', 'a')
              || coalesce(' ' || marc_subfield(fields, '245', 'b'), ''));

-- ---------------------------------------------------------------------------
-- One row per record of a file (or glob) with both matching signals: the
-- jaro-winkler ranking key and the exact match key.  Every macro below joins
-- this to itself or to a second corpus, and it is equally the right starting
-- point for a hand-written NEAREST join against a local table:
--   SELECT q.record_no, t.record_no
--   FROM my_table q
--   INNER JOIN marc_nearest_recs('catalog.mrc') t
--       EXACT NEAREST 5 BY SIMILARITY jaro_winkler_similarity(q.title_key, t.tkey);
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_nearest_recs(path) AS TABLE
SELECT file, record_no,
       marc_subfield(fields, '245', 'a') AS title,
       marc_nearest_key(fields)          AS tkey,
       marc_matchkey(fields)             AS matchkey
FROM read_marc(path);

-- ---------------------------------------------------------------------------
-- Near-duplicate partners inside one corpus: for every record, the five most
-- similar other records by title.  The NEAREST counterpart of
-- marc_dedupe_candidates, and different from it in three ways worth knowing
-- before swapping one for the other:
--
--   * rows are DIRECTED.  marc_dedupe_candidates emits each unordered pair
--     once; a top-k join is per-record, so a pair appears twice when each
--     record is in the other's top five, and once when only one of them is.
--     That asymmetry is information: "b is a's best match" and "a is not b's"
--     is how a large cluster announces itself.
--   * the work is bounded.  Five partners per record, not n-1 scored pairs.
--   * records with no 245 $a never appear.  Their key is NULL, so the clause
--     drops them as candidates and, having no key to rank with, they get no
--     partners either — where marc_dedupe_candidates still surfaces them
--     through its exact-match-key rule.
--
-- NEAREST 6, not 5: a record's own row is its best match at similarity 1.0
-- and is filtered out afterwards, so six candidates leave five partners.
-- (More than six records sharing one title can crowd a record out of its own
-- top-6; it then keeps all six partners, which is the answer anyway.)
-- min_similarity filters afterwards, on the same "at or above the threshold,
-- plus every exact match-key pair" rule marc_dedupe_candidates uses.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_nearest_dupes(path, min_similarity := 0.0) AS TABLE
WITH recs AS (SELECT * FROM marc_nearest_recs(path))
SELECT q.file      AS file_a,
       q.record_no AS record_no_a,
       q.title     AS title_a,
       t.file      AS file_b,
       t.record_no AS record_no_b,
       t.title     AS title_b,
       jaro_winkler_similarity(q.tkey, t.tkey)                        AS similarity,
       q.matchkey IS NOT NULL AND q.matchkey = t.matchkey             AS same_matchkey
FROM recs q
INNER JOIN recs t
    EXACT NEAREST 6 BY SIMILARITY jaro_winkler_similarity(q.tkey, t.tkey)
WHERE NOT (q.file = t.file AND q.record_no = t.record_no)
  AND (jaro_winkler_similarity(q.tkey, t.tkey) >= min_similarity
       OR (q.matchkey IS NOT NULL AND q.matchkey = t.matchkey))
ORDER BY file_a, record_no_a, similarity DESC, file_b, record_no_b;

-- ---------------------------------------------------------------------------
-- Overlap between two corpora: for every record of query_path, the five
-- closest records of target_path.  The vendor-load question — "does this
-- shipment duplicate what we already hold?" — which is a top-k problem per
-- incoming record, not a filtered product of the two files.  No self-match
-- to exclude here, so k is 5 exactly.
--
-- LEFT OUTER would keep incoming records with no candidate at all (all
-- target columns NULL); INNER is the right default for a report whose rows
-- are the matches to review, and the incoming records that matched nothing
-- are the ANTI JOIN of this result against the file.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_nearest_matches(query_path, target_path,
                                             min_similarity := 0.0) AS TABLE
WITH query_recs  AS (SELECT * FROM marc_nearest_recs(query_path)),
     target_recs AS (SELECT * FROM marc_nearest_recs(target_path))
SELECT q.file      AS file_q,
       q.record_no AS record_no_q,
       q.title     AS title_q,
       t.file      AS file_t,
       t.record_no AS record_no_t,
       t.title     AS title_t,
       jaro_winkler_similarity(q.tkey, t.tkey)            AS similarity,
       q.matchkey IS NOT NULL AND q.matchkey = t.matchkey AS same_matchkey
FROM query_recs q
INNER JOIN target_recs t
    EXACT NEAREST 5 BY SIMILARITY jaro_winkler_similarity(q.tkey, t.tkey)
WHERE jaro_winkler_similarity(q.tkey, t.tkey) >= min_similarity
   OR (q.matchkey IS NOT NULL AND q.matchkey = t.matchkey)
ORDER BY file_q, record_no_q, similarity DESC, file_t, record_no_t;

-- ---------------------------------------------------------------------------
-- Reconciliation: for every distinct heading of a corpus, the three closest
-- labels of a candidate list.  This is the last step of the fetch-then-shape
-- workflow in src/macros/reconcile.sql — marc_reconcile_headings builds the
-- queue, the service answers, marc_idloc_candidates / marc_viaf_candidates /
-- marc_wikidata_candidates shape the response — where the header says to
-- "match candidates back to headings with marc_naco equality or
-- jaro_winkler_similarity".  Equality misses variants and similarity over
-- the full product is wasteful; three nearest labels per heading is the
-- shape a reviewer actually works through.
--
-- labels is a VARCHAR list, so it takes the shaped candidates directly:
--   SELECT * FROM marc_nearest_headings('bibs.mrc',
--       (SELECT list(c.label)
--        FROM (SELECT unnest(marc_idloc_candidates(j)) AS c
--              FROM read_json('responses/*.json', records := false) t(j))));
-- Headings are ranked NACO-normalized on both sides, so case, diacritics and
-- comma spacing never decide a match.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_nearest_headings(path, labels,
                                              min_similarity := 0.0) AS TABLE
WITH headings AS (
    SELECT heading, marc_naco(heading) AS hkey, count(*) AS n_occurrences
    FROM (SELECT unnest(marc_headings(fields)) AS heading FROM read_marc(path))
    GROUP BY heading, marc_naco(heading)),
cands AS (
    SELECT label, marc_naco(label) AS lkey
    FROM (SELECT unnest(labels) AS label))
SELECT h.heading, h.n_occurrences, c.label,
       jaro_winkler_similarity(h.hkey, c.lkey) AS similarity
FROM headings h
INNER JOIN cands c
    EXACT NEAREST 3 BY SIMILARITY jaro_winkler_similarity(h.hkey, c.lkey)
WHERE jaro_winkler_similarity(h.hkey, c.lkey) >= min_similarity
ORDER BY h.n_occurrences DESC, h.heading, similarity DESC, c.label;

-- ---------------------------------------------------------------------------
-- Any k, deferred through query().  k is a parse-time literal in the NEAREST
-- clause (see the header), so a macro that takes k has to compose the
-- statement as text and hand it to query(), which parses it when the macro
-- is used rather than when it is created — the same deferral
-- marc_alma_update_bib uses for http_put.  The generated statement is
-- marc_nearest_matches with the threshold dropped and k substituted, and
-- SELECT marc_nearest_matches_sql(...) prints exactly what will run.
-- ---------------------------------------------------------------------------

-- One SQL string literal: quotes doubled, wrapped in single quotes.
CREATE OR REPLACE MACRO marc_nearest_sql_quote(s) AS
    chr(39) || replace(s, chr(39), chr(39) || chr(39)) || chr(39);

-- The deferred top-k statement as text.  k is validated here rather than
-- left to the parser, so a bad k names this macro instead of reporting a
-- syntax error in generated SQL the caller never wrote.
CREATE OR REPLACE MACRO marc_nearest_matches_sql(query_path, target_path, k) AS
    'SELECT q.file AS file_q, q.record_no AS record_no_q, q.title AS title_q, '
    || 't.file AS file_t, t.record_no AS record_no_t, t.title AS title_t, '
    || 'jaro_winkler_similarity(q.tkey, t.tkey) AS similarity, '
    || 'q.matchkey IS NOT NULL AND q.matchkey = t.matchkey AS same_matchkey '
    || 'FROM marc_nearest_recs(' || marc_nearest_sql_quote(query_path) || ') q '
    || 'INNER JOIN marc_nearest_recs(' || marc_nearest_sql_quote(target_path) || ') t '
    || 'EXACT NEAREST '
    || CASE WHEN k IS NOT NULL AND k >= 1 AND k = floor(k)
            THEN CAST(CAST(k AS BIGINT) AS VARCHAR)
            ELSE error('marc_nearest_matches_sql: k must be a positive integer')
       END
    || ' BY SIMILARITY jaro_winkler_similarity(q.tkey, t.tkey) '
    || 'ORDER BY file_q, record_no_q, similarity DESC, file_t, record_no_t';

-- marc_nearest_matches with an arbitrary k.  Same columns, same order; the
-- statement is parsed at use time, so a bad k errors when the macro is
-- called, not when marc21 loads.
CREATE OR REPLACE MACRO marc_nearest_matches_k(query_path, target_path, k) AS TABLE
SELECT * FROM query(marc_nearest_matches_sql(query_path, target_path, k));
