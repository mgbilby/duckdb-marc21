-- ---------------------------------------------------------------------------
-- International interoperability helpers: ISBD display and UNIMARC record
-- label conversion.  See docs/INTERNATIONAL.md for the standards map and
-- xslt/intl/ for the field-level UNIMARC/ONIX/EDM/MADS crosswalks.
--
-- marc_isbd(leader, fields) renders one bibliographic record as a single
-- ISBD-punctuated display string, following the area structure of the IFLA
-- "ISBD: International Standard Bibliographic Description, Consolidated
-- Edition" (IFLA publications are CC BY 4.0; the area/punctuation scheme is
-- referenced, not reproduced):
--
--   area 1  title proper : other title information / statement of resp.
--   area 2  edition / statement of responsibility relating to the edition
--   area 4  place : publisher, date        (260 with 264 fallback)
--   area 5  extent : other physical details ; dimensions
--   area 6  (series ; numbering)
--   area 8  ISBN ... (ISSN for continuing resources, from Leader/07)
--
-- Areas are joined with the prescribed ". — " (point, space, em dash,
-- space); areas 3 (material-specific) and 7 (notes) are intentionally not
-- rendered.  Missing pieces degrade gracefully: absent subfields drop
-- their punctuation, absent areas drop entirely, an empty record yields
-- NULL.  Source ISBD punctuation at subfield boundaries is stripped with
-- marc_trim_punct before the prescribed punctuation is re-applied.
--
-- marc_unimarc_label(leader) / marc_from_unimarc_label(label) convert a
-- MARC 21 leader to a UNIMARC record label and back, per the two published
-- layouts (MARC 21 Bibliographic leader, LC; UNIMARC record label, IFLA
-- UNIMARC Manual).  Length (0-4) and base address (12-16) digits are
-- copied verbatim - writers recompute them anyway.
--
-- House rules: scalar macros bind at extension load, so only core DuckDB
-- functions and this extension's own functions appear here (no json
-- extension); fragment-list + list_filter composition as in formats.sql.
-- ---------------------------------------------------------------------------

-- A concat_ws result is '' (not NULL) when every input is NULL; this wrapper
-- makes empty mean NULL so optional segments can nest.
CREATE OR REPLACE MACRO marc_isbd_nn(v) AS nullif(v, '');

-- Area 1: 245 $a : $b / $c.
CREATE OR REPLACE MACRO marc_isbd_area1(fields) AS
    marc_isbd_nn(concat_ws(' / ',
        marc_isbd_nn(concat_ws(' : ',
            marc_trim_punct(marc_subfield(fields, '245', 'a')),
            marc_trim_punct(marc_subfield(fields, '245', 'b')))),
        marc_trim_punct(marc_subfield(fields, '245', 'c'))));

-- Area 2: 250 $a / $b.
CREATE OR REPLACE MACRO marc_isbd_area2(fields) AS
    marc_isbd_nn(concat_ws(' / ',
        marc_trim_punct(marc_subfield(fields, '250', 'a')),
        marc_trim_punct(marc_subfield(fields, '250', 'b'))));

-- Area 4: place : publisher, date - from 260, else 264 (any function).
CREATE OR REPLACE MACRO marc_isbd_area4(fields) AS
    marc_isbd_nn(concat_ws(', ',
        marc_isbd_nn(concat_ws(' : ',
            marc_trim_punct(coalesce(marc_subfield(fields, '260', 'a'),
                                     marc_subfield(fields, '264', 'a'))),
            marc_trim_punct(coalesce(marc_subfield(fields, '260', 'b'),
                                     marc_subfield(fields, '264', 'b'))))),
        marc_trim_punct(coalesce(marc_subfield(fields, '260', 'c'),
                                 marc_subfield(fields, '264', 'c')))));

-- Area 5: extent : other physical details ; dimensions (300).
CREATE OR REPLACE MACRO marc_isbd_area5(fields) AS
    marc_isbd_nn(concat_ws(' ; ',
        marc_isbd_nn(concat_ws(' : ',
            marc_trim_punct(marc_subfield(fields, '300', 'a')),
            marc_trim_punct(marc_subfield(fields, '300', 'b')))),
        marc_trim_punct(marc_subfield(fields, '300', 'c'))));

-- Area 6: (series ; numbering) from 490.
CREATE OR REPLACE MACRO marc_isbd_area6(fields) AS
    CASE WHEN marc_subfield(fields, '490', 'a') IS NOT NULL
         THEN '(' || concat_ws(' ; ',
                  marc_trim_punct(marc_subfield(fields, '490', 'a')),
                  marc_trim_punct(marc_subfield(fields, '490', 'v'))) || ')'
    END;

-- Area 8: standard number - ISSN for continuing resources (Leader/07 in
-- b/i/s), ISBN otherwise; transcribed form, not normalized.
CREATE OR REPLACE MACRO marc_isbd_area8(leader, fields) AS
    CASE WHEN marc_bib_level(leader) IN ('b', 'i', 's')
              AND marc_subfield(fields, '022', 'a') IS NOT NULL
         THEN 'ISSN ' || marc_trim_punct(marc_subfield(fields, '022', 'a'))
         WHEN marc_subfield(fields, '020', 'a') IS NOT NULL
         THEN 'ISBN ' || marc_trim_punct(marc_subfield(fields, '020', 'a'))
    END;

