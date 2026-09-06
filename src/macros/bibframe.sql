-- ---------------------------------------------------------------------------
-- Linked-data export: BIBFRAME 2.x JSON-LD.
--
-- marc_bibframe_jsonld(leader, fields) returns one JSON-LD text per record
-- modelling the BIBFRAME Work/Instance split: a two-node @graph whose @ids
-- are <001>#work / <001>#instance (relative URIs; resolve them against
-- whatever base the consumer chooses).  Mapping semantics follow the
-- public-domain Library of Congress sources - the BIBFRAME 2 ontology, the
-- id.loc.gov value vocabularies, and the documented conversion logic of
-- LC's marc2bibframe2 - in an original, compact implementation; the same
-- subset as xslt/bibframe/marcxml-to-bibframe2.xsl (see docs/BIBFRAME.md):
--
--   Work      @type from Leader/06 (bf:Text, bf:NotatedMusic,
--             bf:Cartography, bf:MovingImage, bf:Audio, bf:StillImage,
--             bf:Multimedia, bf:Object, bf:MixedMaterial); bf:title (245);
--             bf:contribution (1XX/7XX, role from $4 as a relators URI or
--             $e as a label, 1XX also bflc:PrimaryContribution);
--             bf:subject (6XX); bf:language (008/35-37 as an id.loc.gov
--             languages URI); bf:classification (050/082); bf:content
--             (336$b as a contentTypes URI).
--   Instance  bf:instanceOf/bf:hasInstance; bf:title;
--             bf:responsibilityStatement (245$c); bf:provisionActivity
--             (264 _1 preferred over 260); bf:identifiedBy (020 bf:Isbn
--             via marc_isbn13, 022 bf:Issn via marc_issn, 010 bf:Lccn via
--             marc_lccn, 035 bf:OclcNumber via marc_oclc); bf:extent
--             (300$a); bf:media (337$b) and bf:carrier (338$b);
--             bf:electronicLocator (856$u).
--
-- Keys with no source data are absent, not null.  Built with plain string
-- functions only: scalar macros bind at extension load, so the body cannot
-- reference json-extension functions; the output is a JSON text the json
-- extension's operators consume directly.
--
--     COPY (SELECT marc_bibframe_jsonld(leader, fields)::VARCHAR AS line
--           FROM read_marc('bibs.mrc'))
--     TO 'bibs.bf.jsonld' (FORMAT csv, HEADER false, QUOTE '');
-- ---------------------------------------------------------------------------

-- One JSON string literal, escaped per RFC 8259 (backslash, quote, and the
-- control characters that occur in practice).
CREATE OR REPLACE MACRO marc_bf_str(v) AS
    '"' || replace(replace(replace(replace(replace(v::VARCHAR,
               chr(92), chr(92) || chr(92)), '"', chr(92) || '"'),
               chr(10), chr(92) || 'n'), chr(13), chr(92) || 'r'),
               chr(9), chr(92) || 't') || '"';

-- One JSON object from a fragment list; NULL fragments (absent data) drop.
CREATE OR REPLACE MACRO marc_bf_obj(parts) AS
    '{' || array_to_string(list_filter(parts, lambda p: p IS NOT NULL), ',') || '}';

-- Trailing ISBD separators ( / : ; , ) stripped; NULL when nothing is left.
CREATE OR REPLACE MACRO marc_bf_chomp(v) AS
    nullif(trim(regexp_replace(trim(v::VARCHAR), '[\s/:;,]+$', '')), '');

-- As marc_bf_chomp but a trailing period goes too (dates, role terms,
-- subject subdivisions).
CREATE OR REPLACE MACRO marc_bf_chompd(v) AS
    nullif(trim(regexp_replace(trim(v::VARCHAR), '[\s/:;,.]+$', '')), '');

-- Provision date: the first four-digit year, else the value unbracketed.
CREATE OR REPLACE MACRO marc_bf_date(v) AS
    coalesce(nullif(regexp_extract(coalesce(v, ''), '[0-9]{4}'), ''),
             marc_bf_chompd(replace(replace(v, '[', ''), ']', '')));

