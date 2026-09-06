-- ---------------------------------------------------------------------------
-- Linked-data export: schema.org-flavored JSON-LD.
--
-- marc_jsonld(leader, fields) returns a JSON object built over the existing
-- marc_dublin_core crosswalk plus the identifier normalizers: @context /
-- @type from schema.org, name/author/publisher/datePublished/inLanguage/
-- about/description, isbn (via marc_isbn13 of 020$a) and issn (via marc_issn
-- of 022$a), url (856$u values) and sameAs ($0/$1 URIs via marc_uris).
-- Absent source data drops its key entirely, so consumers see only asserted
-- triples.  Built with plain string functions: scalar macros bind at
-- registration, so the body cannot reference json-extension functions (the
-- extension may not be loadable there); the output is a JSON text the json
-- extension's operators consume directly.
--
--     COPY (SELECT marc_jsonld(leader, fields)::VARCHAR AS line
--           FROM read_marc('bibs.mrc'))
--     TO 'bibs.jsonld' (FORMAT csv, HEADER false, QUOTE '');
-- ---------------------------------------------------------------------------

-- schema.org @type from Leader/06 (+ Leader/07 for continuing resources).
CREATE OR REPLACE MACRO marc_jsonld_type(leader) AS
    CASE
        WHEN marc_record_type(leader) IN ('a', 't')
             AND marc_bib_level(leader) IN ('b', 'i', 's') THEN 'Periodical'
        WHEN marc_record_type(leader) IN ('a', 't') THEN 'Book'
        WHEN marc_record_type(leader) IN ('e', 'f') THEN 'Map'
        WHEN marc_record_type(leader) IN ('c', 'd') THEN 'MusicComposition'
        WHEN marc_record_type(leader) = 'j'         THEN 'MusicRecording'
        WHEN marc_record_type(leader) = 'i'         THEN 'AudioObject'
        WHEN marc_record_type(leader) = 'g'         THEN 'Movie'
        WHEN marc_record_type(leader) = 'k'         THEN 'ImageObject'
        WHEN marc_record_type(leader) = 'm'         THEN 'SoftwareApplication'
        WHEN marc_record_type(leader) = 'p'         THEN 'Collection'
        ELSE 'CreativeWork'
    END;

-- One JSON string literal, escaped per RFC 8259 (backslash, quote, and the
-- control characters that occur in practice).
CREATE OR REPLACE MACRO marc_jsonld_str(v) AS
    '"' || replace(replace(replace(replace(replace(v::VARCHAR,
               chr(92), chr(92) || chr(92)), '"', chr(92) || '"'),
               chr(10), chr(92) || 'n'), chr(13), chr(92) || 'r'),
               chr(9), chr(92) || 't') || '"';

CREATE OR REPLACE MACRO marc_jsonld_arr(vals) AS
    '[' || array_to_string(list_transform(vals, lambda v: marc_jsonld_str(v)), ',') || ']';

-- The member list, one 'key:value' fragment per asserted key, NULL otherwise;
-- marc_jsonld filters the NULLs away.  dc is a marc_dublin_core struct.
CREATE OR REPLACE MACRO marc_jsonld_body(leader, fields, dc) AS
    ['"@context":"https://schema.org"',
     '"@type":' || marc_jsonld_str(marc_jsonld_type(leader)),
     CASE WHEN dc.title IS NOT NULL
          THEN '"name":' || marc_jsonld_str(dc.title) END,
     CASE WHEN dc.creator IS NOT NULL
          THEN '"author":{"@type":"Person","name":' || marc_jsonld_str(dc.creator) || '}' END,
     CASE WHEN len(dc.contributor) > 0
          THEN '"contributor":[' || array_to_string(list_transform(dc.contributor,
                   lambda c: '{"@type":"Person","name":' || marc_jsonld_str(c) || '}'), ',') || ']' END,
     CASE WHEN dc.publisher IS NOT NULL
          THEN '"publisher":{"@type":"Organization","name":' || marc_jsonld_str(dc.publisher) || '}' END,
     CASE WHEN struct_extract(dc, 'date') IS NOT NULL
          THEN '"datePublished":' || marc_jsonld_str(struct_extract(dc, 'date')) END,
     CASE WHEN dc.language IS NOT NULL
          THEN '"inLanguage":' || marc_jsonld_str(dc.language) END,
     CASE WHEN len(dc.subject) > 0
          THEN '"about":' || marc_jsonld_arr(dc.subject) END,
     CASE WHEN dc.description IS NOT NULL
          THEN '"description":' || marc_jsonld_str(dc.description) END,
     CASE WHEN marc_isbn13(marc_subfield(fields, '020', 'a')) IS NOT NULL
          THEN '"isbn":' || marc_jsonld_str(marc_isbn13(marc_subfield(fields, '020', 'a'))) END,
     CASE WHEN marc_issn(marc_subfield(fields, '022', 'a')) IS NOT NULL
          THEN '"issn":' || marc_jsonld_str(marc_issn(marc_subfield(fields, '022', 'a'))) END,
     CASE WHEN len(marc_subfields(fields, '856', 'u')) > 0
          THEN '"url":' || marc_jsonld_arr(marc_subfields(fields, '856', 'u')) END,
     CASE WHEN len(marc_uris(fields)) > 0
          THEN '"sameAs":' || marc_jsonld_arr(list_transform(marc_uris(fields),
                   lambda u: u.uri)) END];

CREATE OR REPLACE MACRO marc_jsonld(leader, fields) AS
    '{' || array_to_string(list_filter(
               marc_jsonld_body(leader, fields, marc_dublin_core(leader, fields)),
               lambda p: p IS NOT NULL), ',') || '}';
