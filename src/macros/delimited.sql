-- ---------------------------------------------------------------------------
-- Delimited text -> MARC (the MarcEdit "Delimited Text Translator"
-- equivalent, as SQL).  Spreadsheet columns become MARC fields through a
-- mapping expressed as a list of structs, one entry per mapped cell:
--
--     [{tag: '245', i1: '0', i2: '0', code: 'a', value: title_column},
--      {tag: '245', i1: '0', i2: '0', code: 'c', value: author_column},
--      {tag: '020', i1: NULL, i2: NULL, code: 'a', value: isbn_column}, ...]
--
-- Rules, matching MarcEdit's translator behavior:
--   * entries with a NULL/blank value are dropped (an empty spreadsheet cell
--     adds no subfield), and a field whose subfields all dropped is omitted;
--   * consecutive-or-not entries sharing (tag, i1, i2) merge into ONE field
--     with their subfields in mapping order -- map 264 $a $b $c from three
--     columns and get a single 264 field.  To get two fields with the same
--     tag (two 650s), vary the indicators or build them as separate mappings
--     unioned before COPY;
--   * a tag below 010 is a control field: its value is taken verbatim, its
--     i1/i2/code are ignored;
--   * NULL i1/i2 mean blank indicators, NULL code means 'a'.
--
-- marc_from_delimited(material, mapping) returns STRUCT(leader, fields)
-- ready for COPY (FORMAT marc): the leader and skeleton 008 come from
-- marc_new_record(material) ('book', 'serial', 'video', 'map', 'music' or
-- 'electronic') and the mapped fields are merged in tag order.  For
-- e-resource lists with a URL column, marc_from_delimited_url additionally
-- appends an 856 40 via marc_kbart_856.  See test/sql/marc_delimited.test
-- for a CSV round trip and docs/RECIPES.md-style usage:
--
--     SELECT marc_from_delimited('book', [
--                {tag: '245', i1: '0', i2: '0', code: 'a', value: title},
--                {tag: '100', i1: '1', i2: NULL, code: 'a', value: author}
--            ]) AS r
--     FROM read_csv('titles.csv');
--     -- then: COPY (SELECT r.leader AS leader, r.fields AS fields ...)
-- ---------------------------------------------------------------------------

-- Mapped cells that survive: a tag and a non-blank value.  A NULL mapping
-- counts as empty (the skeleton record still comes out).
CREATE OR REPLACE MACRO marc_delimited_clean(mapping) AS
    list_filter(coalesce(mapping, []), lambda m:
        m.tag IS NOT NULL AND m.value IS NOT NULL AND trim(m.value) != '');

-- Cleaned mapping entries -> field structs in the read_marc() nested layout.
-- Data-field entries group by (tag, i1, i2) at the position of the group's
-- first entry; control-tag entries (tag < '010') pass through one field each.
CREATE OR REPLACE MACRO marc_delimited_build(mm) AS
    list_transform(
        list_filter(range(1, len(mm) + 1), lambda i:
            mm[i].tag < '010' OR
            len(list_filter(list_slice(mm, 1, i - 1), lambda p:
                    p.tag = mm[i].tag
                    AND coalesce(p.i1, ' ') = coalesce(mm[i].i1, ' ')
                    AND coalesce(p.i2, ' ') = coalesce(mm[i].i2, ' '))) = 0),
        lambda i:
            CASE WHEN mm[i].tag < '010' THEN
                struct_pack(tag := mm[i].tag,
                            ind1 := NULL::VARCHAR, ind2 := NULL::VARCHAR,
                            value := mm[i].value,
                            subfields := NULL::STRUCT(code VARCHAR, value VARCHAR)[])
            ELSE
                struct_pack(tag := mm[i].tag,
                            ind1 := coalesce(mm[i].i1, ' '),
                            ind2 := coalesce(mm[i].i2, ' '),
                            value := NULL::VARCHAR,
                            subfields := list_transform(
                                list_filter(mm, lambda m:
                                    m.tag = mm[i].tag
                                    AND coalesce(m.i1, ' ') = coalesce(mm[i].i1, ' ')
                                    AND coalesce(m.i2, ' ') = coalesce(mm[i].i2, ' ')),
                                lambda m: struct_pack(code := coalesce(m.code, 'a'),
                                                      value := m.value)))
            END);

-- Stable tag-order sort of a fields list (marc_add_field's placement rule,
-- applied wholesale: ties keep their relative order).
CREATE OR REPLACE MACRO marc_delimited_tagsort(fs) AS
    list_transform(
        list_sort(list_transform(range(1, len(fs) + 1),
            lambda i: struct_pack(k := fs[i].tag, i := i, f := fs[i]))),
        lambda e: e.f);