CREATE OR REPLACE MACRO marc_isbd(leader, fields) AS
    marc_isbd_nn(array_to_string(list_filter([
        marc_isbd_area1(fields),
        marc_isbd_area2(fields),
        marc_isbd_area4(fields),
        marc_isbd_area5(fields),
        marc_isbd_area6(fields),
        marc_isbd_area8(leader, fields)
    ], lambda a: a IS NOT NULL), '. — '));

-- ---------------------------------------------------------------------------
-- Record label conversion.  Positions that differ:
--   /5 status        MARC 21 'a' (increase in encoding level) has no
--                    UNIMARC equivalent -> 'c'; UNIMARC 'o' -> 'c'
--   /6 type          MARC t<->UNIMARC b (manuscript language),
--                    m<->l (electronic), o<->m (kit); others coincide
--   /7 bib level     MARC 'b' (serial component part) -> UNIMARC 'a',
--                    'd' (subunit) -> 'm'; a/c/i/m/s coincide
--   /8               MARC type of control <-> UNIMARC hierarchical level
--                    (emitted as '0' = no hierarchy / ' ' = no control)
--   /9               MARC character coding ('a' = UCS on the way back -
--                    this extension's pipeline is UTF-8) <-> undefined
--   /17 encoding     MARC 8 (CIP) <-> UNIMARC 1; 3,5 <-> 3; 2 <- UNIMARC 2;
--                    full-ish (blank,1,4) <-> blank; other MARC levels -> 2
--   /18 cataloguing  MARC a/i (AACR2/ISBD) <-> UNIMARC blank (full ISBD);
--                    MARC c (ISBD, punctuation omitted) <-> UNIMARC i
--                    (partial ISBD); MARC blank/n (non-ISBD) <-> UNIMARC n
--   /20-23           entry map '4500' <-> directory map '450 '
-- ---------------------------------------------------------------------------

CREATE OR REPLACE MACRO marc_unimarc_label(leader) AS
    substr(leader, 1, 5)
    || CASE substr(leader, 6, 1)
           WHEN 'a' THEN 'c' WHEN 'c' THEN 'c' WHEN 'd' THEN 'd'
           WHEN 'p' THEN 'p' ELSE 'n' END
    || CASE
           WHEN substr(leader, 7, 1) = 't' THEN 'b'
           WHEN substr(leader, 7, 1) = 'm' THEN 'l'
           WHEN substr(leader, 7, 1) = 'o' THEN 'm'
           WHEN substr(leader, 7, 1) = 'p' THEN 'a'
           WHEN strpos('acdefgijkr', substr(leader, 7, 1)) > 0
                THEN substr(leader, 7, 1)
           ELSE 'a' END
    || CASE
           WHEN substr(leader, 8, 1) = 'b' THEN 'a'
           WHEN substr(leader, 8, 1) = 'd' THEN 'm'
           WHEN strpos('acims', substr(leader, 8, 1)) > 0
                THEN substr(leader, 8, 1)
           ELSE 'm' END
    || '0 22'
    || substr(leader, 13, 5)
    || CASE substr(leader, 18, 1)
           WHEN '8' THEN '1' WHEN '3' THEN '3' WHEN '5' THEN '3'
           WHEN ' ' THEN ' ' WHEN '1' THEN ' ' WHEN '4' THEN ' '
           ELSE '2' END
    || CASE substr(leader, 19, 1)
           WHEN 'a' THEN ' ' WHEN 'i' THEN ' ' WHEN 'u' THEN ' '
           WHEN 'c' THEN 'i' ELSE 'n' END
    || ' 450 ';

CREATE OR REPLACE MACRO marc_from_unimarc_label(label) AS
    substr(label, 1, 5)
    || CASE substr(label, 6, 1)
           WHEN 'o' THEN 'c'
           WHEN 'c' THEN 'c' WHEN 'd' THEN 'd' WHEN 'p' THEN 'p'
           ELSE 'n' END
    || CASE
           WHEN substr(label, 7, 1) = 'b' THEN 't'
           WHEN substr(label, 7, 1) = 'l' THEN 'm'
           WHEN substr(label, 7, 1) = 'm' THEN 'o'
           WHEN strpos('acdefgijkr', substr(label, 7, 1)) > 0
                THEN substr(label, 7, 1)
           ELSE 'a' END
    || CASE
           WHEN strpos('acims', substr(label, 8, 1)) > 0
                THEN substr(label, 8, 1)
           ELSE 'm' END
    || ' a22'
    || substr(label, 13, 5)
    || CASE substr(label, 18, 1)
           WHEN '1' THEN '8' WHEN '2' THEN '5' WHEN '3' THEN '3'
           ELSE ' ' END
    || CASE substr(label, 19, 1)
           WHEN 'n' THEN ' ' ELSE 'i' END
    || ' 4500';
