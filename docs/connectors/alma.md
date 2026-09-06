# Ex Libris Alma

| | |
|---|---|
| Canonical MARC store | SaaS; MARCXML is the canonical bib format |
| Fetch | `marc_readalma(base, mms_id, [apikey])`, `marc_readalma_bibs(base, mms_ids, [apikey])`, `marc_readalma_sru(base, inst_code, query, [max_records])`, `marc_readoai` |
| Auth | API key per environment (header `Authorization: apikey ...` or `apikey=` parameter); SRU/OAI are keyless |
| Envelope | REST responses wrap the MARCXML `<record>` in a `<bib>` element (batches in `<bibs>`) — transparent to `read_marcxml` |
| Write-back | Record-at-a-time: `marc_alma_update_bib` over the community `http_request` extension (`PUT /almaws/v1/bibs/{mms_id}`); batch: Alma **import profiles** (Resources → Manage import profiles) |

## Auth setup

`base` is the regional API gateway (`api-na`, `api-eu`, `api-ap`,
`api-cn.hosted.exlibrisgroup.com.cn`, ...). Prefer the header secret so the
key stays out of query text and server logs of intermediaries:

```sql
INSTALL httpfs; LOAD httpfs; LOAD marc21;
CREATE SECRET alma (
    TYPE http,
    EXTRA_HTTP_HEADERS MAP {'Authorization': 'apikey l8xx...'},
    SCOPE 'https://api-na.hosted.exlibrisgroup.com'
);
```

(Alma equally accepts `apikey :=` as a macro argument, which appends the
documented `apikey=` query parameter — convenient, less clean.)

## Fetch

```sql
-- One bib: GET /almaws/v1/bibs/{mms_id}; the <bib> envelope (mms_id,
-- created_date, ...) is skipped, only the MARC surfaces
SELECT tag, code, value
FROM marc_readalma('https://api-na.hosted.exlibrisgroup.com', '9939332839702836');

-- Up to 100 bibs per call: GET /almaws/v1/bibs?mms_id=a,b,c
SELECT count(DISTINCT record_no)
FROM marc_readalma_bibs('https://api-na.hosted.exlibrisgroup.com',
                        '9939332839702836,9939332839702837');

-- Keyless SRU on the institution domain — the bulk/set retrieval story
SELECT * FROM marc_readalma_sru('https://mylib.alma.exlibrisgroup.com',
                                'MYLIB', 'alma.all_for_ui=cartography',
                                max_records := 50);
```

Alma has no REST call that returns a *set's members* as MARCXML in one
response; itemized sets come back as ID lists from
`/almaws/v1/conf/sets/{set_id}/members`. Fetch that JSON (DuckDB `json`
extension), then feed comma-joined batches of 100 into
`marc_readalma_bibs`. For whole-collection work, an Alma publishing profile
(OAI-PMH) plus `marc_readoai('https://mylib.alma.exlibrisgroup.com/view/oai/MYLIB/request')`
beats paging the API.

## Analyze and edit

```sql
-- RDA hybrid check across a fetched batch: 264 vs 260
SELECT record_no,
       marc_subfield(fields, '245', 'a')                       AS title,
       len(marc_fields(fields, '260')) > 0                     AS has_260,
       len(marc_fields(fields, '264')) > 0                     AS has_264
FROM marc_readnestedxml('https://api-na.hosted.exlibrisgroup.com/almaws/v1/bibs/9939332839702836');
```

(`marc_readnestedxml` accepts the same URLs the macros build, returning the
nested shape the editing and validation functions take.)

## Write back

> **This edits your production catalog.** `PUT /almaws/v1/bibs/{mms_id}`
> replaces the stored record; Alma's server-side defaults are permissive
> (`override_warning` and `override_lock` both default to true). Develop
> against your Alma **sandbox** gateway with a sandbox key, keep
> `stale_version_check := true` on, and only move to production keys once
> the round trip is verified. Alma API keys are scoped per area
> (Developer Network → your app → API management): a **read-only** Bibs key
> serves every `marc_readalma*` macro and gets `401`/`403` on PUT, and a
> **read/write** Bibs key is what write-back needs — mint separate keys for
> the two roles rather than promoting the key your reports already use, and
> remember each key is bound to one environment (sandbox vs production).

