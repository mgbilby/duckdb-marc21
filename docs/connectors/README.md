# ILS connectors

The `marc21` extension acts as a read-side SQL companion to the major
library-services platforms. The model is the same everywhere:

1. **Fetch** — a `marc_read*` URL-builder macro composes the platform's
   record-retrieval endpoint over `read_marcxml`/`read_marcjson`
   (`LOAD httpfs` first), or you point `read_marc`/`read_marcjson` at files
   the platform exported. FOLIO additionally supports in-place analytics over
   `ATTACH`ed PostgreSQL.
2. **Authenticate** — credentials never appear in query text: they ride in a
   DuckDB HTTP secret scoped to the platform's host
   (`CREATE SECRET (TYPE http, EXTRA_HTTP_HEADERS MAP {...}, BEARER_TOKEN ...,
   SCOPE '...')`).
3. **Analyze / edit** — every fetched record lands in the same nested
   `leader` + `fields` shape, so validation (`marc_validate*`), QA reports,
   crosswalks and the `marc_set_*`/`marc_remove_*`/`marc_merge` editing
   functions apply uniformly.
4. **Write back** — honestly: DuckDB only issues GETs. There is no POST/PUT
   from SQL, so writes always travel as files: `COPY ... (FORMAT marc |
   marcxml | marcjson)` produces the batch, and the platform's own import
   pipeline loads it. That pipeline is named on every platform page.

| Platform | Fetch | Auth | Write-back pipeline |
|---|---|---|---|
| [FOLIO](folio.md) | `marc_readfolio_srs`, `marc_readfolio_record`, `ATTACH` PostgreSQL, data-export files | Okapi token headers / DB credentials | FOLIO **Data Import** |
| [Koha](koha.md) | `marc_readkoha`, `marc_readkoha_public`, `marc_readkoha_opac`, `marc_readoai` | Basic/OAuth header (OPAC: none) | **bulkmarcimport.pl** / staged MARC import |
| [Ex Libris Alma](alma.md) | `marc_readalma`, `marc_readalma_bibs`, `marc_readalma_sru`, `marc_readoai` | API key (header or parameter) | Alma **import profiles** |
| [OCLC WorldShare](worldshare.md) | `marc_readworldshare` | OAuth2 bearer token (WSKey) | WorldShare **Data Sync** collections |
| [SirsiDynix Symphony](symphony.md) | `read_z3950`, `catalogdump`/`flatskip` file loop | Z39.50 / server shell | **catalogload** |

Every macro is defined in `src/macros/ils.sql` and registered at `LOAD
marc21`; the reader paths they compose are exercised by
`test/sql/marc_ils.test` over saved response fixtures in `test/data/`
(`sample_alma_bib.xml`, `sample_koha.xml`, `sample_worldshare.xml`,
`sample_folio_srs.json`).

## Envelope handling, precisely

* `read_marcxml` surfaces every `<record>` element (namespace prefixes
  ignored) and skips everything else, so any wrapper — SRU
  `searchRetrieve`, OAI-PMH `ListRecords`, Alma's `<bib>`/`<bibs>` — is
  transparent, and envelope metadata outside `<record>` contributes nothing.
* `read_marcjson` accepts a record object, an array of them, or NDJSON, and
  per object unwraps FOLIO's `{"parsedRecord": {...}}` and
  `{"content": {...}}` envelopes, and a top-level `{"sourceRecords": [...]}`
  or `{"records": [...]}` collection wrapper is read as one record per
  element.

## Paging

The URL builders fetch one response page per call, matching
`marc_readsru`/`marc_readoai`. For bulk work, prefer each platform's export
side (FOLIO data export or PostgreSQL, Alma publishing/OAI, Koha OAI,
Symphony `catalogdump`) over paging a record-by-record API.

To add a platform that is not listed here, see [SDK.md](SDK.md).
