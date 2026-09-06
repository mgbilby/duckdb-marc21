-- ---------------------------------------------------------------------------
-- ILS connector conveniences: URL builders over read_marcxml/read_marcjson
-- for the record-retrieval endpoints of FOLIO, Koha, Ex Libris Alma and OCLC
-- WorldShare.  All of them need a filesystem for the URL scheme (LOAD httpfs)
-- and, except where noted, credentials supplied out-of-band through a DuckDB
-- HTTP secret (CREATE SECRET ... TYPE http, extra_http_headers / bearer_token,
-- SCOPE'd to the ILS host) so keys never appear in query text.  See
-- docs/connectors/ for per-platform auth and paging patterns.
--
-- Envelope handling is the readers': read_marcxml surfaces every
-- <record> regardless of wrapper elements (Alma's <bib>/<bibs>, SRU, OAI-PMH),
-- read_marcjson unwraps FOLIO's parsedRecord/content per record object.
-- ---------------------------------------------------------------------------

-- Ex Libris Alma Bibs API: one bib by MMS ID.  Returns the <bib>-enveloped
-- MARCXML from GET {base}/almaws/v1/bibs/{mms_id}.  base is the regional API
-- gateway plus nothing else, e.g. 'https://api-na.hosted.exlibrisgroup.com'.
-- Auth: either pass apikey := '...' (Alma accepts the key as a query
-- parameter) or leave it NULL and ship an 'Authorization: apikey ...' header
-- in an HTTP secret.
CREATE OR REPLACE MACRO marc_readalma(base, mms_id, apikey := NULL) AS TABLE
SELECT * FROM read_marcxml(
    base || '/almaws/v1/bibs/' || mms_id ||
    coalesce('?apikey=' || url_encode(apikey), ''));

-- Ex Libris Alma Bibs API: up to 100 bibs per call.  mms_ids is the
-- comma-separated MMS ID list GET {base}/almaws/v1/bibs?mms_id=... expects;
-- the <bibs> wrapper is transparent, so one row set covers all records.
CREATE OR REPLACE MACRO marc_readalma_bibs(base, mms_ids, apikey := NULL) AS TABLE
SELECT * FROM read_marcxml(
    base || '/almaws/v1/bibs?view=full&expand=None&mms_id=' || mms_ids ||
    coalesce('&apikey=' || url_encode(apikey), ''));

-- Ex Libris Alma SRU (no API key needed; sets/bulk retrieval story).  Alma
-- publishes SRU at {domain}/view/sru/{institution_code}; this delegates to
-- marc_readsru for the searchRetrieve parameters.  Alma has no REST endpoint
-- that returns a set's members as MARCXML in one call, so for itemized sets
-- fetch the member MMS IDs from /almaws/v1/conf/sets/{id}/members and batch
-- them through marc_readalma_bibs.
CREATE OR REPLACE MACRO marc_readalma_sru(base, inst_code, query_, max_records := 50) AS TABLE
SELECT * FROM marc_readsru(base || '/view/sru/' || inst_code, query_,
                           max_records := max_records);

-- Koha REST API: one biblio as MARCXML from GET {base}/api/v1/biblios/{id}.
-- base is the *staff* interface origin, e.g. 'https://staff.mylib.example'.
-- Koha content-negotiates: without an 'Accept: application/marcxml+xml'
-- header it answers JSON, so scope an HTTP secret with that header (plus
-- Basic credentials or an OAuth bearer token) to the host.
CREATE OR REPLACE MACRO marc_readkoha(base, biblio_id) AS TABLE
SELECT * FROM read_marcxml(base || '/api/v1/biblios/' || biblio_id);

-- Koha public REST API: same record via the OPAC origin's anonymous
-- endpoint GET {base}/api/v1/public/biblios/{id} (fields the library marked
-- hidden-in-OPAC are withheld).  Needs the same Accept header secret.
CREATE OR REPLACE MACRO marc_readkoha_public(base, biblio_id) AS TABLE
SELECT * FROM read_marcxml(base || '/api/v1/public/biblios/' || biblio_id);

-- Koha OPAC export (works on any Koha OPAC with no headers and no auth):
-- GET {opac_base}/cgi-bin/koha/opac-export.pl?op=export&format=marcxml&bib=N
-- serves MARCXML directly, which makes it the zero-configuration reader.
CREATE OR REPLACE MACRO marc_readkoha_opac(opac_base, biblio_id) AS TABLE
SELECT * FROM read_marcxml(
    opac_base || '/cgi-bin/koha/opac-export.pl?op=export&format=marcxml&bib='
              || biblio_id);

-- OCLC WorldShare / WorldCat Metadata API v2: one bib by OCLC number from
-- GET {base}/worldcat/manage/bibs/{oclc_number}; base is normally
-- 'https://metadata.api.oclc.org'.  Auth is OAuth2 client-credentials: put
-- the token in an HTTP secret's bearer_token and add an
-- 'Accept: application/marcxml+xml' header.  The response is the bare
-- MARCXML record (001/003 carry the OCLC number and OCoLC).
CREATE OR REPLACE MACRO marc_readworldshare(base, oclc_number) AS TABLE
SELECT * FROM read_marcxml(base || '/worldcat/manage/bibs/' || oclc_number);

-- FOLIO Source Record Storage: the source MARC for one *instance* UUID via
-- GET {okapi}/source-storage/records/{instance_uuid}/formatted?idType=INSTANCE,
-- which returns a single source record object whose parsedRecord.content
-- read_marcjson unwraps.  okapi_base is the Okapi/Kong gateway origin; scope
-- an HTTP secret carrying x-okapi-tenant and x-okapi-token headers to it.
CREATE OR REPLACE MACRO marc_readfolio_srs(okapi_base, instance_uuid) AS TABLE
SELECT * FROM read_marcjson(
    okapi_base || '/source-storage/records/' || instance_uuid ||
    '/formatted?idType=INSTANCE');

-- FOLIO SRS collection endpoint /source-storage/source-records: the
-- {"sourceRecords": [...], "totalRecords": N} wrapper is unwrapped by
-- read_marcjson, one row per record.  Page with limit/offset; for
-- whole-tenant work ATTACH the FOLIO PostgreSQL instead
-- (docs/connectors/folio.md).
CREATE OR REPLACE MACRO marc_readfolio_source_records(okapi_base, lim, off) AS TABLE
SELECT * FROM read_marcjson(
    okapi_base || '/source-storage/source-records?limit=' || lim ||
    '&offset=' || off);

-- FOLIO Source Record Storage by SRS record UUID (the 999 ff $s value):
-- GET {okapi}/source-storage/records/{record_uuid}.
CREATE OR REPLACE MACRO marc_readfolio_record(okapi_base, record_uuid) AS TABLE
SELECT * FROM read_marcjson(
    okapi_base || '/source-storage/records/' || record_uuid);

-- ---------------------------------------------------------------------------
-- Alma write-back: PUT /almaws/v1/bibs/{mms_id} composed over the community
-- http_request extension (INSTALL http_request FROM community; LOAD
-- http_request).  marc21 owns the cataloging half — the <bib> envelope, the
-- MARCXML body, the URL and header conventions; the transport is
-- http_request's http_put table function (docs/ECOSYSTEM.md).  Alma updates
-- a bib on PUT only (POST to /almaws/v1/bibs creates a record), which rules
-- out the sibling http_client extension for this endpoint: it registers
-- http_head/http_get/http_post/http_post_form and no http_put, and its
-- http_post hardwires an application/json body.  http_request's http_put
-- table function takes body := BLOB and content_type := VARCHAR named
-- parameters and returns status/content_type/content_length/headers/
-- cookies/body columns.  Note http_request reads DuckDB http secrets for
-- proxy settings only, not extra_http_headers/bearer_token, so unlike the
-- readers above the API key is a macro argument here.
--
-- BINDING.  Macro bodies — table macros included — resolve every function
-- name when the macro is created, and these embedded macros are created at
-- LOAD marc21; a direct http_put reference would therefore make marc21
-- unloadable wherever http_request is absent.  marc_alma_update_bib must be
-- a TABLE macro because the one deferral mechanism is core DuckDB's query()
-- table function: the PUT statement is composed as text (marc_alma_put_sql)
-- and query() parses it only when the macro is USED — the moment by which
-- LOAD http_request must have happened.  A second engine limit shapes the
-- signature: table-function arguments cannot carry lambda expressions
-- (DuckDB 1.5.x rejects nested lambdas there and mis-binds struct access),
-- and marc_alma_bib_body iterates fields with lambdas, so the update macro
-- takes the finished body string, built beforehand in an ordinary SELECT —
-- the SET VARIABLE pattern in docs/connectors/alma.md.
-- ---------------------------------------------------------------------------

-- XML escape for the Alma body: marc_xml_escape (&<>") plus apostrophe, so
-- the same helper serves element content and either attribute quoting.
CREATE OR REPLACE MACRO marc_alma_xml_escape(s) AS
    replace(marc_xml_escape(s), chr(39), '&apos;');

-- The <bib><record>...</record></bib> envelope Alma's PUT expects, from one
-- record's leader and nested fields.  Same slim layout the COPY (FORMAT
-- marcxml) writer emits (control vs data fields by subfields IS NULL, NULL
-- indicators as blanks), minus the collection wrapper and pretty-printing;
-- Alma's REST responses carry <record> without a namespace and accept the
-- same back.  Envelope metadata elements (mms_id, created_date, ...) are
-- output-only on GET and are not required on PUT; with
-- stale_version_check := true the record's own 005 field is what must match
-- the database copy, so fetch first and edit what came back.
CREATE OR REPLACE MACRO marc_alma_bib_body(leader, fields) AS
    '<bib><record><leader>' || marc_alma_xml_escape(leader) || '</leader>'
    || array_to_string(list_transform(fields, lambda f:
           CASE WHEN f.subfields IS NULL
                THEN '<controlfield tag="' || marc_alma_xml_escape(f.tag) || '">'
                     || marc_alma_xml_escape(f.value) || '</controlfield>'
                ELSE '<datafield tag="' || marc_alma_xml_escape(f.tag)
                     || '" ind1="' || marc_alma_xml_escape(coalesce(f.ind1, ' '))
                     || '" ind2="' || marc_alma_xml_escape(coalesce(f.ind2, ' '))
                     || '">'
                     || array_to_string(list_transform(f.subfields, lambda sf:
                            '<subfield code="' || marc_alma_xml_escape(sf.code) || '">'
                            || marc_alma_xml_escape(sf.value) || '</subfield>'), '')
                     || '</datafield>'
           END), '')
    || '</record></bib>';

-- Update-endpoint URL: {base}/almaws/v1/bibs/{mms_id} with the documented
-- update parameters.  validate := true asks Alma to run validation and
-- report errors; stale_version_check := true makes Alma refuse the PUT when
-- the record's 005 no longer matches the stored version (the optimistic-
-- locking guard — Alma's other concurrency defaults are permissive:
-- override_warning and override_lock both default to true server-side).
-- apikey stays NULL when the key travels as a header (marc_alma_headers).
CREATE OR REPLACE MACRO marc_alma_put_url(base, mms_id, apikey := NULL,
                                          validate := false,
                                          stale_version_check := false) AS
    base || '/almaws/v1/bibs/' || mms_id
         || '?validate=' || validate
         || '&stale_version_check=' || stale_version_check
         || coalesce('&apikey=' || url_encode(apikey), '');

-- Request headers for the Bibs API: Alma's documented header form of API-key
-- auth is 'Authorization: apikey {key}'; Accept pins the XML response.  The
-- MAP feeds http_request's headers := parameter directly.
CREATE OR REPLACE MACRO marc_alma_headers(apikey) AS
    CASE WHEN apikey IS NULL
         THEN MAP {'Accept': 'application/xml'}
         ELSE MAP {'Accept': 'application/xml',
                   'Authorization': 'apikey ' || apikey}
    END;

-- One SQL string literal: quotes doubled, wrapped in single quotes — for
-- embedding values in the deferred statement below.
CREATE OR REPLACE MACRO marc_alma_sql_quote(s) AS
    chr(39) || replace(s, chr(39), chr(39) || chr(39)) || chr(39);

-- The deferred PUT statement as text.  Everything the request needs — URL,
-- headers with the key, the XML body — is embedded as quoted literals, so
-- the emitted statement is self-contained and equally usable for auditing
-- (SELECT marc_alma_put_sql(...) shows exactly what will run, key included:
-- treat the output as a credential).
CREATE OR REPLACE MACRO marc_alma_put_sql(base, mms_id, apikey, bib_body,
                                          validate := false,
                                          stale_version_check := false) AS
    'SELECT status, content_type, decode(body) AS body FROM http_put('
    || marc_alma_sql_quote(marc_alma_put_url(base, mms_id,
                               validate := validate,
                               stale_version_check := stale_version_check))
    || ', headers := MAP {' || marc_alma_sql_quote('Accept') || ': '
    || marc_alma_sql_quote('application/xml')
    || coalesce(', ' || marc_alma_sql_quote('Authorization') || ': '
                     || marc_alma_sql_quote('apikey ' || apikey), '')
    || '}, body := encode(' || marc_alma_sql_quote(bib_body)
    || '), content_type := ' || marc_alma_sql_quote('application/xml') || ')';

-- Issue the update (needs LOAD http_request at USE time, per the binding
-- note above).  bib_body is the marc_alma_bib_body output, built in a prior
-- SELECT (SET VARIABLE body = (...); then getvariable('body') here — table-
-- function arguments take variables and literals, not subqueries).  Returns
-- one row: status (200 on success), content_type, body (the saved record's
-- <bib> envelope on success, a <web_service_result> error report
-- otherwise).  This updates a production catalog record — see the warnings
-- in docs/connectors/alma.md before pointing it anywhere but a sandbox.
CREATE OR REPLACE MACRO marc_alma_update_bib(base, mms_id, apikey, bib_body,
                                             validate := false,
                                             stale_version_check := false) AS TABLE
SELECT * FROM query(marc_alma_put_sql(base, mms_id, apikey, bib_body,
                                      validate := validate,
                                      stale_version_check := stale_version_check));
