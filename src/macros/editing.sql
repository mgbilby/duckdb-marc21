-- ===========================================================================
-- Editing depth: heading clustering, 260 → 264 conversion, URL check
-- worklist.  Embedded after src/macros.sql (src/macros/*.sql load in sorted
-- filename order), so this file may use macros defined there
-- (marc_headings, marc_urls_856, marc_control_field) and the C++ scalars
-- registered by marc_cluster_scalars.cpp (marc_fingerprint,
-- marc_ngram_fingerprint).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- OpenRefine-style key-collision clustering of a corpus's headings (the
-- 1XX/6XX/7XX set marc_headings extracts).  method is 'fingerprint' (fold,
-- tokenize, sort, de-dupe — catches reordering, case, punctuation and
-- diacritic variants) or 'ngram' (bigram fingerprint — also catches small
-- internal typos); anything else errors.  One row per non-empty key:
--   n_headings  total heading occurrences under the key
--   n_variants  distinct raw forms (a cluster worth reviewing has > 1)
--   members     the distinct raw forms, sorted
-- Typical use:
--   SELECT * FROM marc_cluster_headings('bibs.mrc', 'fingerprint')
--   WHERE n_variants > 1;
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_cluster_headings(path, method) AS TABLE
WITH keyed AS (
    SELECT heading,
           CASE method
               WHEN 'fingerprint' THEN marc_fingerprint(heading)
               WHEN 'ngram'       THEN marc_ngram_fingerprint(heading, 2)
               ELSE error('marc_cluster_headings: method must be fingerprint or ngram')
           END AS key
    FROM (SELECT unnest(marc_headings(fields)) AS heading FROM read_marc(path)))
SELECT key,
       count(*)                                AS n_headings,
       count(DISTINCT heading)                 AS n_variants,
       list(DISTINCT heading ORDER BY heading) AS members
FROM keyed
WHERE key <> ''
GROUP BY key
ORDER BY n_variants DESC, n_headings DESC, key;

-- ---------------------------------------------------------------------------
-- 260 → 264 conversion (RDA).  Each 260 becomes:
--   * a 264 _1 publication statement — ind1 carried over (sequence has the
--     same meaning in both tags), $a/$b/$c kept along with the $3/$6/$8
--     controls, with any copyright run ("©1999", "℗1999", "c1999",
--     "copyright 1999" and its joining punctuation) stripped from $c; a
--     subfield left empty drops.  $e/$f/$g (manufacture, which RDA moves to
--     a 264 _3) are deliberately NOT carried — convert those by hand;
--   * plus a 264 _4 with $c '©YYYY' when a $c carries a copyright year.
-- Fields other than 260 pass through in place, so the pair lands exactly
-- where the 260 stood.  Pure SQL over the nested fields value — composes
-- with marc_add_field/marc_set_subfield like every other editing scalar.
-- ---------------------------------------------------------------------------

-- The first copyright year in a 260 $c ('' when none; RE2 syntax).
CREATE OR REPLACE MACRO marc_260c_copyright_year(c) AS
    regexp_extract(coalesce(c, ''), '(?:©|℗|[Cc]opyright |\bc)([0-9]{4})', 1);

-- One 260 field struct as its 264 _1 publication statement.
CREATE OR REPLACE MACRO marc_264_publication(f) AS
    struct_pack(
        tag := '264', ind1 := f.ind1, ind2 := '1', value := NULL::VARCHAR,
        subfields := list_filter(
            list_transform(f.subfields, lambda s:
                struct_pack(
                    code := s.code,
                    value := CASE WHEN s.code = 'c'
                                  THEN trim(regexp_replace(s.value,
                                            '[,;: ]*(?:©|℗|[Cc]opyright |\bc)[0-9]{4}\.?', '', 'g'),
                                            ' ,;:')
                                  ELSE s.value END)),
            lambda s: s.code IN ('3', '6', '8', 'a', 'b', 'c') AND s.value <> ''));

-- One 260 field struct as its 264 _4 copyright-notice-date field, NULL when
-- no $c carries a copyright year.
CREATE OR REPLACE MACRO marc_264_copyright(f) AS
    CASE WHEN marc_260c_copyright_year(
             list_aggregate(list_transform(list_filter(f.subfields, lambda s: s.code = 'c'),
                                           lambda s: s.value), 'string_agg', ' ')) <> ''
         THEN struct_pack(
             tag := '264', ind1 := f.ind1, ind2 := '4', value := NULL::VARCHAR,
             subfields := [struct_pack(
                 code := 'c',
                 value := '©' || marc_260c_copyright_year(
                     list_aggregate(list_transform(list_filter(f.subfields, lambda s: s.code = 'c'),
                                                   lambda s: s.value), 'string_agg', ' ')))])
    END;

CREATE OR REPLACE MACRO marc_264_from_260(fields) AS
    flatten(list_transform(fields, lambda f:
        CASE WHEN f.tag = '260' AND f.subfields IS NOT NULL THEN
            list_filter([marc_264_publication(f), marc_264_copyright(f)],
                        lambda g: g IS NOT NULL AND len(g.subfields) > 0)
        ELSE [f] END));

-- ---------------------------------------------------------------------------
-- 856 link-audit worklist: one row per 856 $u across the corpus, with the
-- record's 001 and the parsed scheme/host for triage (mailto:, ftp: and
-- bare-path "URLs" surface immediately).  This macro builds the TO-CHECK
-- list only; actually resolving the links is deliberately out of scope
-- (keeps the extension dependency-free and tests offline).  The documented
-- checking pattern, using the community http_client extension:
--     INSTALL http_client FROM community; LOAD http_client;
--     SELECT u.*, (http_get(u.uri)).status AS status
--     FROM marc_check_urls('bibs.mrc') u
--     WHERE u.scheme IN ('http', 'https');
-- (httpfs alone can read http(s) content but exposes no status-code scalar;
-- filter non-2xx rows from http_get for the broken-link report.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_check_urls(path) AS TABLE
SELECT file, record_no,
       marc_control_field(fields, '001') AS control_number,
       u.uri, u.link_text, u.materials,
       lower(regexp_extract(u.uri, '^([A-Za-z][A-Za-z0-9+.-]*):', 1))          AS scheme,
       lower(regexp_extract(u.uri, '^[A-Za-z][A-Za-z0-9+.-]*://([^/:?#]+)', 1)) AS host
FROM read_marc(path), unnest(marc_urls_856(fields)) AS t(u)
ORDER BY file, record_no;