-- Per-field subfield access (f is one entry of the fields list).
CREATE OR REPLACE MACRO marc_bf_sfvals(f, code_) AS
    list_transform(list_filter(f.subfields, lambda s: s.code = code_),
                   lambda s: s.value);
CREATE OR REPLACE MACRO marc_bf_sf(f, code_) AS marc_bf_sfvals(f, code_)[1];

-- The values of a field's subfields whose codes appear in codes_, joined.
CREATE OR REPLACE MACRO marc_bf_sfjoin(f, codes_, sep) AS
    nullif(array_to_string(
        list_transform(
            list_filter(f.subfields, lambda s: contains(codes_, s.code)),
            lambda s: coalesce(marc_bf_chompd(s.value), '')), sep), '');

-- BIBFRAME Work subclass from Leader/06, NULL when only bf:Work applies.
CREATE OR REPLACE MACRO marc_bf_worktype(leader) AS
    CASE
        WHEN marc_record_type(leader) IN ('a', 't') THEN 'bf:Text'
        WHEN marc_record_type(leader) IN ('c', 'd') THEN 'bf:NotatedMusic'
        WHEN marc_record_type(leader) IN ('e', 'f') THEN 'bf:Cartography'
        WHEN marc_record_type(leader) = 'g'         THEN 'bf:MovingImage'
        WHEN marc_record_type(leader) IN ('i', 'j') THEN 'bf:Audio'
        WHEN marc_record_type(leader) = 'k'         THEN 'bf:StillImage'
        WHEN marc_record_type(leader) = 'm'         THEN 'bf:Multimedia'
        WHEN marc_record_type(leader) = 'r'         THEN 'bf:Object'
        WHEN marc_record_type(leader) IN ('o', 'p') THEN 'bf:MixedMaterial'
    END;

-- Node identity: the 001, else a fixed stem.
CREATE OR REPLACE MACRO marc_bf_id(fields) AS
    coalesce(nullif(trim(marc_control_field(fields, '001')), ''), 'record');

-- 008/35-37 language code (three lowercase letters or nothing).
CREATE OR REPLACE MACRO marc_bf_lang(fields) AS
    nullif(regexp_extract(coalesce(substr(marc_control_field(fields, '008'), 36, 3), ''),
                          '^[a-z]{3}$'), '');

-- 245 as a bf:Title object (shared by Work and Instance), NULL without 245.
CREATE OR REPLACE MACRO marc_bf_title(fields) AS
    CASE WHEN marc_bf_chomp(marc_subfield(fields, '245', 'a')) IS NOT NULL
           OR marc_bf_chomp(marc_subfield(fields, '245', 'b')) IS NOT NULL
         THEN marc_bf_obj(['"@type":"bf:Title"',
             CASE WHEN marc_bf_chomp(marc_subfield(fields, '245', 'a')) IS NOT NULL
                  THEN '"bf:mainTitle":' ||
                       marc_bf_str(marc_bf_chomp(marc_subfield(fields, '245', 'a'))) END,
             CASE WHEN marc_bf_chomp(marc_subfield(fields, '245', 'b')) IS NOT NULL
                  THEN '"bf:subtitle":' ||
                       marc_bf_str(marc_bf_chomp(marc_subfield(fields, '245', 'b'))) END])
    END;

