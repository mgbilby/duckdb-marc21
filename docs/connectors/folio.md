# FOLIO

| | |
|---|---|
| Canonical MARC store | Source Record Storage (SRS), MARC-in-JSON (`parsedRecord.content`) in PostgreSQL |
| Fetch | `marc_readfolio_srs(okapi_base, instance_uuid)`, `marc_readfolio_record(okapi_base, record_uuid)`, `ATTACH` PostgreSQL, data-export `.mrc` files |
| Auth | `x-okapi-tenant` + `x-okapi-token` headers (Okapi), or `Authorization: Bearer` behind Kong/Eureka |
| Linkage | `999 ff $s` = SRS record UUID, `999 ff $i` = Inventory instance UUID |
| Write-back | FOLIO **Data Import** (job profiles) |

## Auth setup

DuckDB cannot POST, so obtain the token outside SQL (`curl -d
'{"username":...,"password":...}' {okapi}/authn/login`, token in the
`x-okapi-token` response header), then scope it to the gateway:

```sql
INSTALL httpfs; LOAD httpfs; LOAD marc21;
CREATE SECRET folio (
    TYPE http,
    EXTRA_HTTP_HEADERS MAP {
        'x-okapi-tenant': 'diku',
        'x-okapi-token': '<token>'
    },
    SCOPE 'https://okapi.mylib.example'
);
```

## Fetch

```sql
-- Source MARC for one Inventory instance
-- (GET /source-storage/records/{uuid}/formatted?idType=INSTANCE)
SELECT tag, code, value
FROM marc_readfolio_srs('https://okapi.mylib.example',
                        '5b1eb450-ff9a-4d02-b50a-6c0f8b7cf02e');

-- Or directly by SRS record UUID (the 999 ff $s value)
SELECT * FROM marc_readfolio_record('https://okapi.mylib.example',
                                    'c9f30e1d-2a44-4a5f-9b8e-6f2d1e0a7b41');
```

The collection endpoint `/source-storage/source-records` wraps results in
`{"sourceRecords": [...]}`; `read_marcjson` unwraps it, one row per record
(`marc_readfolio_source_records(okapi_base, lim, off)` pages it). For
whole-tenant work, the database or data export patterns below still scale
better.

## In-place analytics: ATTACH the FOLIO PostgreSQL

FOLIO is Apache-2.0 and PostgreSQL-backed, so a read-only replica login is
the highest-bandwidth connector — no API paging at all:

```sql
INSTALL postgres; LOAD postgres;
ATTACH 'host=folio-db dbname=okapi user=folio_ro' AS folio (TYPE postgres, READ_ONLY);

-- Validate every source record of one tenant in place
WITH src AS (
    SELECT id, marc_parse_json(content::VARCHAR) AS rec
    FROM folio.diku_mod_source_record_storage.marc_records_lb
)
SELECT id, unnest(marc_validate(rec.leader, rec.fields)) AS violation
FROM src;
```

`marc_parse_json` accepts the raw `content` JSONB, the `{"content": ...}`
wrapper, or the whole `{"parsedRecord": ...}` envelope.

### 999 ff linkage

FOLIO reserves `999 ff` for its own identifiers: `$s` is the SRS record UUID,
`$i` the Inventory instance UUID. That makes SRS-to-Inventory joins pure SQL:

```sql
WITH src AS (
    SELECT id, marc_parse_json(content::VARCHAR) AS rec
    FROM folio.diku_mod_source_record_storage.marc_records_lb
)
SELECT src.id                                            AS srs_id,
       marc_subfield(rec.fields, '999', 'i')             AS instance_id,
       inst.jsonb ->> 'hrid'                             AS instance_hrid,
       marc_subfield(rec.fields, '245', 'a')             AS marc_title,
       inst.jsonb ->> 'title'                            AS instance_title
FROM src
JOIN folio.diku_mod_inventory_storage.instance AS inst
  ON inst.id = marc_subfield(rec.fields, '999', 'i')::UUID;
```

(Compare `marc_title` with `instance_title` to audit mapping drift between
SRS and Inventory.)

## Files without credentials

`mod-data-export` MARC files read with `read_marc('export.mrc')`; API
responses saved as JSON read with `read_marcjson` (NDJSON supported).

## Edit and write back

DuckDB never POSTs to Okapi. The write path is a file into **FOLIO Data
Import** (Settings → Data import job profiles; create/update actions match
on `001`/`035`/`999 ff` per profile):

```sql
-- Quality-gate, fix, and export a batch for Data Import
COPY (
    SELECT rec.leader, rec.fields
    FROM (SELECT marc_parse_json(content::VARCHAR) AS rec
          FROM folio.diku_mod_source_record_storage.marc_records_lb)
    WHERE len(marc_folio_check(rec.leader, rec.fields)) = 0
) TO 'for_folio.mrc' (FORMAT marc);   -- always UTF-8, leader/09 = 'a'
```

`marc_folio_check(leader, fields)` encodes the importer's expectations
(`001`+`003` present, no stray `999 ff` on *new* records, UTF-8 leader). For
update jobs keep the `999 ff` intact — it is exactly what FOLIO's default
update match profile matches on.
