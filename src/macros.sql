-- Macros registered at LOAD time.  Everything here is pure SQL over the two
-- Rust table functions, which keeps phase one free of nested-vector FFI.

-- ---------------------------------------------------------------------------
-- marc_readfields(path): one row per field.
--   control fields  -> subfields NULL, control_value populated
--   data fields     -> subfields LIST(STRUCT(code, value)), control_value NULL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_readfields(path) AS TABLE
SELECT
    record_no,
    file,
    control_number,
    any_value(leader)                                            AS leader,
    field_no,
    any_value(tag)                                               AS tag,
    any_value(ind1)                                              AS ind1,
    any_value(ind2)                                              AS ind2,
    any_value(value) FILTER (WHERE code IS NULL)                 AS control_value,
    CASE WHEN count(code) = 0 THEN NULL
         ELSE list(struct_pack(code := code, value := value) ORDER BY subfield_no)
                  FILTER (WHERE code IS NOT NULL)
    END                                                          AS subfields
FROM read_marc_subfields(path)
GROUP BY record_no, file, control_number, field_no
ORDER BY file, record_no, field_no;

-- ---------------------------------------------------------------------------
-- Leader / control-field position helpers.  Positions are 0-based to match
-- the MARC 21 documentation ("Leader/06", "008/35-37").
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_leader_pos(leader, pos)             AS substr(leader, pos + 1, 1);
CREATE OR REPLACE MACRO marc_control_pos(val, start_pos, len)    AS substr(val, start_pos + 1, len);
CREATE OR REPLACE MACRO marc_record_type(leader)                 AS substr(leader, 7, 1);   -- Leader/06
CREATE OR REPLACE MACRO marc_bib_level(leader)                   AS substr(leader, 8, 1);   -- Leader/07
CREATE OR REPLACE MACRO marc_encoding_scheme(leader)             AS
    CASE substr(leader, 10, 1) WHEN 'a' THEN 'utf8' ELSE 'marc8' END;                     -- Leader/09

-- ---------------------------------------------------------------------------
-- Navigation over the nested `fields` column produced by read_marc().
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_fields(fields, tag_) AS
    list_filter(fields, lambda f: f.tag = tag_);

CREATE OR REPLACE MACRO marc_subfields(fields, tag_, code_) AS
    list_transform(
        list_filter(
            flatten(list_transform(
                list_filter(fields, lambda f: f.tag = tag_ AND f.subfields IS NOT NULL),
                lambda f: f.subfields)),
            lambda s: s.code = code_),
        lambda s: s.value);

CREATE OR REPLACE MACRO marc_subfield(fields, tag_, code_) AS
    marc_subfields(fields, tag_, code_)[1];

CREATE OR REPLACE MACRO marc_control_field(fields, tag_) AS
    list_transform(list_filter(fields, lambda f: f.tag = tag_), lambda f: f.value)[1];