-- One 1XX/7XX field as a bf:Contribution object: agent class from the tag,
-- role from the first $4 (relators URI) or first $e (label).
CREATE OR REPLACE MACRO marc_bf_contrib(f) AS
    marc_bf_obj([
        CASE WHEN substr(f.tag, 1, 1) = '1'
             THEN '"@type":["bf:Contribution","bflc:PrimaryContribution"]'
             ELSE '"@type":"bf:Contribution"' END,
        '"bf:agent":' || marc_bf_obj([
            '"@type":"' || CASE substr(f.tag, 2, 2)
                               WHEN '00' THEN 'bf:Person'
                               WHEN '10' THEN 'bf:Organization'
                               ELSE 'bf:Meeting' END || '"',
            CASE WHEN marc_bf_sfjoin(f, 'abcdq', ' ') IS NOT NULL
                 THEN '"rdfs:label":' || marc_bf_str(marc_bf_sfjoin(f, 'abcdq', ' ')) END]),
        CASE WHEN trim(coalesce(marc_bf_sf(f, '4'), '')) != ''
             THEN '"bf:role":{"@id":' ||
                  marc_bf_str('http://id.loc.gov/vocabulary/relators/' ||
                              trim(marc_bf_sf(f, '4'))) || '}'
             WHEN marc_bf_chompd(marc_bf_sf(f, 'e')) IS NOT NULL
             THEN '"bf:role":{"@type":"bf:Role","rdfs:label":' ||
                  marc_bf_str(marc_bf_chompd(marc_bf_sf(f, 'e'))) || '}' END]);

-- One 6XX field as a subject object: label subdivided with double hyphen,
-- @id from an http $0 when present.
CREATE OR REPLACE MACRO marc_bf_subject(f) AS
    marc_bf_obj([
        '"@type":"' || CASE f.tag WHEN '651' THEN 'bf:Place'
                                  WHEN '648' THEN 'bf:Temporal'
                                  ELSE 'bf:Topic' END || '"',
        CASE WHEN len(list_filter(marc_bf_sfvals(f, '0'),
                                  lambda v: v LIKE 'http%')) > 0
             THEN '"@id":' || marc_bf_str(list_filter(marc_bf_sfvals(f, '0'),
                                  lambda v: v LIKE 'http%')[1]) END,
        CASE WHEN marc_bf_sfjoin(f, 'abcdqtvxyz', '--') IS NOT NULL
             THEN '"rdfs:label":' ||
                  marc_bf_str(marc_bf_sfjoin(f, 'abcdqtvxyz', '--')) END]);

-- The provision field: RDA 264 _1 preferred, then 260, then any 264.
CREATE OR REPLACE MACRO marc_bf_pubfield(fields) AS
    coalesce(list_filter(fields, lambda f: f.tag = '264' AND f.ind2 = '1')[1],
             list_filter(fields, lambda f: f.tag = '260')[1],
             list_filter(fields, lambda f: f.tag = '264')[1]);

CREATE OR REPLACE MACRO marc_bf_provision(f) AS
    CASE WHEN f.tag IS NOT NULL THEN marc_bf_obj([
        '"@type":"bf:Publication"',
        CASE WHEN marc_bf_chomp(marc_bf_sf(f, 'a')) IS NOT NULL
             THEN '"bf:place":{"@type":"bf:Place","rdfs:label":' ||
                  marc_bf_str(marc_bf_chomp(marc_bf_sf(f, 'a'))) || '}' END,
        CASE WHEN marc_bf_chomp(marc_bf_sf(f, 'b')) IS NOT NULL
             THEN '"bf:agent":{"@type":"bf:Agent","rdfs:label":' ||
                  marc_bf_str(marc_bf_chomp(marc_bf_sf(f, 'b'))) || '}' END,
        CASE WHEN marc_bf_date(marc_bf_sf(f, 'c')) IS NOT NULL
             THEN '"bf:date":' || marc_bf_str(marc_bf_date(marc_bf_sf(f, 'c'))) END])
    END;

-- Identifier objects: 020/022/010 through the extension's normalizers with
-- the raw value as fallback; 035 only for values that normalize as OCLC
-- numbers and carry the (OCoLC) prefix.
CREATE OR REPLACE MACRO marc_bf_ident(kind, val) AS
    '{"@type":"' || kind || '","rdf:value":' || marc_bf_str(val) || '}';

