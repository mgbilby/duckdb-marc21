-- ---------------------------------------------------------------------------
-- OAI-PMH resumption-token paging.  marc_readoai (macros.sql) reads ONE
-- ListRecords response page; a full harvest walks the chain of
-- resumptionTokens the repository hands back.  Everything here composes core
-- DuckDB (read_text, regexp_extract, url_encode) with a URL-scheme
-- filesystem (LOAD httpfs) and the built-in read_marcxml, per the
-- composition doctrine in docs/ECOSYSTEM.md — no HTTP code lives in marc21.
--
-- THE LOOP, HONESTLY: SQL has no recursion over HTTP.  A recursive CTE
-- cannot call read_marcxml/read_text with a value computed by the previous
-- iteration (table functions bind their path at plan time), so the page
-- chain is driven from OUTSIDE the statement — a shell loop, a client
-- language, or the CLI's own iteration — with two statements per page:
--
--   -- page N: records (append to the harvest table)
--   INSERT INTO harvest
--     SELECT * FROM marc_readoai_page('https://oai.example.org/oai', $token);
--   -- page N: the next token (NULL at the end of the list)
--   SELECT token FROM marc_oai_token(
--     marc_oai_page_url('https://oai.example.org/oai', $token));
--
-- with the first page coming from marc_readoai(base, ...) and
-- marc_oai_token(marc_oai_url(base, ...)) instead.  Each page is fetched
-- twice (once for records, once for the token); if that matters, read_text
-- once into a table and both parse the stored content: read_marcxml over a
-- saved file, marc_oai_extract_token over the text column.
-- docs/LINKING.md carries a complete shell-driven harvest recipe.
-- ---------------------------------------------------------------------------

-- First-page ListRecords URL.  Mirrors marc_readoai's arguments and adds the
-- optional selective-harvest window (from_/until_ are OAI-PMH UTCdatetime
-- strings, 'YYYY-MM-DD' or 'YYYY-MM-DDThh:mm:ssZ').
CREATE OR REPLACE MACRO marc_oai_url(base, metadata_prefix := 'marc21', set_ := NULL,
                                     from_ := NULL, until_ := NULL) AS
    base || '?verb=ListRecords&metadataPrefix=' || metadata_prefix ||
    coalesce('&set=' || url_encode(set_), '') ||
    coalesce('&from=' || url_encode(from_), '') ||
    coalesce('&until=' || url_encode(until_), '');

-- Follow-up page URL.  The protocol makes resumptionToken an EXCLUSIVE
-- argument: no metadataPrefix/set/from/until may accompany it, so the
-- builder deliberately takes nothing else.  Tokens are opaque and often
-- carry '/', '!', '+' or spaces — hence url_encode.
CREATE OR REPLACE MACRO marc_oai_page_url(base, resumption_token) AS
    base || '?verb=ListRecords&resumptionToken=' || url_encode(resumption_token);

-- Records of one follow-up page (same row shape as marc_readoai).
CREATE OR REPLACE MACRO marc_readoai_page(base, resumption_token) AS TABLE
SELECT * FROM read_marcxml(marc_oai_page_url(base, resumption_token));

-- The resumptionToken of one response, from its XML text: the element's
-- text content, whitespace-trimmed, NULL when the element is absent or
-- empty (an empty <resumptionToken/> is how a repository ends the list).
-- Scalar, so it works over any text source: read_text content, a stored
-- column, a literal.
CREATE OR REPLACE MACRO marc_oai_extract_token(xml) AS
    nullif(trim(regexp_extract(xml, '<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?resumptionToken[^>]*>([^<]*)', 1)), '');

-- The token plus its optional flow-control attributes for one response URL
-- (or local file), through read_text.  One row: token (NULL at the end of
-- the list), complete_list_size, cursor (both NULL when the repository does
-- not report them), expiration_date (text as sent).
CREATE OR REPLACE MACRO marc_oai_token(url) AS TABLE
SELECT marc_oai_extract_token(content) AS token,
       try_cast(nullif(regexp_extract(content, '<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?resumptionToken[^>]*completeListSize="([^"]*)"', 1), '')
                AS BIGINT) AS complete_list_size,
       try_cast(nullif(regexp_extract(content, '<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?resumptionToken[^>]*cursor="([^"]*)"', 1), '')
                AS BIGINT) AS cursor,
       nullif(regexp_extract(content, '<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?resumptionToken[^>]*expirationDate="([^"]*)"', 1), '')
           AS expiration_date
FROM read_text(url);