-- Skeleton + built fields, in tag order.  A mapped tag replaces the
-- skeleton's placeholder of the same tag (marc_new_record's book skeleton
-- carries an empty 245, which a mapped 245 supersedes).
CREATE OR REPLACE MACRO marc_delimited_assemble(material, built) AS
    struct_pack(
        leader := marc_new_record(material).leader,
        fields := marc_delimited_tagsort(
            list_filter(marc_new_record(material).fields, lambda f:
                NOT list_contains(list_transform(built, lambda b: b.tag), f.tag))
            || built));

-- One record per spreadsheet row: marc_new_record(material) skeleton plus
-- the mapped fields, merged in tag order.
CREATE OR REPLACE MACRO marc_from_delimited(material, mapping) AS
    marc_delimited_assemble(material,
        marc_delimited_build(marc_delimited_clean(mapping)));

-- Same, plus an 856 40 $u [$z] built by marc_kbart_856 when url is not NULL
-- (e-resource spreadsheets: title/author/... columns plus a URL column).
CREATE OR REPLACE MACRO marc_from_delimited_url(material, mapping, url, link_text) AS
    marc_delimited_assemble(material,
        marc_delimited_build(marc_delimited_clean(mapping)) ||
        CASE WHEN url IS NOT NULL AND trim(url) != ''
             THEN [marc_kbart_856(url, link_text)]
             ELSE [] END);

-- ---------------------------------------------------------------------------
-- Named preset mappings for common spreadsheet layouts.  Each preset returns
-- the mapping LIST above, ready for marc_from_delimited /
-- marc_from_delimited_url — pass your columns in, get the struct list out:
--
--     SELECT marc_from_delimited('book',
--                marc_delimited_preset_books(title, author, isbn,
--                                            publisher, pubyear)) AS r
--     FROM read_csv('books.csv', all_varchar := true);
--
-- A NULL or blank column simply drops its subfield (marc_delimited_clean's
-- rule), so partial spreadsheets work unchanged, and a preset composes like
-- any hand-written mapping — append extra entries with ||:
--
--     marc_delimited_preset_books(title, author, isbn, publisher, pubyear)
--         || [{tag: '650', i1: ' ', i2: '0', code: 'a', value: subject}]
--
-- There is deliberately NO marc_delimited_preset(name, ...) dispatcher: a
-- SQL macro has a fixed argument list, so one macro cannot take five columns
-- for 'books' but three for 'serials'.  Call the preset for your layout.
-- ---------------------------------------------------------------------------

-- Monographs: title / author / ISBN / publisher / publication year.
-- 245 ind1 tracks whether an author (100 1_) is present; publisher and year
-- share (tag, i1, i2) so they merge into ONE 264 _1 publication statement.
CREATE OR REPLACE MACRO marc_delimited_preset_books(title, author, isbn, publisher, pubyear) AS [
    {tag: '100', i1: '1', i2: NULL, code: 'a', value: author},
    {tag: '245',
     i1: CASE WHEN author IS NULL OR trim(author) = '' THEN '0' ELSE '1' END,
     i2: '0', code: 'a', value: title},
    {tag: '020', i1: NULL, i2: NULL, code: 'a', value: isbn},
    {tag: '264', i1: ' ', i2: '1', code: 'b', value: publisher},
    {tag: '264', i1: ' ', i2: '1', code: 'c', value: pubyear}
];

-- Serials: title / ISSN / publisher.  Pair with material 'serial'.
CREATE OR REPLACE MACRO marc_delimited_preset_serials(title, issn, publisher) AS [
    {tag: '245', i1: '0', i2: '0', code: 'a', value: title},
    {tag: '022', i1: NULL, i2: NULL, code: 'a', value: issn},
    {tag: '264', i1: ' ', i2: '1', code: 'b', value: publisher}
];

-- E-resources: title / URL / ISBN.  The URL becomes an 856 40 $u directly in
-- the mapping (856 is an ordinary data field), so this preset works through
-- plain marc_from_delimited with material 'electronic'; use
-- marc_from_delimited_url instead when you also want marc_kbart_856's $z
-- link text.
CREATE OR REPLACE MACRO marc_delimited_preset_eresources(title, url, isbn) AS [
    {tag: '245', i1: '0', i2: '0', code: 'a', value: title},
    {tag: '856', i1: '4', i2: '0', code: 'u', value: url},
    {tag: '020', i1: NULL, i2: NULL, code: 'a', value: isbn}
];