CREATE OR REPLACE MACRO marc_bf_idents(fields) AS
    list_concat(list_concat(list_concat(
        list_transform(marc_subfields(fields, '020', 'a'), lambda v:
            marc_bf_ident('bf:Isbn', coalesce(marc_isbn13(v), trim(v)))),
        list_transform(marc_subfields(fields, '022', 'a'), lambda v:
            marc_bf_ident('bf:Issn', coalesce(marc_issn(v), trim(v))))),
        list_transform(marc_subfields(fields, '010', 'a'), lambda v:
            marc_bf_ident('bf:Lccn', coalesce(marc_lccn(v), trim(v))))),
        list_transform(
            list_filter(marc_subfields(fields, '035', 'a'), lambda v:
                v LIKE '(OCoLC)%' AND marc_oclc(v) IS NOT NULL),
            lambda v: marc_bf_ident('bf:OclcNumber', marc_oclc(v))));

-- 336/337/338 $b codes as an id.loc.gov vocabulary reference array.
CREATE OR REPLACE MACRO marc_bf_vocab(vals, base_) AS
    CASE WHEN len(vals) > 0
         THEN '[' || array_to_string(list_transform(vals, lambda v:
                  '{"@id":' || marc_bf_str(base_ || trim(v)) || '}'), ',') || ']'
    END;

-- The Work-side object lists, one JSON object fragment per source field.
CREATE OR REPLACE MACRO marc_bf_contribs(fields) AS
    list_transform(
        list_filter(fields, lambda f:
            f.tag IN ('100', '110', '111', '700', '710', '711')
            AND f.subfields IS NOT NULL),
        lambda f: marc_bf_contrib(f));

CREATE OR REPLACE MACRO marc_bf_subjects(fields) AS
    list_transform(
        list_filter(fields, lambda f:
            f.tag IN ('600', '610', '611', '630', '648', '650', '651', '653')
            AND f.subfields IS NOT NULL),
        lambda f: marc_bf_subject(f));

CREATE OR REPLACE MACRO marc_bf_classes(fields) AS
    list_concat(
        list_transform(list_filter(fields, lambda f:
            f.tag = '050' AND marc_bf_sf(f, 'a') IS NOT NULL), lambda f:
            marc_bf_obj(['"@type":"bf:ClassificationLcc"',
                '"bf:classificationPortion":' || marc_bf_str(trim(marc_bf_sf(f, 'a'))),
                CASE WHEN marc_bf_sf(f, 'b') IS NOT NULL
                     THEN '"bf:itemPortion":' ||
                          marc_bf_str(trim(marc_bf_sf(f, 'b'))) END])),
        list_transform(list_filter(fields, lambda f:
            f.tag = '082' AND marc_bf_sf(f, 'a') IS NOT NULL), lambda f:
            marc_bf_obj(['"@type":"bf:ClassificationDdc"',
                '"bf:classificationPortion":' ||
                    marc_bf_str(trim(marc_bf_sf(f, 'a')))])));

-- The Work node.
CREATE OR REPLACE MACRO marc_bf_work(leader, fields, uri_) AS
    marc_bf_obj([
        '"@id":' || marc_bf_str(uri_ || '#work'),
        '"@type":' || CASE WHEN marc_bf_worktype(leader) IS NULL
                           THEN '"bf:Work"'
                           ELSE '["bf:Work","' || marc_bf_worktype(leader) || '"]' END,
        CASE WHEN marc_bf_title(fields) IS NOT NULL
             THEN '"bf:title":' || marc_bf_title(fields) END,
        CASE WHEN len(marc_bf_contribs(fields)) > 0
             THEN '"bf:contribution":[' ||
                  array_to_string(marc_bf_contribs(fields), ',') || ']' END,
        CASE WHEN len(marc_bf_subjects(fields)) > 0
             THEN '"bf:subject":[' ||
                  array_to_string(marc_bf_subjects(fields), ',') || ']' END,
        CASE WHEN marc_bf_lang(fields) IS NOT NULL
             THEN '"bf:language":{"@id":' ||
                  marc_bf_str('http://id.loc.gov/vocabulary/languages/' ||
                              marc_bf_lang(fields)) || '}' END,
        CASE WHEN len(marc_bf_classes(fields)) > 0
             THEN '"bf:classification":[' ||
                  array_to_string(marc_bf_classes(fields), ',') || ']' END,
        CASE WHEN marc_bf_vocab(marc_subfields(fields, '336', 'b'),
                 'http://id.loc.gov/vocabulary/contentTypes/') IS NOT NULL
             THEN '"bf:content":' || marc_bf_vocab(marc_subfields(fields, '336', 'b'),
                 'http://id.loc.gov/vocabulary/contentTypes/') END,
        '"bf:hasInstance":{"@id":' || marc_bf_str(uri_ || '#instance') || '}']);

