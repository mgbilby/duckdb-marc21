# OCLC WorldShare

| | |
|---|---|
| Canonical MARC store | WorldCat; records keyed by OCLC number (`001` prefixed `ocm`/`ocn`/`on`, `003` = `OCoLC`) |
| Fetch | `marc_readworldshare(base, oclc_number)` over the WorldCat Metadata API |
| Auth | WSKey → OAuth2 client-credentials **bearer token** |
| Formats | Metadata API serves MARCXML or MARC-in-JSON by `Accept` header |
| Write-back | WorldShare **Data Sync** collections (Collection Manager) |

## Auth setup

A WSKey with the `WorldCatMetadataAPI` scope trades for a short-lived
(~20 minute) token outside SQL:

```
curl -u "KEY:SECRET" -X POST \
  "https://oauth.oclc.org/token?grant_type=client_credentials&scope=WorldCatMetadataAPI"
```

Put the token and the MARCXML `Accept` header in one scoped secret
(re-create the secret when the token rotates):

```sql
INSTALL httpfs; LOAD httpfs; LOAD marc21;
CREATE SECRET oclc (
    TYPE http,
    BEARER_TOKEN '<access_token>',
    EXTRA_HTTP_HEADERS MAP {'Accept': 'application/marcxml+xml'},
    SCOPE 'https://metadata.api.oclc.org'
);
```

## Fetch

```sql
-- GET /worldcat/manage/bibs/{oclcNumber}: the current WorldCat record,
-- served as a bare MARCXML <record>
SELECT tag, code, value
FROM marc_readworldshare('https://metadata.api.oclc.org', 1000000303);
```

The macro takes the OCLC number bare (digits); the returned `001` carries
the prefixed form. `marc_oclc(...)` normalizes either direction — prefix and
leading zeros stripped, NULL when not an OCLC number — which is the join key
for reconciliation:

```sql
-- Compare local 035s against what WorldCat says the number is now
-- (019 carries merged-away numbers)
SELECT l.control_number                                  AS local_001,
       marc_oclc(marc_subfield(l.fields, '035', 'a'))    AS local_oclc,
       marc_oclc(w.control_number)                       AS worldcat_oclc,
       marc_subfields(w.fields, '019', 'a')              AS merged_from
FROM read_marc('local_export.mrc')                       AS l,
     marc_readnestedxml('https://metadata.api.oclc.org/worldcat/manage/bibs/'
                        || marc_oclc(marc_subfield(l.fields, '035', 'a'))) AS w;
```

There is no MARC-returning search: the WorldCat Search API answers
application/json bib summaries, not records — search there for numbers, then
fetch records by number here. One record per call; batch by joining a table
of OCLC numbers as above, mindful of rate limits.

## Write back

DuckDB cannot POST/PUT to the Metadata API. The batch pathway OCLC provides
is **Data Sync** in WorldShare Collection Manager: a collection profile plus
uploaded record files, which OCLC matches against WorldCat and reports back
on. Produce the file here:

```sql
COPY (
    SELECT leader, fields
    FROM read_marc('local_export.mrc')
    WHERE len(marc_validate(leader, fields)) = 0
) TO 'datasync_batch.mrc' (FORMAT marc);
```

Upload the file to the Data Sync collection's file exchange location. Keep
your local system number in `001`/`035` intact — Data Sync cross-references
report OCLC's matched number against it, and the report joins right back to
this database on `marc_oclc`.