### Record-at-a-time: the Bibs API PUT

Updating a bib is a fetch–modify–put cycle, and the body must be the
`<bib>`-enveloped MARCXML — the wrapping element is exactly what the API
stripped on the way out. Envelope metadata (`mms_id`, `created_date`, ...)
is output-only; `marc_alma_bib_body(leader, fields)` rebuilds the minimal
envelope `<bib><record>…</record></bib>` from an edited record, XML-escaped
(`&<>"'`). Always fetch first and edit what came back: the fetched `005` is
what `stale_version_check=true` compares against the stored version, so a
record changed by someone else between your GET and PUT is refused instead
of silently overwritten (JSON bodies are not supported on this endpoint;
updating a CZ-linked record is not supported).

The transport is the community `http_request` extension — chosen over
`http_client`, which registers no `http_put` and hardwires POST bodies to
`application/json`. Because `http_request` keeps its own HTTP client, the
DuckDB `http` secret that authenticates the read path does **not** apply
here (only proxy settings are read from it); the key is a macro argument:

```sql
INSTALL http_request FROM community;
LOAD http_request;         -- required at USE time; marc21 loads without it
LOAD marc21; LOAD httpfs;  -- httpfs serves the fetch half

-- 1. Fetch the record (nested shape), apply the edit, build the body.
--    Table-function arguments take variables and literals, not subqueries
--    or lambda-bearing expressions, so the body lands in a variable first.
SET VARIABLE alma_body = (
    SELECT marc_alma_bib_body(leader,
               marc_set_subfield(fields, '040', 'd', 'MyORG'))
    FROM marc_readnestedxml(
        'https://api-na.hosted.exlibrisgroup.com/almaws/v1/bibs/9939332839702836?apikey=l8xxSANDBOXREAD'));

-- 2. PUT it back and inspect the response row.
SELECT status, body
FROM marc_alma_update_bib('https://api-na.hosted.exlibrisgroup.com',
                          '9939332839702836', 'l8xxSANDBOXWRITE',
                          getvariable('alma_body'),
                          stale_version_check := true);
```

`status = 200` returns the saved record's `<bib>` envelope in `body`
(re-fetch through `marc_readalma` to verify field-level results); anything
else returns Alma's `<web_service_result>` error report — a stale `005`
under `stale_version_check` surfaces there, in which case re-fetch, re-apply
the edit, and PUT again. `validate := true` additionally asks Alma to run
its validation and report errors. The helpers compose à la carte, too:
`marc_alma_put_url(base, mms_id, ...)` and `marc_alma_headers(apikey)` feed
`http_put` directly, and `marc_alma_put_sql(...)` prints the deferred
statement for auditing (the key is embedded — treat the output as a
credential).

### curl fallback (no community extensions)

Sites that cannot install community extensions keep the cataloging half in
SQL and hand the transport to curl — `marc_alma_bib_body` output is a
complete request body:

```sql
COPY (SELECT marc_alma_bib_body(leader,
                 marc_set_subfield(fields, '040', 'd', 'MyORG')) AS b
      FROM marc_readnestedxml('https://api-na.hosted.exlibrisgroup.com/almaws/v1/bibs/9939332839702836?apikey=...'))
TO 'bib_9939332839702836.xml' (FORMAT csv, HEADER false, QUOTE '');
```

```sh
curl -X PUT \
  -H 'Authorization: apikey l8xxSANDBOXWRITE' \
  -H 'Content-Type: application/xml' \
  --data-binary @bib_9939332839702836.xml \
  'https://api-na.hosted.exlibrisgroup.com/almaws/v1/bibs/9939332839702836?stale_version_check=true'
```

### Batch: import profiles

For more than a handful of records the batch write path is a file into an
Alma **import profile** (Repository/Update Inventory type; match on `035
$a` network number or MMS ID per profile config):

```sql
COPY (
    SELECT leader, marc_set_subfield(fields, '040', 'd', 'MyORG') AS fields
    FROM marc_readnestedxml('alma_export.xml')
) TO 'for_alma.xml' (FORMAT marcxml);   -- import profiles take MARCXML or binary MARC
```

Load the file via Resources → Import, or drop it on the profile's S3/FTP
watch location.