-- The Instance node.
CREATE OR REPLACE MACRO marc_bf_instance(leader, fields, uri_) AS
    marc_bf_obj([
        '"@id":' || marc_bf_str(uri_ || '#instance'),
        '"@type":"bf:Instance"',
        '"bf:instanceOf":{"@id":' || marc_bf_str(uri_ || '#work') || '}',
        CASE WHEN marc_bf_title(fields) IS NOT NULL
             THEN '"bf:title":' || marc_bf_title(fields) END,
        CASE WHEN marc_bf_chomp(marc_subfield(fields, '245', 'c')) IS NOT NULL
             THEN '"bf:responsibilityStatement":' ||
                  marc_bf_str(marc_bf_chomp(marc_subfield(fields, '245', 'c'))) END,
        CASE WHEN marc_bf_provision(marc_bf_pubfield(fields)) IS NOT NULL
             THEN '"bf:provisionActivity":' ||
                  marc_bf_provision(marc_bf_pubfield(fields)) END,
        CASE WHEN len(marc_bf_idents(fields)) > 0
             THEN '"bf:identifiedBy":[' ||
                  array_to_string(marc_bf_idents(fields), ',') || ']' END,
        CASE WHEN marc_bf_chomp(marc_subfield(fields, '300', 'a')) IS NOT NULL
             THEN '"bf:extent":{"@type":"bf:Extent","rdfs:label":' ||
                  marc_bf_str(marc_bf_chomp(marc_subfield(fields, '300', 'a'))) || '}' END,
        CASE WHEN marc_bf_vocab(marc_subfields(fields, '337', 'b'),
                 'http://id.loc.gov/vocabulary/mediaTypes/') IS NOT NULL
             THEN '"bf:media":' || marc_bf_vocab(marc_subfields(fields, '337', 'b'),
                 'http://id.loc.gov/vocabulary/mediaTypes/') END,
        CASE WHEN marc_bf_vocab(marc_subfields(fields, '338', 'b'),
                 'http://id.loc.gov/vocabulary/carriers/') IS NOT NULL
             THEN '"bf:carrier":' || marc_bf_vocab(marc_subfields(fields, '338', 'b'),
                 'http://id.loc.gov/vocabulary/carriers/') END,
        CASE WHEN len(marc_subfields(fields, '856', 'u')) > 0
             THEN '"bf:electronicLocator":[' || array_to_string(
                  list_transform(marc_subfields(fields, '856', 'u'),
                      lambda u: '{"@id":' || marc_bf_str(u) || '}'), ',') || ']' END]);

CREATE OR REPLACE MACRO marc_bibframe_jsonld(leader, fields) AS
    '{"@context":{'
    || '"bf":"http://id.loc.gov/ontologies/bibframe/",'
    || '"bflc":"http://id.loc.gov/ontologies/bflc/",'
    || '"rdf":"http://www.w3.org/1999/02/22-rdf-syntax-ns#",'
    || '"rdfs":"http://www.w3.org/2000/01/rdf-schema#"},"@graph":['
    || marc_bf_work(leader, fields, marc_bf_id(fields)) || ','
    || marc_bf_instance(leader, fields, marc_bf_id(fields)) || ']}';
