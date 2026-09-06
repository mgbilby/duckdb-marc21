# Niche and composition in the DuckDB ecosystem

marc21 occupies one niche and defends it: **the MARC 21 record model and
cataloging semantics as first-class SQL**. Everything that is not that —
generic formats, transport, search infrastructure, generic string
matching — is deliberately left to DuckDB itself or to sibling community
extensions, and this extension is designed to compose with them in the same
`LOAD`ed session. Before adding a feature here, check this table: if a core
or community extension already covers the generic half, the right change is
a recipe or a thin macro that composes, not a reimplementation.

## What marc21 uniquely owns

* ISO 2709 reading/writing with per-record encoding detection, and full
  MARC-8 both directions from the Library of Congress code tables.
* The nested record model (`leader`, `fields`) with MARCspec addressing,
  Avram validation rulepacks, and format-aware rules.
* Cataloging semantics: RDA checks and generation, ISBD display, heading
  and identifier normalization (NACO, ISBN/ISSN/LCCN/OCLC), match keys,
  merge/diff/edit surgery, call-number parsing and sort keys.
* MARC serializations and dialects: MARCXML, MARC-in-JSON (FOLIO
  envelopes included), breaker text, Aleph sequential, MicroLIF, UNIMARC
  structure.
* A dependency-free Z39.50 client — a library protocol no general-purpose
  extension provides.
* Crosswalk *semantics* (MODS, MADS, DC/DCTERMS, EAD, ONIX, EDM,
  BIBFRAME, schema.org) — the mappings are bibliographic domain knowledge;
  the generic halves of those jobs compose per the table below.

## What marc21 deliberately does not rebuild

| Generic capability | Use jointly | How it composes with marc21 |
|---|---|---|
| Archives (zip, tar) | `zipfs`, `tarfs` (community) | glob `.mrc` members of vendor archives straight into `read_marc` |
| Collation, locale sorting | `icu` (core) | shelflist and heading reports `ORDER BY ... COLLATE` |
| Full-text search | `fts` (core) | index extracted subfield columns; marc21 supplies the extraction |
| Generic fuzzy matching / record linkage | `rapidfuzz`, `splink_udfs`, `duckdb_rphonetic` (community); `jaro_winkler_similarity` (core) | marc21 supplies NACO forms, match keys and clustering keys; heavier linkage models run on those columns |
| Generic XML/HTML querying | `webbed`, `html_query` (community) | query MODS/EAD/ONIX crosswalk *outputs*, or scrape non-MARC pages, then join on control numbers; MARCXML itself stays on the tuned built-in reader |
| HTTP POST/PUT (ILS write-back) | `http_client` / `http_request` (community) | `COPY` produces the MARCXML/JSON body; the request extension delivers it (Alma `PUT /almaws/v1/bibs/{mms_id}`, FOLIO imports) |
| HTTP(S)/S3 reading, gzip | `httpfs` (core) | every reader takes URLs; SRU/OAI macros build URLs over `read_marcxml` |
| JSON querying | `json` (core) | `marc_jsonld`/`marc_bibframe_jsonld` emit JSON text the `json` operators consume; API shapers use `read_json`; the extension loads without it by design |
| Other databases (FOLIO Postgres, SQLite, ES) | `postgres` / `sqlite` scanners (core), `elasticsearch` (community) | `ATTACH` the ILS database; `marc_parse_json` bridges its rows into the marc_* surface |
| RDF/SPARQL | `rdf` (community) | BIBFRAME and EDM crosswalk outputs are RDF/XML — load them there for graph queries |
| Remote filesystems | `sshfs`, `webdavfs`, `cache_httpfs` (community) | point the readers at dumps where they live |
| Scheduling, serving, plotting, LLM calls | `cronjob`, `httpserver`, `textplot`, `open_prompt`, ... | out of scope here, composable in session |
| Spreadsheets (xlsx, Google Sheets) | `read_csv` (core), `sheetreader`, `gsheets` (community) | `marc_from_delimited(material, mapping)` turns any of their rows into records |

Names above are community-repository extension names; availability varies
by platform and release. Nothing in marc21 *requires* any of them:
the extension stays 100% dependency-free so it loads everywhere, including
WASM — composition is opt-in per session.

## The test for new features

Ask: is the hard part MARC/cataloging knowledge, or generic plumbing?

* Cataloging knowledge (a mapping, a rule set, an encoding, a record
  operation) → belongs here.
* Generic plumbing (a transport, a file format that is not MARC, an index,
  a matching algorithm) → compose; add at most a recipe in
  `docs/RECIPES.md` or a thin macro that assumes the sibling extension is
  loaded (guard it the way the reconciliation macros document `read_json`).

## Language wrappers are not here either

Thin `pip`-style and crate-style entry points — connect, load the
extension, hand back readers as lazy relations — are sugar over the SQL
surface, not part of it. They live with the language companions, beside
the reference implementations they will be measured against, because they
follow a different release cadence and a different toolchain: a wrapper
fix should not wait for an extension release, and an extension release
should not wait for a wrapper's test matrix. This repository stays C++,
SQL, schemas, tests and specifications.