-- Convenience: a field's subfields concatenated in order, MarcEdit-breaker style ("$aTitle :$bsub /").
CREATE OR REPLACE MACRO marc_fieldbreak(f) AS
    '=' || f.tag || '  ' ||
    CASE WHEN f.subfields IS NULL
         THEN f.value
         ELSE replace(f.ind1, ' ', '\') || replace(f.ind2, ' ', '\') ||
              list_aggregate(list_transform(f.subfields, lambda s: '$' || s.code || s.value), 'string_agg', '')
    END;

-- ---------------------------------------------------------------------------
-- Phase 2/3 macros.
-- ---------------------------------------------------------------------------

-- Structural validation of one record's leader + fields.  Returns a LIST of
-- human-readable violations; an empty list means the record passes.  This is
-- the structural core of marc_validate; validation against a full Avram
-- schema (field repeatability, fixed-position vocabularies) layers on top.
CREATE OR REPLACE MACRO marc_validate(leader, fields) AS
    list_filter([
        CASE WHEN length(leader) != 24
             THEN 'leader is ' || length(leader) || ' chars, expected 24' END,
        CASE WHEN substr(leader, 10, 1) NOT IN ('a', ' ')
             THEN 'leader/09 is ' || substr(leader, 10, 1) || ', expected ''a'' or blank' END,
        CASE WHEN len(list_filter(fields, lambda f: length(f.tag) != 3)) > 0
             THEN 'tag not 3 characters: ' ||
                  list_filter(fields, lambda f: length(f.tag) != 3)[1].tag END,
        CASE WHEN len(list_filter(fields, lambda f: f.tag = '001')) > 1
             THEN '001 is not repeatable but occurs ' ||
                  len(list_filter(fields, lambda f: f.tag = '001')) || ' times' END,
        CASE WHEN len(list_filter(fields, lambda f: f.tag = '245')) = 0
             THEN 'no 245 (title) field' END,
        CASE WHEN len(list_filter(fields, lambda f:
                        f.subfields IS NOT NULL AND len(f.subfields) = 0)) > 0
             THEN 'data field with no subfields' END
    ], lambda v: v IS NOT NULL);

-- Whole-record breaker rendering (one text block per record).
CREATE OR REPLACE MACRO marc_recordbreak(leader, fields) AS
    '=LDR  ' || leader || chr(10) ||
    list_aggregate(
        list_transform(fields, lambda f: marc_fieldbreak(f)),
        'string_agg', chr(10));

-- Nested readers over the text formats, mirroring read_marc()/marc_readfields().
CREATE OR REPLACE MACRO marc_readfieldsxml(path) AS TABLE
SELECT record_no, file, control_number,
       any_value(leader) AS leader, field_no,
       any_value(tag) AS tag, any_value(ind1) AS ind1, any_value(ind2) AS ind2,
       any_value(value) FILTER (WHERE code IS NULL) AS control_value,
       CASE WHEN count(code) = 0 THEN NULL
            ELSE list(struct_pack(code := code, value := value) ORDER BY subfield_no)
                     FILTER (WHERE code IS NOT NULL)
       END AS subfields
FROM read_marcxml(path)
GROUP BY record_no, file, control_number, field_no
ORDER BY file, record_no, field_no;

CREATE OR REPLACE MACRO marc_readnestedxml(path) AS TABLE
SELECT record_no, file, control_number, leader,
       list(struct_pack(tag := tag, ind1 := ind1, ind2 := ind2,
                        value := control_value, subfields := subfields)
            ORDER BY field_no) AS fields
FROM marc_readfieldsxml(path)
GROUP BY record_no, file, control_number, leader
ORDER BY record_no;

CREATE OR REPLACE MACRO marc_readfieldsbreaker(path) AS TABLE
SELECT record_no, file, control_number,
       any_value(leader) AS leader, field_no,
       any_value(tag) AS tag, any_value(ind1) AS ind1, any_value(ind2) AS ind2,
       any_value(value) FILTER (WHERE code IS NULL) AS control_value,
       CASE WHEN count(code) = 0 THEN NULL
            ELSE list(struct_pack(code := code, value := value) ORDER BY subfield_no)
                     FILTER (WHERE code IS NOT NULL)
       END AS subfields
FROM read_marc_breaker(path)
GROUP BY record_no, file, control_number, field_no
ORDER BY file, record_no, field_no;

CREATE OR REPLACE MACRO marc_readnestedbreaker(path) AS TABLE
SELECT record_no, file, control_number, leader,
       list(struct_pack(tag := tag, ind1 := ind1, ind2 := ind2,
                        value := control_value, subfields := subfields)
            ORDER BY field_no) AS fields
FROM marc_readfieldsbreaker(path)
GROUP BY record_no, file, control_number, leader
ORDER BY record_no;

-- ---------------------------------------------------------------------------
-- Record format from Leader/06 (MARC 21 family of formats):
--   z              -> authority
--   u, v, x, y     -> holdings
--   w              -> classification
--   q              -> community information
--   a-t otherwise  -> bibliographic (a c d e f g i j k m o p r t; unknown
--                     codes are treated as bibliographic too, matching the
--                     reader's permissiveness)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_format(leader) AS
    CASE
        WHEN marc_record_type(leader) = 'z'                      THEN 'authority'
        WHEN marc_record_type(leader) IN ('u', 'v', 'x', 'y')    THEN 'holdings'
        WHEN marc_record_type(leader) = 'w'                      THEN 'classification'
        WHEN marc_record_type(leader) = 'q'                      THEN 'community'
        ELSE 'bibliographic'
    END;

-- Redefinition of marc_validate (appended so marc_format exists at bind
-- time): identical to the version above except the "no 245" check applies
-- only to bibliographic records — authority/holdings/classification/
-- community formats have no title field to demand.
CREATE OR REPLACE MACRO marc_validate(leader, fields) AS
    list_filter([
        CASE WHEN length(leader) != 24
             THEN 'leader is ' || length(leader) || ' chars, expected 24' END,
        CASE WHEN substr(leader, 10, 1) NOT IN ('a', ' ')
             THEN 'leader/09 is ' || substr(leader, 10, 1) || ', expected ''a'' or blank' END,
        CASE WHEN len(list_filter(fields, lambda f: length(f.tag) != 3)) > 0
             THEN 'tag not 3 characters: ' ||
                  list_filter(fields, lambda f: length(f.tag) != 3)[1].tag END,
        CASE WHEN len(list_filter(fields, lambda f: f.tag = '001')) > 1
             THEN '001 is not repeatable but occurs ' ||
                  len(list_filter(fields, lambda f: f.tag = '001')) || ' times' END,
        CASE WHEN marc_format(leader) = 'bibliographic'
              AND len(list_filter(fields, lambda f: f.tag = '245')) = 0
             THEN 'no 245 (title) field' END,
        CASE WHEN len(list_filter(fields, lambda f:
                        f.subfields IS NOT NULL AND len(f.subfields) = 0)) > 0
             THEN 'data field with no subfields' END
    ], lambda v: v IS NOT NULL);

-- ---------------------------------------------------------------------------
-- Text helpers shared by the mapping/crosswalk macros.
-- ---------------------------------------------------------------------------

-- Strip ISBD-style trailing punctuation (" /", " :", " ;", " =", ",", ".")
-- plus trailing whitespace.  Simplification: a single trailing period is
-- always stripped, so "U.S.A." becomes "U.S.A" — good enough for display
-- titles and headings, documented rather than special-cased.
CREATE OR REPLACE MACRO marc_trim_punct(s) AS
    rtrim(s, ' /:;=,.');

-- XML-escape a string for element content and attribute values.
CREATE OR REPLACE MACRO marc_xml_escape(s) AS
    replace(replace(replace(replace(s, '&', '&amp;'),
                            '<', '&lt;'),
                    '>', '&gt;'),
            '"', '&quot;');

-- ---------------------------------------------------------------------------
-- Fixed-field explosion: leader and 008 as STRUCTs (positions per the
-- published MARC 21 leader/008 layouts, 0-based in the comments).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_leader_struct(leader) AS {
    'record_length':       TRY_CAST(substr(leader, 1, 5) AS INTEGER),  -- LDR/00-04
    'status':              substr(leader, 6, 1),                       -- LDR/05
    'type':                substr(leader, 7, 1),                       -- LDR/06
    'bib_level':           substr(leader, 8, 1),                       -- LDR/07
    'control_type':        substr(leader, 9, 1),                      -- LDR/08
    'encoding':            marc_encoding_scheme(leader),               -- LDR/09
    'indicator_count':     substr(leader, 11, 1),                      -- LDR/10
    'subfield_code_count': substr(leader, 12, 1),                      -- LDR/11
    'base_address':        TRY_CAST(substr(leader, 13, 5) AS INTEGER), -- LDR/12-16
    'encoding_level':      substr(leader, 18, 1),                      -- LDR/17
    'cataloging_form':     substr(leader, 19, 1),                      -- LDR/18
    'multipart_level':     substr(leader, 20, 1)                       -- LDR/19
};

-- Books-material positions of 008 (008/18-34 for Leader/06 in a,t with
-- Leader/07 in a,c,d,m), per the published "008 - Books" layout.
CREATE OR REPLACE MACRO marc_008_books(v) AS {
    'illustrations':          marc_control_pos(v, 18, 4),
    'audience':               marc_control_pos(v, 22, 1),
    'form':                   marc_control_pos(v, 23, 1),
    'nature_of_contents':     marc_control_pos(v, 24, 4),
    'government_publication': marc_control_pos(v, 28, 1),
    'conference':             marc_control_pos(v, 29, 1),
    'festschrift':            marc_control_pos(v, 30, 1),
    'index':                  marc_control_pos(v, 31, 1),
    'literary_form':          marc_control_pos(v, 33, 1),
    'biography':              marc_control_pos(v, 34, 1)
};

-- All-materials positions (008/00-17, 35-39) plus the books sub-struct when
-- the leader says books; helper so marc_008_struct extracts the 008 once.
CREATE OR REPLACE MACRO marc_008_parts(v, is_books) AS {
    'date_entered':      marc_control_pos(v, 0, 6),
    'date_type':         marc_control_pos(v, 6, 1),
    'date1':             marc_control_pos(v, 7, 4),
    'date2':             marc_control_pos(v, 11, 4),
    'place':             marc_control_pos(v, 15, 3),
    'language':          marc_control_pos(v, 35, 3),
    'modified':          marc_control_pos(v, 38, 1),
    'cataloging_source': marc_control_pos(v, 39, 1),
    'books':             CASE WHEN is_books THEN marc_008_books(v) END
};

-- NULL when the record has no 008.
CREATE OR REPLACE MACRO marc_008_struct(leader, fields) AS
    CASE WHEN marc_control_field(fields, '008') IS NOT NULL
         THEN marc_008_parts(marc_control_field(fields, '008'),
                             marc_record_type(leader) IN ('a', 't')
                             AND marc_bib_level(leader) IN ('a', 'c', 'd', 'm'))
    END;

-- ---------------------------------------------------------------------------
-- QA report table macros over a whole file.
-- ---------------------------------------------------------------------------

-- Tag frequency: occurrences, records containing the tag, and the share of
-- records containing it.
CREATE OR REPLACE MACRO marc_report_tags(path) AS TABLE
SELECT tag,
       count(*)                          AS "count",
       count(DISTINCT (file, record_no)) AS records_with,
       round(100.0 * count(DISTINCT (file, record_no)) /
             (SELECT count(*) FROM read_marc(path)), 1) AS pct_records
FROM marc_readfields(path)
GROUP BY tag
ORDER BY tag;

-- Subfield frequency within one tag.
CREATE OR REPLACE MACRO marc_report_subfields(path, tag_) AS TABLE
SELECT code,
       count(*)                          AS "count",
       count(DISTINCT (file, record_no)) AS records_with
FROM read_marc_subfields(path)
WHERE tag = tag_ AND code IS NOT NULL
GROUP BY code
ORDER BY code;

-- Per-record completeness.  The 0-100 score is a weighted sum: title 30,
-- author (1XX name) 15, subject (any 6XX) 15, ISBN 10, language (008/35-37 or
-- 041$a) 10, publication (260/264) 10, physical description (300) 10.
CREATE OR REPLACE MACRO marc_report_completeness(path) AS TABLE
SELECT file, record_no, control_number,
       has_title, has_author, has_subject, has_isbn,
       has_language, has_publication, has_physical,
       30 * has_title::INT + 15 * has_author::INT + 15 * has_subject::INT +
       10 * has_isbn::INT + 10 * has_language::INT +
       10 * has_publication::INT + 10 * has_physical::INT AS completeness
FROM (
    SELECT file, record_no, control_number,
           marc_subfield(fields, '245', 'a') IS NOT NULL              AS has_title,
           len(list_filter(fields, lambda f:
               f.tag IN ('100', '110', '111'))) > 0                   AS has_author,
           len(list_filter(fields, lambda f: f.tag LIKE '6%')) > 0    AS has_subject,
           len(marc_subfields(fields, '020', 'a')) > 0                AS has_isbn,
           coalesce(nullif(trim(marc_control_pos(
               marc_control_field(fields, '008'), 35, 3)), '') IS NOT NULL, false)
           OR len(marc_subfields(fields, '041', 'a')) > 0             AS has_language,
           len(list_filter(fields, lambda f:
               f.tag IN ('260', '264'))) > 0                          AS has_publication,
           len(marc_fields(fields, '300')) > 0                        AS has_physical
    FROM read_marc(path))
ORDER BY file, record_no;

-- One row per structural violation (records that pass produce no rows).
CREATE OR REPLACE MACRO marc_report_errors(path) AS TABLE
SELECT file, record_no, control_number,
       unnest(marc_validate(leader, fields)) AS violation
FROM read_marc(path)
ORDER BY file, record_no;

-- ---------------------------------------------------------------------------
-- FOLIO data-import preparation: expectations the FOLIO importer places on
-- incoming bibliographic records.  FOLIO reserves 999 ff (ind1='f', ind2='f')
-- for its own instance/SRS identifiers, matches on 001+003, and stores
-- records as UTF-8 (Leader/09 = 'a').
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_folio_check(leader, fields) AS
    list_filter([
        CASE WHEN len(list_filter(fields, lambda f: f.tag = '001')) = 0
             THEN 'no 001: FOLIO data import uses 001 as the incoming record identifier' END,
        CASE WHEN len(list_filter(fields, lambda f: f.tag = '001')) > 0
              AND len(list_filter(fields, lambda f: f.tag = '003')) = 0
             THEN '001 without 003: FOLIO qualifies the 001 control number by the 003 source' END,
        CASE WHEN len(list_filter(fields, lambda f:
                        f.tag = '999' AND f.ind1 = 'f' AND f.ind2 = 'f')) > 0
             THEN '999 ff present: FOLIO reserves 999 ff for its own instance/SRS identifiers' END,
        CASE WHEN substr(leader, 10, 1) != 'a'
             THEN 'leader/09 is not ''a'': FOLIO expects UTF-8 encoded records' END
    ], lambda v: v IS NOT NULL);

-- ---------------------------------------------------------------------------
-- Inventory mapping: a FOLIO-instance-shaped STRUCT built from the MARC 21
-- field definitions (modeled on FOLIO's default bib-to-instance mapping).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_instance(leader, fields) AS {
    'title': nullif(marc_trim_punct(concat_ws(' ',
                 marc_subfield(fields, '245', 'a'),
                 marc_subfield(fields, '245', 'b'),
                 marc_subfield(fields, '245', 'c'))), ''),
    'contributors': list_filter(
        list_transform(
            list_filter(fields, lambda f:
                f.tag IN ('100', '110', '111', '700', '710', '711')
                AND f.subfields IS NOT NULL),
            lambda f: marc_trim_punct(
                list_filter(f.subfields, lambda s: s.code = 'a')[1].value)),
        lambda v: v IS NOT NULL),
    'identifiers':
        list_transform(marc_subfields(fields, '010', 'a'),
                       lambda v: {'type': 'lccn', 'value': trim(v)}) ||
        list_transform(marc_subfields(fields, '020', 'a'),
                       lambda v: {'type': 'isbn', 'value': v}) ||
        list_transform(marc_subfields(fields, '022', 'a'),
                       lambda v: {'type': 'issn', 'value': v}) ||
        list_transform(marc_subfields(fields, '035', 'a'),
                       lambda v: {'type': 'system-control-number', 'value': v}),
    'publication': {
        'place': marc_trim_punct(coalesce(marc_subfield(fields, '260', 'a'),
                                          marc_subfield(fields, '264', 'a'))),
        'publisher': marc_trim_punct(coalesce(marc_subfield(fields, '260', 'b'),
                                              marc_subfield(fields, '264', 'b'))),
        'date': marc_trim_punct(coalesce(marc_subfield(fields, '260', 'c'),
                                         marc_subfield(fields, '264', 'c')))
    },
    'languages': list_filter(
        [nullif(trim(marc_control_pos(marc_control_field(fields, '008'), 35, 3)), '')]
        || marc_subfields(fields, '041', 'a'),
        lambda v: v IS NOT NULL),
    'subjects': list_filter(
        list_transform(
            list_filter(fields, lambda f: f.tag LIKE '6%' AND f.subfields IS NOT NULL),
            lambda f: marc_trim_punct(
                list_filter(f.subfields, lambda s: s.code = 'a')[1].value)),
        lambda v: v IS NOT NULL),
    'edition': marc_trim_punct(marc_subfield(fields, '250', 'a')),
    'physical_description': marc_trim_punct(marc_subfield(fields, '300', 'a'))
};

-- ---------------------------------------------------------------------------
-- Crosswalks: Dublin Core (per the LC MARC-to-DC crosswalk's field mapping)
-- and a simple well-formed MODS XML rendering.
-- ---------------------------------------------------------------------------

-- MODS typeOfResource vocabulary from Leader/06 (also used as the DC type).
CREATE OR REPLACE MACRO marc_type_of_resource(leader) AS
    CASE marc_record_type(leader)
        WHEN 'a' THEN 'text'
        WHEN 't' THEN 'text'
        WHEN 'e' THEN 'cartographic'
        WHEN 'f' THEN 'cartographic'
        WHEN 'c' THEN 'notated music'
        WHEN 'd' THEN 'notated music'
        WHEN 'i' THEN 'sound recording-nonmusical'
        WHEN 'j' THEN 'sound recording-musical'
        WHEN 'k' THEN 'still image'
        WHEN 'g' THEN 'moving image'
        WHEN 'r' THEN 'three dimensional object'
        WHEN 'm' THEN 'software, multimedia'
        WHEN 'p' THEN 'mixed material'
        WHEN 'o' THEN 'kit'
    END;

-- Simple Dublin Core: title 245$a$b, creator 1XX$a, contributor 7XX$a,
-- subject 6XX$a, description 520/500, publisher+date 260/264 (date falls back
-- to 008/07-10), format 300$a, identifier 020/022/856$u, language 008/35-37
-- then 041$a, relation 530/787$t, coverage 651$a, rights 506/540.
CREATE OR REPLACE MACRO marc_dublin_core(leader, fields) AS {
    'title': nullif(marc_trim_punct(concat_ws(' ',
                 marc_subfield(fields, '245', 'a'),
                 marc_subfield(fields, '245', 'b'))), ''),
    'creator': marc_trim_punct(coalesce(marc_subfield(fields, '100', 'a'),
                                        marc_subfield(fields, '110', 'a'),
                                        marc_subfield(fields, '111', 'a'))),
    'subject': list_filter(
        list_transform(
            list_filter(fields, lambda f: f.tag LIKE '6%' AND f.subfields IS NOT NULL),
            lambda f: marc_trim_punct(
                list_filter(f.subfields, lambda s: s.code = 'a')[1].value)),
        lambda v: v IS NOT NULL),
    'description': coalesce(marc_subfield(fields, '520', 'a'),
                            marc_subfield(fields, '500', 'a')),
    'publisher': marc_trim_punct(coalesce(marc_subfield(fields, '260', 'b'),
                                          marc_subfield(fields, '264', 'b'))),
    'contributor': list_filter(
        list_transform(
            list_filter(fields, lambda f:
                f.tag IN ('700', '710', '711') AND f.subfields IS NOT NULL),
            lambda f: marc_trim_punct(
                list_filter(f.subfields, lambda s: s.code = 'a')[1].value)),
        lambda v: v IS NOT NULL),
    'date': marc_trim_punct(coalesce(
        marc_subfield(fields, '260', 'c'),
        marc_subfield(fields, '264', 'c'),
        nullif(trim(marc_control_pos(marc_control_field(fields, '008'), 7, 4)), ''))),
    'type': marc_type_of_resource(leader),
    'format': marc_trim_punct(marc_subfield(fields, '300', 'a')),
    'identifier': marc_subfields(fields, '020', 'a')
               || marc_subfields(fields, '022', 'a')
               || marc_subfields(fields, '856', 'u'),
    'language': coalesce(
        nullif(trim(marc_control_pos(marc_control_field(fields, '008'), 35, 3)), ''),
        marc_subfield(fields, '041', 'a')),
    'relation': marc_trim_punct(coalesce(marc_subfield(fields, '530', 'a'),
                                         marc_subfield(fields, '787', 't'))),
    'coverage': marc_trim_punct(marc_subfield(fields, '651', 'a')),
    'rights': coalesce(marc_subfield(fields, '506', 'a'),
                       marc_subfield(fields, '540', 'a'))
};

-- <originInfo> from an instance publication struct (helper for marc_mods_xml).
CREATE OR REPLACE MACRO marc_mods_origininfo(pub) AS
    CASE WHEN pub.place IS NULL AND pub.publisher IS NULL
              AND struct_extract(pub, 'date') IS NULL
         THEN ''
         ELSE concat('<originInfo>',
              CASE WHEN pub.place IS NOT NULL
                   THEN '<place><placeTerm type="text">' || marc_xml_escape(pub.place)
                        || '</placeTerm></place>' ELSE '' END,
              CASE WHEN pub.publisher IS NOT NULL
                   THEN '<publisher>' || marc_xml_escape(pub.publisher) || '</publisher>'
                   ELSE '' END,
              CASE WHEN struct_extract(pub, 'date') IS NOT NULL
                   THEN '<dateIssued>' || marc_xml_escape(struct_extract(pub, 'date'))
                        || '</dateIssued>' ELSE '' END,
              '</originInfo>')
    END;

-- MODS XML string: titleInfo, name, typeOfResource, originInfo, language,
-- physicalDescription, subject, identifier.  Elements are emitted only when
-- their source data exists, so the output stays well-formed and minimal.
CREATE OR REPLACE MACRO marc_mods_xml(leader, fields) AS
    concat(
        '<mods xmlns="http://www.loc.gov/mods/v3">',
        CASE WHEN marc_subfield(fields, '245', 'a') IS NOT NULL
             THEN '<titleInfo><title>' ||
                  marc_xml_escape(marc_trim_punct(concat_ws(' ',
                      marc_subfield(fields, '245', 'a'),
                      marc_subfield(fields, '245', 'b')))) ||
                  '</title></titleInfo>'
             ELSE '' END,
        coalesce(list_aggregate(
            list_transform(
                list_filter(fields, lambda f:
                    f.tag IN ('100', '110', '111', '700', '710', '711')
                    AND f.subfields IS NOT NULL),
                lambda f: '<name><namePart>' ||
                    marc_xml_escape(marc_trim_punct(
                        list_filter(f.subfields, lambda s: s.code = 'a')[1].value)) ||
                    '</namePart></name>'),
            'string_agg', ''), ''),
        CASE WHEN marc_type_of_resource(leader) IS NOT NULL
             THEN '<typeOfResource>' || marc_type_of_resource(leader) || '</typeOfResource>'
             ELSE '' END,
        marc_mods_origininfo(struct_extract(marc_instance(leader, fields), 'publication')),
        CASE WHEN nullif(trim(marc_control_pos(marc_control_field(fields, '008'), 35, 3)), '') IS NOT NULL
             THEN '<language><languageTerm type="code" authority="iso639-2b">' ||
                  trim(marc_control_pos(marc_control_field(fields, '008'), 35, 3)) ||
                  '</languageTerm></language>'
             ELSE '' END,
        CASE WHEN marc_subfield(fields, '300', 'a') IS NOT NULL
             THEN '<physicalDescription><extent>' ||
                  marc_xml_escape(marc_trim_punct(marc_subfield(fields, '300', 'a'))) ||
                  '</extent></physicalDescription>'
             ELSE '' END,
        coalesce(list_aggregate(
            list_transform(
                list_filter(fields, lambda f: f.tag LIKE '6%' AND f.subfields IS NOT NULL),
                lambda f: CASE WHEN len(list_filter(f.subfields, lambda s: s.code = 'a')) > 0
                    THEN '<subject><topic>' ||
                         marc_xml_escape(marc_trim_punct(
                             list_filter(f.subfields, lambda s: s.code = 'a')[1].value)) ||
                         '</topic></subject>' END),
            'string_agg', ''), ''),
        coalesce(list_aggregate(
            list_transform(marc_subfields(fields, '020', 'a'),
                lambda v: '<identifier type="isbn">' || marc_xml_escape(v) || '</identifier>'),
            'string_agg', ''), ''),
        coalesce(list_aggregate(
            list_transform(marc_subfields(fields, '022', 'a'),
                lambda v: '<identifier type="issn">' || marc_xml_escape(v) || '</identifier>'),
            'string_agg', ''), ''),
        '</mods>');

-- ---------------------------------------------------------------------------
-- Linked data: URIs and authority identifiers carried in $0/$1.
-- ---------------------------------------------------------------------------

-- Every $0/$1 value that looks like a URI, with its field tag and code.
CREATE OR REPLACE MACRO marc_uris(fields) AS
    flatten(list_transform(
        list_filter(fields, lambda f: f.subfields IS NOT NULL),
        lambda f: list_transform(
            list_filter(f.subfields, lambda s:
                s.code IN ('0', '1') AND s.value LIKE 'http%'),
            lambda s: {'tag': f.tag, 'code': s.code, 'uri': s.value})));

-- All $0/$1 values (URI-shaped or not), for the source-specific filters below.
CREATE OR REPLACE MACRO marc_sf01(fields) AS
    list_transform(
        list_filter(
            flatten(list_transform(
                list_filter(fields, lambda f: f.subfields IS NOT NULL),
                lambda f: f.subfields)),
            lambda s: s.code IN ('0', '1')),
        lambda s: s.value);

-- Library of Congress identifiers (id.loc.gov URIs).
CREATE OR REPLACE MACRO marc_ids_lc(fields) AS
    list_filter(marc_sf01(fields), lambda v: v LIKE '%id.loc.gov%');

-- VIAF identifiers (viaf.org URIs).
CREATE OR REPLACE MACRO marc_ids_viaf(fields) AS
    list_filter(marc_sf01(fields), lambda v: v LIKE '%viaf.org%');

-- OCLC FAST identifiers: '(OCoLC)fst...'-prefixed $0s and FAST URIs.
CREATE OR REPLACE MACRO marc_ids_fast(fields) AS
    list_filter(marc_sf01(fields), lambda v:
        v LIKE '(OCoLC)fst%' OR v LIKE '%worldcat.org/fast%' OR v LIKE '%fast.oclc.org%');

-- ---------------------------------------------------------------------------
-- Serials holdings patterns: 853-855 captions paired with 863-865 values.
-- ---------------------------------------------------------------------------

-- Zip a caption field's $a-$f with a value field's $a-$f by code:
-- one {code, cap, val} per enumeration subfield of the value field.
CREATE OR REPLACE MACRO marc_86x_zip(cap_f, val_f) AS
    list_filter(
        list_transform(val_f.subfields, lambda s: {
            'code': s.code,
            'cap': list_filter(cap_f.subfields, lambda c: c.code = s.code)[1].value,
            'val': s.value}),
        lambda p: p.code BETWEEN 'a' AND 'f');

-- Pair each 863/864/865 with its 853/854/855 caption on the $8 link (the part
-- of the value field's $8 before '.', since 863 $8 carries link.sequence).
-- caption_field is NULL when no caption with a matching $8 exists.
CREATE OR REPLACE MACRO marc_holdings_pairs(fields) AS
    list_transform(
        list_filter(fields, lambda f:
            f.tag IN ('863', '864', '865') AND f.subfields IS NOT NULL),
        lambda v: {
            'link': split_part(
                list_filter(v.subfields, lambda s: s.code = '8')[1].value, '.', 1),
            'caption_field': list_filter(fields, lambda c:
                c.tag = CASE v.tag WHEN '863' THEN '853'
                                   WHEN '864' THEN '854'
                                   ELSE '855' END
                AND c.subfields IS NOT NULL
                AND list_filter(c.subfields, lambda s2: s2.code = '8')[1].value =
                    split_part(list_filter(v.subfields, lambda s3: s3.code = '8')[1].value,
                               '.', 1))[1],
            'value_field': v});

-- Human-readable enumeration/chronology, e.g. "v.3:no.2(1998:Mar.)":
-- caption+value pairs whose caption is not parenthesized join as
-- caption||value on ':'; parenthesized captions (chronology, e.g. "(year)")
-- contribute just their values, joined on ':' inside one trailing "(...)".
-- Simplification (documented): plain caption:value joins over $a-$f, no
-- chronology arithmetic or compressed-holdings expansion.
CREATE OR REPLACE MACRO marc_expand_863(cap_f, val_f) AS
    coalesce(list_aggregate(
        list_transform(
            list_filter(marc_86x_zip(cap_f, val_f),
                        lambda p: p.cap IS NULL OR p.cap NOT LIKE '(%'),
            lambda p: coalesce(p.cap, '') || p.val),
        'string_agg', ':'), '') ||
    CASE WHEN len(list_filter(marc_86x_zip(cap_f, val_f),
                              lambda p: p.cap LIKE '(%')) > 0
         THEN '(' || list_aggregate(
                  list_transform(
                      list_filter(marc_86x_zip(cap_f, val_f),
                                  lambda p: p.cap LIKE '(%'),
                      lambda p: p.val),
                  'string_agg', ':') || ')'
         ELSE '' END;

-- ---------------------------------------------------------------------------
-- Validation rulepacks: MARC 21 bibliographic / authority / holdings Avram
-- schemas (schemas/*.avram.json) embedded as constants.
-- ---------------------------------------------------------------------------
-- BEGIN GENERATED rulepack macros (tools/gen_schema_macros.py; edit schemas/*.json, not this block)
-- marc_validate_bib: schemas/marc21_bibliographic.avram.json embedded as a constant so the
-- Avram schema is parsed once at bind time.
CREATE OR REPLACE MACRO marc_validate_bib(leader, fields) AS
    marc_validate_avram(leader, fields, '{"title":"MARC 21 Format for Bibliographic Data (rulepack subset)","description":"Avram-subset rulepack written from the published LC MARC 21 bibliographic documentation. Covers the consequential repeatability, requiredness, indicator and subfield rules for the most common tags; it is deliberately useful-not-exhaustive, and tags absent from `fields` are not flagged. Limits of the Avram subset: cross-field rules are not expressible, so `1XX mutually exclusive (at most one of 100/110/111/130)`, `260 vs 264 choice`, and `880 must mirror its linked field` cannot be asserted here - each 1XX is individually marked non-repeatable instead. Only 008 and 245 are marked required (LC national-level records also mandate 040, but requiring it here would flag large amounts of legitimate data).","family":"marc","language":"eng","fields":{"001":{"repeatable":false,"description":"Control Number"},"003":{"repeatable":false,"description":"Control Number Identifier"},"005":{"repeatable":false,"description":"Date and Time of Latest Transaction"},"006":{"repeatable":true,"description":"Fixed-Length Data Elements - Additional Material Characteristics"},"007":{"repeatable":true,"description":"Physical Description Fixed Field"},"008":{"repeatable":false,"required":true,"description":"Fixed-Length Data Elements"},"010":{"repeatable":false,"description":"Library of Congress Control Number","subfields":{"a":{},"b":{"repeatable":true},"z":{"repeatable":true},"8":{"repeatable":true}}},"015":{"repeatable":true,"description":"National Bibliography Number"},"016":{"repeatable":true,"description":"National Bibliographic Agency Control Number"},"020":{"repeatable":true,"description":"International Standard Book Number","subfields":{"a":{},"c":{},"q":{"repeatable":true},"z":{"repeatable":true},"6":{},"8":{"repeatable":true}}},"022":{"repeatable":true,"description":"International Standard Serial Number","indicator1":{"codes":{" ":{},"0":{},"1":{}}},"subfields":{"a":{},"l":{},"m":{},"y":{"repeatable":true},"z":{"repeatable":true},"2":{},"6":{},"8":{"repeatable":true}}},"024":{"repeatable":true,"description":"Other Standard Identifier","indicator1":{"codes":{"0":{},"1":{},"2":{},"3":{},"4":{},"7":{},"8":{}}}},"028":{"repeatable":true,"description":"Publisher or Distributor Number"},"035":{"repeatable":true,"description":"System Control Number","subfields":{"a":{},"z":{"repeatable":true},"6":{},"8":{"repeatable":true}}},"040":{"repeatable":false,"description":"Cataloging Source","subfields":{"a":{},"b":{},"c":{},"d":{"repeatable":true},"e":{"repeatable":true},"6":{},"8":{"repeatable":true}}},"041":{"repeatable":true,"description":"Language Code","indicator1":{"codes":{" ":{},"0":{},"1":{}}},"indicator2":{"codes":{" ":{},"7":{}}}},"042":{"repeatable":false,"description":"Authentication Code"},"043":{"repeatable":false,"description":"Geographic Area Code"},"050":{"repeatable":true,"description":"Library of Congress Call Number","indicator1":{"codes":{" ":{},"0":{},"1":{}}},"indicator2":{"codes":{"0":{},"4":{}}},"subfields":{"a":{"repeatable":true},"b":{},"3":{},"6":{},"8":{"repeatable":true}}},"060":{"repeatable":true,"description":"National Library of Medicine Call Number"},"082":{"repeatable":true,"description":"Dewey Decimal Classification Number","indicator1":{"codes":{"0":{},"1":{},"7":{}}},"indicator2":{"codes":{" ":{},"0":{},"4":{}}},"subfields":{"a":{"repeatable":true},"b":{},"m":{},"q":{},"2":{},"6":{},"8":{"repeatable":true}}},"084":{"repeatable":true,"description":"Other Classification Number"},"100":{"repeatable":false,"description":"Main Entry - Personal Name (1XX: at most one of 100/110/111/130 per record, not expressible in Avram)","indicator1":{"codes":{"0":{},"1":{},"3":{}}},"indicator2":{"codes":{" ":{}}},"subfields":{"a":{},"b":{"repeatable":true},"c":{"repeatable":true},"d":{},"e":{"repeatable":true},"f":{},"g":{"repeatable":true},"j":{"repeatable":true},"k":{"repeatable":true},"l":{},"n":{"repeatable":true},"p":{"repeatable":true},"q":{},"t":{},"u":{},"0":{"repeatable":true},"1":{"repeatable":true},"2":{},"4":{"repeatable":true},"6":{},"8":{"repeatable":true}}},"110":{"repeatable":false,"description":"Main Entry - Corporate Name","indicator1":{"codes":{"0":{},"1":{},"2":{}}},"indicator2":{"codes":{" ":{}}},"subfields":{"a":{},"b":{"repeatable":true},"c":{"repeatable":true},"d":{"repeatable":true},"e":{"repeatable":true},"f":{},"g":{"repeatable":true},"k":{"repeatable":true},"l":{},"n":{"repeatable":true},"p":{"repeatable":true},"t":{},"u":{},"0":{"repeatable":true},"1":{"repeatable":true},"2":{},"4":{"repeatable":true},"6":{},"8":{"repeatable":true}}},"111":{"repeatable":false,"description":"Main Entry - Meeting Name","indicator1":{"codes":{"0":{},"1":{},"2":{}}},"indicator2":{"codes":{" ":{}}},"subfields":{"a":{},"c":{"repeatable":true},"d":{"repeatable":true},"e":{"repeatable":true},"f":{},"g":{"repeatable":true},"j":{"repeatable":true},"k":{"repeatable":true},"l":{},"n":{"repeatable":true},"p":{"repeatable":true},"q":{},"t":{},"u":{},"0":{"repeatable":true},"1":{"repeatable":true},"2":{},"4":{"repeatable":true},"6":{},"8":{"repeatable":true}}},"130":{"repeatable":false,"description":"Main Entry - Uniform Title","indicator2":{"codes":{" ":{}}}},"210":{"repeatable":true,"description":"Abbreviated Title"},"222":{"repeatable":true,"description":"Key Title"},"240":{"repeatable":false,"description":"Uniform Title","indicator1":{"codes":{"0":{},"1":{}}}},"245":{"repeatable":false,"required":true,"description":"Title Statement","indicator1":{"codes":{"0":{},"1":{}}},"indicator2":{"codes":{"0":{},"1":{},"2":{},"3":{},"4":{},"5":{},"6":{},"7":{},"8":{},"9":{}}},"subfields":{"a":{"required":true},"b":{},"c":{},"f":{},"g":{},"h":{},"k":{"repeatable":true},"n":{"repeatable":true},"p":{"repeatable":true},"s":{},"6":{},"8":{"repeatable":true}}},"246":{"repeatable":true,"description":"Varying Form of Title"},"250":{"repeatable":true,"description":"Edition Statement (repeatable since the 2014 format update)","subfields":{"a":{},"b":{},"3":{},"6":{},"8":{"repeatable":true}}},"255":{"repeatable":true,"description":"Cartographic Mathematical Data"},"260":{"repeatable":true,"description":"Publication, Distribution, etc. (Imprint)","indicator1":{"codes":{" ":{},"2":{},"3":{}}},"subfields":{"a":{"repeatable":true},"b":{"repeatable":true},"c":{"repeatable":true},"e":{"repeatable":true},"f":{"repeatable":true},"g":{"repeatable":true},"3":{},"6":{},"8":{"repeatable":true}}},"263":{"repeatable":false,"description":"Projected Publication Date"},"264":{"repeatable":true,"description":"Production, Publication, Distribution, Manufacture, and Copyright Notice","indicator1":{"codes":{" ":{},"2":{},"3":{}}},"indicator2":{"codes":{"0":{},"1":{},"2":{},"3":{},"4":{}}},"subfields":{"a":{"repeatable":true},"b":{"repeatable":true},"c":{"repeatable":true},"3":{},"6":{},"8":{"repeatable":true}}},"300":{"repeatable":true,"description":"Physical Description","subfields":{"a":{"repeatable":true},"b":{},"c":{"repeatable":true},"e":{},"f":{"repeatable":true},"g":{"repeatable":true},"3":{},"6":{},"8":{"repeatable":true}}},"336":{"repeatable":true,"description":"Content Type"},"337":{"repeatable":true,"description":"Media Type"},"338":{"repeatable":true,"description":"Carrier Type"},"490":{"repeatable":true,"description":"Series Statement","indicator1":{"codes":{"0":{},"1":{}}},"subfields":{"a":{"repeatable":true},"l":{},"v":{"repeatable":true},"x":{"repeatable":true},"3":{},"6":{},"8":{"repeatable":true}}},"500":{"repeatable":true,"description":"General Note","subfields":{"a":{},"3":{},"5":{},"6":{},"8":{"repeatable":true}}},"504":{"repeatable":true,"description":"Bibliography, etc. Note","subfields":{"a":{},"b":{},"6":{},"8":{"repeatable":true}}},"505":{"repeatable":true,"description":"Formatted Contents Note","indicator1":{"codes":{"0":{},"1":{},"2":{},"8":{}}},"indicator2":{"codes":{" ":{},"0":{}}}},"520":{"repeatable":true,"description":"Summary, etc.","indicator1":{"codes":{" ":{},"0":{},"1":{},"2":{},"3":{},"4":{},"8":{}}}},"546":{"repeatable":true,"description":"Language Note"},"600":{"repeatable":true,"description":"Subject Added Entry - Personal Name","indicator1":{"codes":{"0":{},"1":{},"3":{}}},"indicator2":{"codes":{"0":{},"1":{},"2":{},"3":{},"4":{},"5":{},"6":{},"7":{}}}},"610":{"repeatable":true,"description":"Subject Added Entry - Corporate Name","indicator1":{"codes":{"0":{},"1":{},"2":{}}},"indicator2":{"codes":{"0":{},"1":{},"2":{},"3":{},"4":{},"5":{},"6":{},"7":{}}}},"611":{"repeatable":true,"description":"Subject Added Entry - Meeting Name","indicator1":{"codes":{"0":{},"1":{},"2":{}}},"indicator2":{"codes":{"0":{},"1":{},"2":{},"3":{},"4":{},"5":{},"6":{},"7":{}}}},"630":{"repeatable":true,"description":"Subject Added Entry - Uniform Title","indicator2":{"codes":{"0":{},"1":{},"2":{},"3":{},"4":{},"5":{},"6":{},"7":{}}}},"650":{"repeatable":true,"description":"Subject Added Entry - Topical Term","indicator1":{"codes":{" ":{},"0":{},"1":{},"2":{}}},"indicator2":{"codes":{"0":{},"1":{},"2":{},"3":{},"4":{},"5":{},"6":{},"7":{}}},"subfields":{"a":{},"b":{},"c":{},"d":{},"e":{"repeatable":true},"g":{"repeatable":true},"v":{"repeatable":true},"x":{"repeatable":true},"y":{"repeatable":true},"z":{"repeatable":true},"0":{"repeatable":true},"1":{"repeatable":true},"2":{},"3":{},"4":{"repeatable":true},"6":{},"8":{"repeatable":true}}},"651":{"repeatable":true,"description":"Subject Added Entry - Geographic Name","indicator2":{"codes":{"0":{},"1":{},"2":{},"3":{},"4":{},"5":{},"6":{},"7":{}}},"subfields":{"a":{},"e":{"repeatable":true},"g":{"repeatable":true},"v":{"repeatable":true},"x":{"repeatable":true},"y":{"repeatable":true},"z":{"repeatable":true},"0":{"repeatable":true},"1":{"repeatable":true},"2":{},"3":{},"4":{"repeatable":true},"6":{},"8":{"repeatable":true}}},"653":{"repeatable":true,"description":"Index Term - Uncontrolled"},"655":{"repeatable":true,"description":"Index Term - Genre/Form","indicator1":{"codes":{" ":{},"0":{}}},"indicator2":{"codes":{"0":{},"1":{},"2":{},"3":{},"4":{},"5":{},"6":{},"7":{}}}},"700":{"repeatable":true,"description":"Added Entry - Personal Name","indicator1":{"codes":{"0":{},"1":{},"3":{}}},"indicator2":{"codes":{" ":{},"2":{}}}},"710":{"repeatable":true,"description":"Added Entry - Corporate Name","indicator1":{"codes":{"0":{},"1":{},"2":{}}},"indicator2":{"codes":{" ":{},"2":{}}}},"711":{"repeatable":true,"description":"Added Entry - Meeting Name","indicator1":{"codes":{"0":{},"1":{},"2":{}}},"indicator2":{"codes":{" ":{},"2":{}}}},"730":{"repeatable":true,"description":"Added Entry - Uniform Title","indicator2":{"codes":{" ":{},"2":{}}}},"740":{"repeatable":true,"description":"Added Entry - Uncontrolled Related/Analytical Title","indicator2":{"codes":{" ":{},"2":{}}}},"760":{"repeatable":true,"description":"Main Series Entry"},"770":{"repeatable":true,"description":"Supplement/Special Issue Entry"},"773":{"repeatable":true,"description":"Host Item Entry"},"776":{"repeatable":true,"description":"Additional Physical Form Entry"},"780":{"repeatable":true,"description":"Preceding Entry"},"785":{"repeatable":true,"description":"Succeeding Entry"},"787":{"repeatable":true,"description":"Other Relationship Entry"},"800":{"repeatable":true,"description":"Series Added Entry - Personal Name","indicator1":{"codes":{"0":{},"1":{},"3":{}}}},"810":{"repeatable":true,"description":"Series Added Entry - Corporate Name","indicator1":{"codes":{"0":{},"1":{},"2":{}}}},"811":{"repeatable":true,"description":"Series Added Entry - Meeting Name","indicator1":{"codes":{"0":{},"1":{},"2":{}}}},"830":{"repeatable":true,"description":"Series Added Entry - Uniform Title"},"850":{"repeatable":true,"description":"Holding Institution"},"852":{"repeatable":true,"description":"Location"},"856":{"repeatable":true,"description":"Electronic Location and Access","indicator1":{"codes":{" ":{},"0":{},"1":{},"2":{},"3":{},"4":{},"7":{}}},"indicator2":{"codes":{" ":{},"0":{},"1":{},"2":{},"8":{}}}},"880":{"repeatable":true,"description":"Alternate Graphic Representation (subfields mirror the linked field, so they are left unconstrained)"}}}');

-- marc_validate_auth: schemas/marc21_authority.avram.json embedded as a constant so the
-- Avram schema is parsed once at bind time.
CREATE OR REPLACE MACRO marc_validate_auth(leader, fields) AS
    marc_validate_avram(leader, fields, '{"title":"MARC 21 Format for Authority Data (rulepack subset)","description":"Avram-subset rulepack written from the published LC MARC 21 authority documentation. Limits of the Avram subset: an authority record must contain exactly one 1XX heading (one of 100/110/111/130/147/148/150/151/155), which is a cross-field rule Avram cannot express - each 1XX is individually marked non-repeatable instead, and none is individually marked required. Only 008 is marked required.","family":"marc","language":"eng","fields":{"001":{"repeatable":false,"description":"Control Number"},"003":{"repeatable":false,"description":"Control Number Identifier"},"005":{"repeatable":false,"description":"Date and Time of Latest Transaction"},"008":{"repeatable":false,"required":true,"description":"Fixed-Length Data Elements"},"010":{"repeatable":false,"description":"Library of Congress Control Number","subfields":{"a":{},"z":{"repeatable":true},"8":{"repeatable":true}}},"016":{"repeatable":true,"description":"National Bibliographic Agency Control Number"},"024":{"repeatable":true,"description":"Other Standard Identifier"},"035":{"repeatable":true,"description":"System Control Number","subfields":{"a":{},"z":{"repeatable":true},"6":{},"8":{"repeatable":true}}},"040":{"repeatable":false,"description":"Cataloging Source","subfields":{"a":{},"b":{},"c":{},"d":{"repeatable":true},"e":{"repeatable":true},"f":{},"6":{},"8":{"repeatable":true}}},"100":{"repeatable":false,"description":"Heading - Personal Name (exactly one 1XX per record, not expressible in Avram)","indicator1":{"codes":{"0":{},"1":{},"3":{}}},"indicator2":{"codes":{" ":{}}},"subfields":{"a":{},"b":{"repeatable":true},"c":{"repeatable":true},"d":{},"f":{},"g":{"repeatable":true},"q":{},"t":{},"v":{"repeatable":true},"x":{"repeatable":true},"y":{"repeatable":true},"z":{"repeatable":true},"6":{},"8":{"repeatable":true}}},"110":{"repeatable":false,"description":"Heading - Corporate Name","indicator1":{"codes":{"0":{},"1":{},"2":{}}},"indicator2":{"codes":{" ":{}}}},"111":{"repeatable":false,"description":"Heading - Meeting Name","indicator1":{"codes":{"0":{},"1":{},"2":{}}},"indicator2":{"codes":{" ":{}}}},"130":{"repeatable":false,"description":"Heading - Uniform Title","indicator1":{"codes":{" ":{}}}},"147":{"repeatable":false,"description":"Heading - Named Event"},"148":{"repeatable":false,"description":"Heading - Chronological Term"},"150":{"repeatable":false,"description":"Heading - Topical Term","indicator1":{"codes":{" ":{}}},"indicator2":{"codes":{" ":{}}},"subfields":{"a":{},"b":{},"g":{"repeatable":true},"v":{"repeatable":true},"x":{"repeatable":true},"y":{"repeatable":true},"z":{"repeatable":true},"6":{},"8":{"repeatable":true}}},"151":{"repeatable":false,"description":"Heading - Geographic Name","indicator1":{"codes":{" ":{}}},"indicator2":{"codes":{" ":{}}}},"155":{"repeatable":false,"description":"Heading - Genre/Form Term","indicator1":{"codes":{" ":{}}},"indicator2":{"codes":{" ":{}}}},"400":{"repeatable":true,"description":"See From Tracing - Personal Name"},"410":{"repeatable":true,"description":"See From Tracing - Corporate Name"},"411":{"repeatable":true,"description":"See From Tracing - Meeting Name"},"430":{"repeatable":true,"description":"See From Tracing - Uniform Title"},"450":{"repeatable":true,"description":"See From Tracing - Topical Term"},"451":{"repeatable":true,"description":"See From Tracing - Geographic Name"},"455":{"repeatable":true,"description":"See From Tracing - Genre/Form Term"},"500":{"repeatable":true,"description":"See Also From Tracing - Personal Name"},"510":{"repeatable":true,"description":"See Also From Tracing - Corporate Name"},"511":{"repeatable":true,"description":"See Also From Tracing - Meeting Name"},"530":{"repeatable":true,"description":"See Also From Tracing - Uniform Title"},"550":{"repeatable":true,"description":"See Also From Tracing - Topical Term"},"551":{"repeatable":true,"description":"See Also From Tracing - Geographic Name"},"555":{"repeatable":true,"description":"See Also From Tracing - Genre/Form Term"},"667":{"repeatable":true,"description":"Nonpublic General Note","subfields":{"a":{},"5":{"repeatable":true},"6":{},"8":{"repeatable":true}}},"670":{"repeatable":true,"description":"Source Data Found","subfields":{"a":{},"b":{},"u":{"repeatable":true},"6":{},"8":{"repeatable":true}}},"675":{"repeatable":false,"description":"Source Data Not Found","subfields":{"a":{"repeatable":true},"6":{},"8":{"repeatable":true}}},"678":{"repeatable":true,"description":"Biographical or Historical Data"},"680":{"repeatable":true,"description":"Public General Note"},"681":{"repeatable":true,"description":"Subject Example Tracing Note"},"682":{"repeatable":false,"description":"Deleted Heading Information"},"688":{"repeatable":true,"description":"Application History Note"}}}');

-- marc_validate_holdings: schemas/marc21_holdings.avram.json embedded as a constant so the
-- Avram schema is parsed once at bind time.
CREATE OR REPLACE MACRO marc_validate_holdings(leader, fields) AS
    marc_validate_avram(leader, fields, '{"title":"MARC 21 Format for Holdings Data (rulepack subset)","description":"Avram-subset rulepack written from the published LC MARC 21 holdings documentation. Centered on 852 (Location) and the 853-855 caption / 863-865 enumeration pairs. Limits of the Avram subset: the requirement that each 863/864/865 field link to a matching 853/854/855 caption via $8 is a cross-field rule Avram cannot express (see marc_holdings_pairs for that pairing). Only 008 is marked required.","family":"marc","language":"eng","fields":{"001":{"repeatable":false,"description":"Control Number"},"003":{"repeatable":false,"description":"Control Number Identifier"},"004":{"repeatable":false,"description":"Control Number for Related Bibliographic Record"},"005":{"repeatable":false,"description":"Date and Time of Latest Transaction"},"007":{"repeatable":true,"description":"Physical Description Fixed Field"},"008":{"repeatable":false,"required":true,"description":"Fixed-Length Data Elements"},"010":{"repeatable":false,"description":"Library of Congress Control Number"},"014":{"repeatable":true,"description":"Linkage Number"},"035":{"repeatable":true,"description":"System Control Number","subfields":{"a":{},"z":{"repeatable":true},"6":{},"8":{"repeatable":true}}},"040":{"repeatable":false,"description":"Record Source","subfields":{"a":{},"b":{},"c":{},"d":{"repeatable":true},"e":{"repeatable":true},"6":{},"8":{"repeatable":true}}},"506":{"repeatable":true,"description":"Restrictions on Access Note"},"538":{"repeatable":true,"description":"System Details Note"},"541":{"repeatable":true,"description":"Immediate Source of Acquisition Note"},"561":{"repeatable":true,"description":"Ownership and Custodial History"},"562":{"repeatable":true,"description":"Copy and Version Identification Note"},"563":{"repeatable":true,"description":"Binding Information"},"583":{"repeatable":true,"description":"Action Note"},"852":{"repeatable":true,"description":"Location (note: $8 is NOT repeatable in 852, unlike most fields)","indicator1":{"codes":{" ":{},"0":{},"1":{},"2":{},"3":{},"4":{},"5":{},"6":{},"7":{},"8":{}}},"indicator2":{"codes":{" ":{},"0":{},"1":{},"2":{}}},"subfields":{"a":{},"b":{"repeatable":true},"c":{"repeatable":true},"d":{"repeatable":true},"e":{"repeatable":true},"f":{"repeatable":true},"g":{"repeatable":true},"h":{},"i":{"repeatable":true},"j":{},"k":{"repeatable":true},"l":{},"m":{"repeatable":true},"n":{},"p":{},"q":{},"s":{"repeatable":true},"t":{},"u":{"repeatable":true},"x":{"repeatable":true},"z":{"repeatable":true},"2":{},"3":{},"6":{},"8":{}}},"853":{"repeatable":true,"description":"Captions and Pattern - Basic Bibliographic Unit"},"854":{"repeatable":true,"description":"Captions and Pattern - Supplementary Material"},"855":{"repeatable":true,"description":"Captions and Pattern - Indexes"},"863":{"repeatable":true,"description":"Enumeration and Chronology - Basic Bibliographic Unit"},"864":{"repeatable":true,"description":"Enumeration and Chronology - Supplementary Material"},"865":{"repeatable":true,"description":"Enumeration and Chronology - Indexes"},"866":{"repeatable":true,"description":"Textual Holdings - Basic Bibliographic Unit"},"867":{"repeatable":true,"description":"Textual Holdings - Supplementary Material"},"868":{"repeatable":true,"description":"Textual Holdings - Indexes"},"876":{"repeatable":true,"description":"Item Information - Basic Bibliographic Unit"},"877":{"repeatable":true,"description":"Item Information - Supplementary Material"},"878":{"repeatable":true,"description":"Item Information - Indexes"}}}');
-- END GENERATED rulepack macros

-- Dispatch on marc_format(leader); classification/community formats fall back
-- to the structural marc_validate.
CREATE OR REPLACE MACRO marc_validate_format(leader, fields) AS
    CASE marc_format(leader)
        WHEN 'bibliographic' THEN marc_validate_bib(leader, fields)
        WHEN 'authority'     THEN marc_validate_auth(leader, fields)
        WHEN 'holdings'      THEN marc_validate_holdings(leader, fields)
        ELSE marc_validate(leader, fields)
    END;
-- Summary statistics: quick completeness overviews.
--   marc_summary(path)            one row: totals + per-record distributions
--   marc_summary_fields(path)     one row per tag: occurrence distributions
--   marc_summary_subfields(path, tag)  one row per code: counts + value lengths
-- "subfields" counts include control-field values (one per control field);
-- stddevs are sample standard deviations and NULL when only one observation.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_summary(path) AS TABLE
WITH per_record AS (
    SELECT file, record_no,
           count(DISTINCT field_no)  AS fields,
           count(*)                  AS subfields,
           count(DISTINCT tag)       AS distinct_tags,
           any_value(leader)         AS leader
    FROM read_marc_subfields(path)
    GROUP BY file, record_no)
SELECT count(*)                                   AS records,
       count(DISTINCT file)                       AS files,
       sum(fields)                                AS total_fields,
       sum(subfields)                             AS total_subfields,
       min(fields)                                AS min_fields,
       max(fields)                                AS max_fields,
       round(avg(fields), 2)                      AS mean_fields,
       round(stddev_samp(fields), 2)              AS stddev_fields,
       min(subfields)                             AS min_subfields,
       max(subfields)                             AS max_subfields,
       round(avg(subfields), 2)                   AS mean_subfields,
       round(stddev_samp(subfields), 2)           AS stddev_subfields,
       round(avg(distinct_tags), 2)               AS mean_distinct_tags,
       sum(CASE WHEN marc_encoding_scheme(leader) = 'marc8' THEN 1 ELSE 0 END) AS marc8_records
FROM per_record;

CREATE OR REPLACE MACRO marc_summary_fields(path) AS TABLE
WITH s AS (SELECT * FROM read_marc_subfields(path)),
rec_tag AS (
    SELECT file, record_no, tag,
           count(DISTINCT field_no) AS occurrences,
           count(*)                 AS subfields
    FROM s GROUP BY file, record_no, tag),
total AS (SELECT count(DISTINCT (file, record_no)) AS records FROM s)
SELECT tag,
       sum(occurrences)                                          AS total_occurrences,
       count(*)                                                  AS records_with,
       round(100.0 * count(*) / (SELECT records FROM total), 1)  AS pct_records,
       min(occurrences)                                          AS min_per_record,
       max(occurrences)                                          AS max_per_record,
       round(avg(occurrences), 2)                                AS mean_per_record,
       round(stddev_samp(occurrences), 2)                        AS stddev_per_record,
       round(sum(subfields) / sum(occurrences)::DOUBLE, 2)       AS mean_subfields_per_field
FROM rec_tag GROUP BY tag ORDER BY tag;

CREATE OR REPLACE MACRO marc_summary_subfields(path, tag_) AS TABLE
SELECT code,
       count(*)                                  AS occurrences,
       count(DISTINCT (file, record_no))         AS records_with,
       min(strlen(value))                        AS min_len,
       max(strlen(value))                        AS max_len,
       round(avg(strlen(value)), 1)              AS mean_len,
       round(stddev_samp(strlen(value)), 1)      AS stddev_len
FROM read_marc_subfields(path)
WHERE tag = tag_ AND code IS NOT NULL
GROUP BY code ORDER BY code;

-- ---------------------------------------------------------------------------
-- Remote retrieval conveniences.  Both build endpoint URLs for read_marcxml,
-- whose parser extracts MARC records from SRU searchRetrieve and OAI-PMH
-- ListRecords envelopes (deleted-record stubs yield no rows).  Requires a
-- filesystem extension for the URL scheme (LOAD httpfs).  Single response
-- page per call: pass maximum_records / a resumptionToken-bearing URL for
-- paging.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_readsru(base, query_, max_records := 50) AS TABLE
SELECT * FROM read_marcxml(
    base || '?version=1.1&operation=searchRetrieve&recordSchema=marcxml' ||
    '&maximumRecords=' || max_records || '&query=' || url_encode(query_));

CREATE OR REPLACE MACRO marc_readoai(base, metadata_prefix := 'marc21', set_ := NULL) AS TABLE
SELECT * FROM read_marcxml(
    base || '?verb=ListRecords&metadataPrefix=' || metadata_prefix ||
    coalesce('&set=' || url_encode(set_), ''));

-- ---------------------------------------------------------------------------
-- KBART holdings files (KBART Phase II / NISO RP-9): tab-separated, one
-- header row, every value textual.  marc_read_kbart passes the file's
-- columns through unchanged (SELECT *, all VARCHAR, original header names)
-- rather than demanding the full standard column list — real vendor files
-- omit and append columns freely, so presence checks belong to the caller.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_read_kbart(path) AS TABLE
SELECT * FROM read_csv(path,
                       delim := e'\t',
                       header := true,
                       all_varchar := true,
                       normalize_names := false);

-- An 856 40 (HTTP / resource itself) field struct for a KBART title_url,
-- with an optional $z public note.  Compatible with marc_add_field and the
-- nested `fields` layout.
CREATE OR REPLACE MACRO marc_kbart_856(title_url, link_text) AS
    struct_pack(
        tag := '856', ind1 := '4', ind2 := '0', value := NULL::VARCHAR,
        subfields := list_filter([
            struct_pack(code := 'u', value := title_url),
            CASE WHEN link_text IS NOT NULL
                 THEN struct_pack(code := 'z', value := link_text) END
        ], lambda s: s IS NOT NULL));

-- Minimal e-resource record from one KBART row: STRUCT(leader, fields) ready
-- for COPY (FORMAT marc) or further marc_add_field/marc_set_subfield editing.
-- Deliberate simplifications, documented rather than configured:
--   * leader is a fixed monograph-style '00000nam a2200000 a 4500' even for
--     serials (lengths are recomputed by the writer);
--   * online_identifier lands in 022 when it normalizes as an ISSN
--     (marc_issn), else in 020 when it normalizes as an ISBN (marc_isbn13),
--     else nowhere;
--   * 245 00 $a takes publication_title verbatim (no nonfiling calculation),
--     260 $b takes publisher_name, 856 40 $u takes title_url;
--   * absent (NULL) inputs simply drop their field — no 008 or 001 is built,
--     so stamp provenance with marc_add_local/marc_stamp before export.
CREATE OR REPLACE MACRO marc_kbart_to_marc(publication_title, online_identifier,
                                           title_url, publisher_name) AS
    struct_pack(
        leader := '00000nam a2200000 a 4500',
        fields := list_filter([
            CASE WHEN marc_issn(online_identifier) IS NOT NULL THEN
                struct_pack(tag := '022', ind1 := ' ', ind2 := ' ', value := NULL::VARCHAR,
                            subfields := [struct_pack(code := 'a',
                                                      value := marc_issn(online_identifier))]) END,
            CASE WHEN marc_issn(online_identifier) IS NULL
                  AND marc_isbn13(online_identifier) IS NOT NULL THEN
                struct_pack(tag := '020', ind1 := ' ', ind2 := ' ', value := NULL::VARCHAR,
                            subfields := [struct_pack(code := 'a',
                                                      value := marc_isbn13(online_identifier))]) END,
            CASE WHEN publication_title IS NOT NULL THEN
                struct_pack(tag := '245', ind1 := '0', ind2 := '0', value := NULL::VARCHAR,
                            subfields := [struct_pack(code := 'a', value := publication_title)]) END,
            CASE WHEN publisher_name IS NOT NULL THEN
                struct_pack(tag := '260', ind1 := ' ', ind2 := ' ', value := NULL::VARCHAR,
                            subfields := [struct_pack(code := 'b', value := publisher_name)]) END,
            CASE WHEN title_url IS NOT NULL THEN
                marc_kbart_856(title_url, NULL) END
        ], lambda f: f IS NOT NULL));

-- ---------------------------------------------------------------------------
-- Local-field templating: build a data field from parallel code/value lists
-- and insert it in tag order (marc_add_field's default placement).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_add_local(fields, tag_, i1, i2, codes_list, values_list) AS
    marc_add_field(fields, struct_pack(
        tag := tag_, ind1 := i1, ind2 := i2, value := NULL::VARCHAR,
        subfields := list_transform(range(1, len(codes_list) + 1),
            lambda i: struct_pack(code := codes_list[i], value := values_list[i]))));

-- Provenance stamp: 949 __ $a org_code $d <load date>.  The date is today
-- rendered as YYYY-MM-DD (now() cast down to DATE, which stays in core —
-- current_date/today() live in icu); 949 and $d are conventional local
-- choices (change the template with marc_add_local for site practice).
CREATE OR REPLACE MACRO marc_stamp(fields, org_code) AS
    marc_add_local(fields, '949', ' ', ' ',
                   ['a', 'd'], [org_code, now()::TIMESTAMP::DATE::VARCHAR]);

-- ---------------------------------------------------------------------------
-- Authority cross-references.  Headings are a field's alphabetic subfield
-- values joined with ' '; the tracing-control subfield $w and all numeric
-- control subfields ($0-$9) are excluded, so 400 $w nne $a X reads as "X".
-- Cross-record work (matching a bib file against an authority file) is a SQL
-- join written by the caller — see docs/RECIPES.md.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_heading_join(f) AS
    list_aggregate(
        list_transform(
            list_filter(f.subfields, lambda s: s.code BETWEEN 'a' AND 'z' AND s.code != 'w'),
            lambda s: s.value),
        'string_agg', ' ');

-- One entry per 1XX/4XX/5XX field of an authority record:
--   kind 'authorized' (1XX), 'see_from' (4XX), 'see_also' (5XX).
-- Non-authority leaders yield an empty list — bibliographic 4XX/5XX are
-- series statements and notes, not tracings.
CREATE OR REPLACE MACRO marc_authority_refs(leader, fields) AS
    CASE WHEN marc_format(leader) = 'authority' THEN
        list_transform(
            list_filter(fields, lambda f:
                f.subfields IS NOT NULL AND substr(f.tag, 1, 1) IN ('1', '4', '5')),
            lambda f: struct_pack(
                kind := CASE substr(f.tag, 1, 1)
                            WHEN '1' THEN 'authorized'
                            WHEN '4' THEN 'see_from'
                            ELSE 'see_also' END,
                tag := f.tag,
                heading := marc_heading_join(f)))
    ELSE [] END;

-- Flip candidates: bib headings (LIST(VARCHAR)) that NACO-match a see_from
-- tracing in one authority record's refs, each paired with that record's
-- authorized (1XX) heading.  see_also tracings never flip.
CREATE OR REPLACE MACRO marc_heading_flips(bib_headings, auth_refs) AS
    list_transform(
        list_filter(bib_headings, lambda h:
            len(list_filter(auth_refs, lambda r:
                r.kind = 'see_from' AND marc_naco(r.heading) = marc_naco(h))) > 0),
        lambda h: struct_pack(
            heading := h,
            authorized := list_filter(auth_refs, lambda r: r.kind = 'authorized')[1].heading));

-- ---------------------------------------------------------------------------
-- Bib heading extraction, for heading-change impact analysis (the workflow —
-- old/new authority snapshot diff joined against these — is a recipe in
-- docs/RECIPES.md, not a macro).  Covered tags: main entries 100/110/111/130,
-- every 6XX, added entries 700/710/711/730/740; 76X-78X linking entries and
-- 8XX series are deliberately out of scope.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_headings(fields) AS
    list_transform(
        list_filter(fields, lambda f:
            f.subfields IS NOT NULL AND
            (f.tag LIKE '6%' OR
             f.tag IN ('100', '110', '111', '130', '700', '710', '711', '730', '740'))),
        lambda f: marc_heading_join(f));

CREATE OR REPLACE MACRO marc_headings_naco(fields) AS
    list_transform(marc_headings(fields), lambda h: marc_naco(h));

-- ---------------------------------------------------------------------------
-- 856 URL extraction for link auditing: one entry per 856 that carries a $u.
-- uri is the field's first $u, link_text prefers $y (link text) over $z
-- (public note), materials is $3.  Pair with the community http_client
-- extension to check the links (docs/RECIPES.md; not a dependency here).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_urls_856(fields) AS
    list_transform(
        list_filter(fields, lambda f:
            f.tag = '856' AND f.subfields IS NOT NULL AND
            len(list_filter(f.subfields, lambda s: s.code = 'u')) > 0),
        lambda f: struct_pack(
            uri := list_filter(f.subfields, lambda s: s.code = 'u')[1].value,
            link_text := coalesce(
                list_filter(f.subfields, lambda s: s.code = 'y')[1].value,
                list_filter(f.subfields, lambda s: s.code = 'z')[1].value),
            materials := list_filter(f.subfields, lambda s: s.code = '3')[1].value));

-- ---------------------------------------------------------------------------
-- Fuzzy deduplication.  marc_dedupe_key is marc_matchkey under its workflow
-- name (NACO-normalized 245 $a $b first-40 || normalized ISBN || year);
-- marc_dedupe_candidates scores every unordered record pair of a file (or
-- glob) by jaro_winkler_similarity over NACO-normalized 245 $a titles, and
-- keeps pairs at or above the threshold — plus every exact match-key pair
-- regardless of threshold.  Records without a 245 $a score NULL and appear
-- only via the match-key rule.  Quadratic in file size by design: block first
-- (e.g. by marc_dedupe_key or year) for large files — see docs/RECIPES.md.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_dedupe_key(fields) AS marc_matchkey(fields);

CREATE OR REPLACE MACRO marc_dedupe_candidates(path, threshold) AS TABLE
WITH recs AS (
    SELECT file, record_no,
           marc_subfield(fields, '245', 'a') AS title,
           marc_matchkey(fields)             AS matchkey
    FROM read_marc(path)),
pairs AS (
    SELECT a.file      AS file_a,
           a.record_no AS record_no_a,
           b.file      AS file_b,
           b.record_no AS record_no_b,
           a.title     AS title_a,
           b.title     AS title_b,
           jaro_winkler_similarity(marc_naco(a.title), marc_naco(b.title)) AS similarity,
           a.matchkey IS NOT NULL AND a.matchkey = b.matchkey              AS same_matchkey
    FROM recs a
    JOIN recs b ON a.file < b.file OR (a.file = b.file AND a.record_no < b.record_no))
SELECT * FROM pairs
WHERE similarity >= threshold OR same_matchkey
ORDER BY file_a, record_no_a, file_b, record_no_b;

-- ---------------------------------------------------------------------------
-- RDA readiness check for AACR2-era bibliographic records: the fields most
-- commonly overlooked (or left in AACR2 form) when records predate RDA.
-- Returns a list of issue codes, empty when nothing was flagged; non-
-- bibliographic leaders yield an empty list.
--   desc_aacr2           Leader/18 = 'a' (record still coded AACR2)
--   no_040e_rda          no 040 $e 'rda' cataloging-convention marker
--   missing_336/337/338  RDA content/media/carrier types absent
--                        (marc_generate_33x derives them from the leader)
--   gmd_245h             245 $h GMD, deprecated in RDA in favor of 33X
--   only_260             publication in 260 with no 264 (RDA prefers 264)
--   aacr2_abbreviations  250/300 abbreviations that marc_rda_expand would
--                        spell out (p., v., ill., ed., ...)
--   sl_sn_260            [S.l.] / [s.n.] in 260, replaced in RDA by
--                        '[Place of publication not identified]' etc.
--   et_al_245            '[et al.]' in the 245 $c statement of responsibility
--   no_relator_1xx/7xx   100/110/111 (or 700/710/711) name entries with
--                        neither a $e relationship designator nor a $4 code
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MACRO marc_rda_check(leader, fields) AS
    CASE WHEN marc_format(leader) = 'bibliographic' THEN
        list_filter([
            CASE WHEN marc_leader_pos(leader, 18) = 'a' THEN 'desc_aacr2' END,
            CASE WHEN NOT list_contains(marc_subfields(fields, '040', 'e'), 'rda')
                 THEN 'no_040e_rda' END,
            CASE WHEN len(marc_fields(fields, '336')) = 0 THEN 'missing_336' END,
            CASE WHEN len(marc_fields(fields, '337')) = 0 THEN 'missing_337' END,
            CASE WHEN len(marc_fields(fields, '338')) = 0 THEN 'missing_338' END,
            CASE WHEN marc_subfield(fields, '245', 'h') IS NOT NULL THEN 'gmd_245h' END,
            CASE WHEN len(marc_fields(fields, '260')) > 0 AND len(marc_fields(fields, '264')) = 0
                 THEN 'only_260' END,
            CASE WHEN marc_rda_expand(fields) <> fields THEN 'aacr2_abbreviations' END,
            CASE WHEN len(list_filter(marc_subfields(fields, '260', 'a'),
                                      lambda v: v ILIKE '%[s.l.%')) > 0
                   OR len(list_filter(marc_subfields(fields, '260', 'b'),
                                      lambda v: v ILIKE '%[s.n.%')) > 0
                 THEN 'sl_sn_260' END,
            CASE WHEN coalesce(marc_subfield(fields, '245', 'c'), '') ILIKE '%et al%'
                 THEN 'et_al_245' END,
            CASE WHEN len(list_filter(fields, lambda f:
                        f.tag IN ('100', '110', '111') AND (f.subfields IS NULL OR
                        len(list_filter(f.subfields, lambda s: s.code IN ('e', '4'))) = 0))) > 0
                 THEN 'no_relator_1xx' END,
            CASE WHEN len(list_filter(fields, lambda f:
                        f.tag IN ('700', '710', '711') AND (f.subfields IS NULL OR
                        len(list_filter(f.subfields, lambda s: s.code IN ('e', '4'))) = 0))) > 0
                 THEN 'no_relator_7xx' END
        ], lambda x: x IS NOT NULL)
    ELSE [] END;
