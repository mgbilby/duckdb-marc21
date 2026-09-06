# Koha

| | |
|---|---|
| Canonical MARC store | `biblio_metadata` (MARCXML) in MySQL/MariaDB |
| Fetch | `marc_readkoha(base, biblio_id)`, `marc_readkoha_public(base, biblio_id)`, `marc_readkoha_opac(opac_base, biblio_id)`, `marc_readoai` |
| Auth | Basic or OAuth2 on `/api/v1/`; the OPAC export and OAI endpoints are anonymous |
| Local fields | `999 $c/$d` biblionumber, `942` bib-level item type, `952` items |
| Write-back | **bulkmarcimport.pl**, or staged MARC import (Stage MARC records → Manage staged records) |

## Auth setup

Koha's REST API content-negotiates: without `Accept:
application/marcxml+xml` it answers JSON, so the header goes in the secret
alongside the credentials:

```sql
INSTALL httpfs; LOAD httpfs; LOAD marc21;
CREATE SECRET koha_staff (
    TYPE http,
    EXTRA_HTTP_HEADERS MAP {
        'Accept': 'application/marcxml+xml',
        'Authorization': 'Basic <base64(user:password)>'
    },
    SCOPE 'https://staff.mylib.example'
);
```

For a quick anonymous read on any public Koha, skip the secret entirely and
use the OPAC export CGI, which serves MARCXML with no headers at all:

```sql
SELECT tag, code, value
FROM marc_readkoha_opac('https://opac.mylib.example', 70);
```

## Fetch

```sql
-- Staff REST API: GET /api/v1/biblios/70 (MARCXML via the Accept header)
SELECT * FROM marc_readkoha('https://staff.mylib.example', 70);

-- Public REST API (OPAC origin, no login; OPAC-hidden fields withheld)
SELECT * FROM marc_readkoha_public('https://opac.mylib.example', 70);

-- Bulk: Koha ships an OAI-PMH server on the OPAC
SELECT count(DISTINCT record_no)
FROM marc_readoai('https://opac.mylib.example/cgi-bin/koha/oai.pl',
                  metadata_prefix := 'marc21');
```

## Analyze

Koha keeps its own identifiers inside the record — `999 $c` is the
biblionumber, so API results join straight back to spreadsheet or SQL data
keyed on biblionumber:

```sql
SELECT marc_subfield(fields, '999', 'c')  AS biblionumber,
       marc_subfield(fields, '245', 'a')  AS title,
       marc_subfield(fields, '942', 'c')  AS item_type,
       marc_validate(leader, fields)      AS violations
FROM marc_readnestedxml('https://staff.mylib.example/api/v1/biblios/70');
```

(`marc_readnestedxml` is the nested-shape reader over the same URL the
`marc_readkoha` macro builds.)

## Edit and write back

Writes travel as files into Koha's import pipeline — either the staff
client's **Stage MARC records for import** / **Manage staged MARC records**
workflow, or `misc/migration_tools/bulkmarcimport.pl` on the server:

```sql
-- Batch-edit exported records, keep 999 $c so Koha matches existing biblios
COPY (
    SELECT leader,
           marc_set_subfield(fields, '040', 'd', 'MyORG') AS fields
    FROM read_marc('koha_export.mrc')
) TO 'for_koha.mrc' (FORMAT marc);
```

```
# server side (update matched biblios, keep items):
perl misc/migration_tools/bulkmarcimport.pl -b -update -match id -file for_koha.mrc
```

Staged import matches on a configurable rule (commonly `999$c` or ISBN);
`bulkmarcimport.pl` similarly keys on the record id. Strip `999 $c/$d` with
the editing functions only when you intend *new* biblios rather than
updates.
