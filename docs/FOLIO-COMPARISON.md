# marc21 × FOLIO: feature comparison and tandem doctrine

This document compares the marc21 DuckDB extension against the MARC 21
cataloging feature set of [FOLIO](https://github.com/folio-org) (Apache-2.0
library services platform, docs at [dev.folio.org](https://dev.folio.org)),
answering three questions:

1. which FOLIO cataloging capabilities the extension already replicates,
2. which it could and should replicate (with effort and defining sources),
3. which should deliberately stay unreplicated so the extension complements a
   live FOLIO tenant instead of pretending to be one.

Every FOLIO claim links to the module repo or file it came from. Extension
claims are limited to functions that exist in
[docs/REFERENCE.md](REFERENCE.md), `src/macros.sql`, `src/macros/ils.sql`, or
the C++ scalars, and were verified against the test suite before being cited.

Classification legend:

* **REPLICATED** — the extension provides an equivalent of the capability's
  *cataloging semantics* today (batch/SQL form, not the interactive or
  service form).
* **REPLICABLE (S/M/L)** — worth building; small / medium / large effort.
* **TANDEM** — deliberately not replicated; FOLIO's job, with the
  extension playing a complementary read-side or preparation role.

---

## 1. Feature matrix

| # | FOLIO capability | Module | Extension today | Classification |
|---|---|---|---|---|
| 1 | Interactive quickMARC editor UI: per-field editing grid, create/edit/derive actions for bib, holdings, authority ("a single Stripes plugin of type `quick-marc`") | [ui-quick-marc](https://github.com/folio-org/ui-quick-marc), [mod-quick-marc](https://github.com/folio-org/mod-quick-marc) | None; the extension is headless SQL by design | **TANDEM** — a multi-user editing UI with tenant auth and async save (`PUT /records-editor/records/{id}` returns 202) belongs to the platform; the extension edits *files and result sets*, not live records |
| 2 | MARC field edit operations: add/delete fields, set subfields, change indicators, find-and-replace — the operations quickMARC and Data Import "modify" actions perform | [mod-quick-marc](https://github.com/folio-org/mod-quick-marc), [mod-di-converter-storage](https://github.com/folio-org/mod-di-converter-storage) | `marc_add_field`, `marc_remove_fields`, `marc_remove_subfield`, `marc_set_subfield`, `marc_replace_values`, `marc_set_indicators`, `marc_move_field`, `marc_copy_field`, `marc_change_case`, `marc_remove_fields_where`, `marc_build_field`, `marc_merge`, `marc_diff` — composable in UPDATE/SELECT over whole corpora | **REPLICATED** (batch form; superset of the per-record operations) |
| 3 | Specification-driven MARC validation: 16 rules (`undefinedField`, `nonRepeatableField`, `missingField`, `invalidIndicator`, `undefinedSubfield`, `nonRepeatableSubfield`, `invalidLccnSubfieldValue`, …) with ERROR (blocks save) vs WARNING severity, driven entirely by a stored specification — "disabled rules are silently skipped" | [mod-record-specifications](https://github.com/folio-org/mod-record-specifications), rules in [docs/features/record-validation.md](https://github.com/folio-org/mod-record-specifications/blob/master/docs/features/record-validation.md) | `marc_validate` (structural), `marc_validate_avram(schema_json)` (any Avram-subset spec, same schema-driven philosophy), `marc_validate_bib`/`_auth`/`_holdings`/`_format` rulepacks generated from `schemas/*.avram.json` | **REPLICATED** (same rule families via Avram schemas; no error/warn severity split — violations are one list) |
| 4 | Tenant-local validation spec: institutions define local fields, required fields, subfield/indicator codes via the specification-storage API; quickMARC picks changes up from the `specification-storage.specification.updated` Kafka topic | [mod-record-specifications](https://github.com/folio-org/mod-record-specifications) | `marc_validate_avram` accepts any schema JSON, but nothing converts a FOLIO specification document into Avram | **REPLICABLE (S)** — a `marc_folio_spec_to_avram(spec_json)` conversion macro; the tenant's live spec (one GET) then drives file validation identical to what quickMARC will enforce on save |
| 5 | Derive new MARC bib: copy an existing bib as the start of a new record (quickMARC "derive" action) | [ui-quick-marc](https://github.com/folio-org/ui-quick-marc) | All the parts exist (`marc_remove_fields` for 999/001/035, `marc_stamp`, editing macros) but no one-call macro | **REPLICABLE (S)** — `marc_derive(leader, fields)`: strip `999 ff`, 001/003, FOLIO-assigned 035s, reset Leader/05 to `n`; mirrors what quickMARC derive drops |
| 6 | Optimistic locking on save: storage rejects stale versions (`DB_ALLOW_SUPPRESS_OPTIMISTIC_LOCKING` exists precisely to suppress it during migrations) | [mod-inventory-storage](https://github.com/folio-org/mod-inventory-storage), [dev.folio.org](https://dev.folio.org/guides/) | None, deliberately | **TANDEM** — version arbitration only means something inside the system of record; the extension is read-only toward FOLIO and writes only files |
| 7 | MARC authority editing and validation (quickMARC authority mode: 1XX required/unique, 010 unique) | [mod-quick-marc](https://github.com/folio-org/mod-quick-marc) | Authority files edit with the same field macros; `marc_validate_auth` rulepack; `marc_authority_refs` (1XX/4XX/5XX extraction), `marc_heading_flips` (see-from matching) | **REPLICATED** (batch form) |
| 8 | SRS canonical record store: rawRecord + parsedRecord, `matchedId`, **generations** incremented per re-import, snapshots (job linkage), `leader_record_status` trigger column | [mod-source-record-storage](https://github.com/folio-org/mod-source-record-storage) | The extension reads this model but keeps no store of its own | **TANDEM** — SRS *is* the system of record; duplicating generations/snapshots would fork provenance. The extension's `marc_leader_pos(leader, 5)` covers status queries on extracted data |
| 9 | SRS read access: parsedRecord JSON, single-record and collection endpoints | [mod-source-record-storage](https://github.com/folio-org/mod-source-record-storage) | `marc_parse_json` (raw content, `{"content":...}`, `{"parsedRecord":...}` envelopes), `read_marcjson` (incl. the `{"sourceRecords":[...]}` collection envelope — see `src/core/marcjson.cpp` and `test/sql/marc_envelopes.test`), `marc_readfolio_srs` / `marc_readfolio_record` / `marc_readfolio_source_records` macros, ATTACH-the-Postgres pattern over `marc_records_lb` | **REPLICATED** (read side) |
| 10 | `marc_indexers` field tables: SRS explodes parsedRecord JSON into `(field_no, ind1, ind2, subfield_no, value, marc_id)` rows so the Search API can query by field ([fill_marc_indexers.sql](https://github.com/folio-org/mod-source-record-storage/blob/master/mod-source-record-storage-server/src/main/resources/migration_scripts/fill_marc_indexers.sql)) | [mod-source-record-storage](https://github.com/folio-org/mod-source-record-storage) | `read_marc_subfields` / `read_marcjson` produce exactly this shape (tag, ind1, ind2, code, value, record_no) as the extension's *primary* analytical primitive — computed on the fly, no materialized tables or version-cleanup verticles needed | **REPLICATED** (and simpler: a column-store scan replaces the maintained index tables) |
| 11 | MARC→Instance mapping: the 28,099-line [marc_bib_rules.json](https://github.com/folio-org/mod-source-record-manager/blob/master/mod-source-record-manager-server/src/main/resources/rules/marc_bib_rules.json) rule set (targets like `hrid`, `languages`, `dates.date1`; condition functions `char_select`, `trim_punctuation`, `set_identifier_type_id_by_name`, `set_instance_type_id`, `set_deleted`…), tenant-customizable via the `/mapping-rules` API | [mod-source-record-manager](https://github.com/folio-org/mod-source-record-manager) | `marc_instance(leader, fields)` — a fixed, hand-written subset (title, contributors, identifiers, publication, languages, subjects, edition, physical description) modeled on the default mapping; no rules-file interpreter, no tenant customization, no reference-UUID resolution | **REPLICABLE (L)** — see shortlist §3.1; today's `marc_instance` is a useful approximation, not the rule engine |
| 12 | Import-side identifier management: strip incoming 001, assign FOLIO HRID, write `999 ff $s` (SRS id) / `$i` (instance id), preserve OCLC numbers by field migration | [mod-source-record-manager](https://github.com/folio-org/mod-source-record-manager) | `marc_folio_check` warns about pre-existing `999 ff` and missing 001/003 *before* import; `marc_subfield(fields,'999','s'/'i')` reads the linkage afterward for SQL joins to `instance` (docs/connectors/folio.md) | **TANDEM** — HRID and UUID minting must be single-sourced in the tenant; the extension's role is pre-flight QA and post-hoc join analytics on the convention |
| 13 | Data-import orchestration: S3 upload, `SPLIT_FILES_ENABLED` chunking (1,000 records/part), queue scoring by "job size, age, tenant usage", Kafka consumers, job executions with progress states | [mod-data-import](https://github.com/folio-org/mod-data-import), [mod-source-record-manager](https://github.com/folio-org/mod-source-record-manager) | None; `COPY ... (FORMAT marc)` writes the clean UTF-8 file that gets uploaded | **TANDEM** — multi-tenant distributed job plumbing is the opposite of an embedded analytical engine; replicating it would re-implement FOLIO badly |
| 14 | Match profiles: configurable MARC-to-MARC / MARC-to-Inventory matching (e.g. on 001, 035, `999 ff $s`, identifiers) deciding create vs update vs discard | [mod-di-converter-storage](https://github.com/folio-org/mod-di-converter-storage) | Building blocks: `marc_matchkey`/`marc_dedupe_key`, `marc_isbn13`/`marc_oclc`/`marc_lccn` normalizers, `marc_dedupe_candidates`, plain SQL joins against ATTACHed SRS | **REPLICABLE (M)** — a match-profile *preview*: given the profile's match criteria, report which incoming records would match which existing SRS/instances before the job runs (see §3.4) |
| 15 | Action-profile "modify MARC" step: declarative field modifications applied during import | [mod-di-converter-storage](https://github.com/folio-org/mod-di-converter-storage) | The full editing macro set (row 2) applied at file level pre-import | **REPLICATED** (pre-import batch form) |
| 16 | Inventory domain: instance/holdings/item storage, reference data (instance types, identifier types, contributor types as tenant UUIDs), bulk interface `instance-storage-bulk` | [mod-inventory](https://github.com/folio-org/mod-inventory), [mod-inventory-storage](https://github.com/folio-org/mod-inventory-storage) | Read-only via ATTACH (`instance.jsonb` joins in docs/connectors/folio.md); `marc_instance` emits names/values, never tenant UUIDs | **TANDEM** — entity storage, reference data governance and entity writes are FOLIO's; the extension reads them in place |
| 17 | Authority linking rules: which bib fields are linkable to which authority fields with which subfields — e.g. rule 1: bib 100 ↔ authority 100 `$a$b$c$d$j$q`; rule 5: bib 240 ↔ authority 100 with `subfieldModifications` `t→a` and required-`$t` validation; `autoLinkingEnabled` flags ([instance-authority.json](https://github.com/folio-org/mod-entities-links/blob/master/src/test/resources/linking-rules/instance-authority.json)) | [mod-entities-links](https://github.com/folio-org/mod-entities-links), [doc/documentation.md](https://github.com/folio-org/mod-entities-links/blob/master/doc/documentation.md) | `marc_headings`, `marc_authority_refs`, `marc_heading_flips`, `marc_naco` cover heading extraction and see-from flips, but the linkable-field/subfield rule table itself is not encoded | **REPLICABLE (S)** — port the rules file as a rulepack macro (see §3.3) |
| 18 | Auto-link suggestions: `POST /records-editor/links/suggestion` proposes authority links for bib headings | [mod-quick-marc](https://github.com/folio-org/mod-quick-marc), [mod-entities-links](https://github.com/folio-org/mod-entities-links) | `marc_reconcile_headings` + id.loc.gov/VIAF/Wikidata URL builders and candidate shapers (fetch-then-shape) — reconciliation against *external* authorities, not the tenant's authority store | **REPLICABLE (M)** — same suggestion semantics against ATTACHed `mod_entities_links`/authority storage: NACO-normalized join of bib headings to authority 1XX/4XX under the row-17 rules |
| 19 | Live authority control: `$0` (natural id) + `$9` (authority UUID) written into linked bib fields, links re-written when authorities change, ACTUAL/ERROR link status, authority statistics propagated by events, 7-day deleted-authority archive | [mod-entities-links](https://github.com/folio-org/mod-entities-links) | Post-hoc audit is pure SQL today (`marc_subfields(fields,'6xx','9')` joined to authority tables); no event handling, by design | **TANDEM** — keeping thousands of bib links consistent as authorities change is Kafka-event work that must happen inside the tenant; the extension audits the *result* (orphan `$9`s, headings that drifted from their authority) |
| 20 | Export of underlying SRS MARC (data export for instances with source records; `999 ff` handling; `.mrc` to S3 as `/{tenantId}/{jobExecutionId}/{fileName}.mrc`) | [mod-data-export](https://github.com/folio-org/mod-data-export) | `COPY (... FROM srs) TO 'f' (FORMAT marc)` from ATTACHed Postgres or saved API JSON; UTF-8 or MARC-8, NFC or NFD | **REPLICATED** (read-and-write-file side; no job/S3 orchestration, none wanted) |
| 21 | Generated MARC from Inventory: [rulesDefault.json](https://github.com/folio-org/mod-data-export/blob/master/src/main/resources/rules/rulesDefault.json) builds MARC on the fly from instance JSON (`$.instance.hrid`→001, `set_transaction_datetime`→005, `set_fixed_length_data_elements`→008, identifier rules per type), plus holdings/item rules ([holdingsRulesDefault.json](https://github.com/folio-org/mod-data-export/blob/master/src/main/resources/rules/holdingsRulesDefault.json)) and tenant `RULES_OVERRIDE` via mod-configuration | [mod-data-export](https://github.com/folio-org/mod-data-export) | Nothing generates MARC *from instance JSON*; `marc_from_delimited` proves the record-construction machinery exists | **REPLICABLE (M)** — see §3.2: export FOLIO-source (non-MARC) instances and appended holdings/items as MARC straight from ATTACHed inventory tables |
| 22 | Bulk MARC remapping when mapping rules change: chunked (500 records, 4 threads) two-phase `data_mapping` → `data_saving` operations, saving via `instance-storage-bulk` ([doc/documentation.md](https://github.com/folio-org/mod-marc-migrations/blob/master/doc/documentation.md)) | [mod-marc-migrations](https://github.com/folio-org/mod-marc-migrations) | No write-back (correct); once §3.1 lands, the *mapping* phase becomes a query, enabling dry-run drift reports | **TANDEM** (the saving half; the mapping half is the strongest argument for §3.1) |
| 23 | Discovery search & browse: Kafka-fed OpenSearch/Elasticsearch, CQL over titles/contributors/identifiers/holdings, "up to 5 languages" of analyzers, call-number / subject / contributor browse | [mod-search](https://github.com/folio-org/mod-search) | Ad-hoc SQL over `read_marc_subfields` answers offline questions; `marc_lcc_sortkey`/`marc_ddc_sortkey` give shelflist order (the analytical cousin of call-number browse); no serving layer | **TANDEM** — patron-facing, always-on, language-analyzed search is infrastructure; the extension's niche is questions the search UI cannot express (arbitrary joins, aggregations, regressions over time) |
| 24 | OAI-PMH provider: verbs, `marc21`/`marc21_withholdings`/`oai_dc`, records sourced from SRS or Inventory, suppression handling | [mod-oai-pmh](https://github.com/folio-org/mod-oai-pmh) | Client only: `marc_readoai` (ListRecords page), `read_marcxml` handles OAI envelopes | **TANDEM** — serving harvesters is a platform duty; the extension is the *harvester's* analysis tool (including QA of what mod-oai-pmh emits) |
| 25 | Z39.50/SRU serving of FOLIO data (z2folio: "USMARC, OPAC, XML and JSON formats", backed by mod-search + mod-graphql + SRS) | [Net-Z3950-FOLIO](https://github.com/folio-org/Net-Z3950-FOLIO) | Client only: `read_z3950` (independent Z39.50-1995 client), `marc_readsru` — the other end of the wire | **TANDEM** — perfectly complementary: the extension can QA a z2folio endpoint from the outside |
| 26 | OCLC Connexion intake: edge listener using "the `copycat-imports` interface" and the WorldCat copycat profile | [edge-connexion](https://github.com/folio-org/edge-connexion) | `marc_readworldshare`, `read_z3950` cover copy-cataloging *retrieval* for file-based prep, not the live gateway | **TANDEM** — an always-listening authenticated edge service; nothing to gain from a SQL replica |
| 27 | Bulk edit of MARC instance fields: per-rule `{tag, ind1, ind2, subfield, actions[]}` model ([marc_rule_details.json](https://github.com/folio-org/mod-bulk-operations/blob/master/src/main/resources/swagger.api/schemas/marc_rule_details.json)), FQM-driven record sets, preview-then-commit | [mod-bulk-operations](https://github.com/folio-org/mod-bulk-operations) | The same rule semantics as composable SQL (row 2 macros) over any predicate DuckDB can express — a strict superset of the FQM predicate language for *analysis*; commit stays with FOLIO | **REPLICATED** (rule semantics and preview, on files/extracts; committing to the tenant remains Data Import / bulk-ops) |

---

## 2. Tandem doctrine — what the source actually supports

The working hypothesis was: FOLIO is the system of record; the extension does
(a) pre-load QA, (b) post-hoc SQL analytics, (c) bulk analysis the UI cannot.
The source largely confirms it, and sharpens it in four ways.

**Confirmed: consistency in FOLIO is event plumbing, and it is everywhere.**
Every boundary the extension might be tempted to cross is held together by
Kafka: data import chunks flow through Kafka consumers
([mod-source-record-manager](https://github.com/folio-org/mod-source-record-manager)),
[mod-search](https://github.com/folio-org/mod-search) indexes from inventory
and authority topics, [mod-entities-links](https://github.com/folio-org/mod-entities-links)
propagates authority-change and statistics events across consortium tenants,
and even quickMARC validation subscribes to
`specification-storage.specification.updated`
([mod-quick-marc](https://github.com/folio-org/mod-quick-marc)). Optimistic
locking is enforced in storage itself
(mod-inventory-storage's `DB_ALLOW_SUPPRESS_OPTIMISTIC_LOCKING` exists only to
switch it off for migrations), and SRS versions records through generations
and snapshots. An embedded, single-process analytical engine cannot
participate in any of that without becoming another FOLIO — so it must not
write to the tenant, ever. The extension's existing posture (ATTACH
`READ_ONLY`, output is always a *file* handed to Data Import) is exactly
right.

**Sharpened: "mapping is mostly identifiers", which cuts both ways.** The
default bib-to-instance rules resolve values into tenant reference-data UUIDs
(`set_instance_type_id`, `set_identifier_type_id_by_name`,
`set_issuance_mode_id` in
[marc_bib_rules.json](https://github.com/folio-org/mod-source-record-manager/blob/master/mod-source-record-manager-server/src/main/resources/rules/marc_bib_rules.json)).
A standalone re-implementation can never emit correct instances because it
lacks the tenant's reference tables — *unless* it is running against the
ATTACHed tenant database, where those tables are one join away. Conclusion: a
SQL mapping engine (§3.1) is feasible and honest **as an audit/dry-run tool**
in tandem mode, and its output should still never be written back directly;
FOLIO ships `instance-storage-bulk` and
[mod-marc-migrations](https://github.com/folio-org/mod-marc-migrations) for
that.

**Sharpened: the highest-value niche is rule-drift auditing, not just QA and
reporting.** FOLIO itself demonstrates the pain point: it built a whole
module, mod-marc-migrations, because "updating the existing authority records
when mapping rules are changed" is expensive, chunked, two-phase work inside
the platform. No FOLIO module offers a *read-only* answer to "what would the
current (or proposed) rules produce, and where does Inventory disagree?" The
connector docs' `marc_title` vs `instance_title` join is the embryo of this;
with §3.1 it becomes a full mapping-drift report — arguably the strongest
tandem feature the extension can offer, and one that makes the FOLIO
migration module *more* useful (run the dry run here, run the real migration
there).

**Corrected: "generated vs source" export is two capabilities, not one.**
[mod-data-export](https://github.com/folio-org/mod-data-export) exports
underlying SRS records where they exist (replicated today via
`COPY (FORMAT marc)`) but *generates* MARC from instance/holdings/item JSON
for FOLIO-source records via rulesDefault.json. The generated half is a
genuine gap (§3.2), not covered by the current "read SRS and write a file"
story — and it matters precisely for the records that have **no** source MARC
to read.

One nuance on the extension's own framing: `marc_folio_check` and
docs/connectors/folio.md describe FOLIO as "matching on 001+003". In the
source, matching is **profile-driven**
([mod-di-converter-storage](https://github.com/folio-org/mod-di-converter-storage)
match profiles), and [mod-source-record-manager](https://github.com/folio-org/mod-source-record-manager)
*removes* incoming 001s and assigns HRIDs on create. The checks themselves
(001 present, no stray `999 ff`, UTF-8 leader) remain sound pre-flight advice;
the rationale text just slightly overstates how fixed the match criteria are.

**The doctrine, restated.** FOLIO keeps: record storage and versioning
(generations, snapshots, optimistic locking), identifier minting (HRID,
UUIDs, `999 ff`), all writes and their orchestration (data import, bulk
operations commit, marc migrations saving), event-driven consistency
(search indexing, authority link maintenance), tenant auth, and every serving
surface (search/browse, OAI-PMH, Z39.50, Connexion). The extension keeps:
file-side preparation and QA before Data Import; read-side analytics over
ATTACHed Postgres/Metadb, saved API JSON, and export files at column-store
speed; batch edit/derive/dedupe/reconcile workflows expressed as SQL; and
dry-run emulation of FOLIO's declarative rule sets (validation specs, mapping
rules, linking rules, export rules) so problems surface before a job runs,
not after.

---

## 3. Replicable shortlist — what to build next

Ordered by value-for-effort. Each item names the FOLIO artifact that defines
the behavior. FOLIO is Apache-2.0 throughout; see §4 on licensing.

### 3.1 Mapping-rules engine: `marc_folio_map(rules_json, leader, fields)` — L

The single most valuable port. Interpret the tenant's actual mapping rules —
the default
[marc_bib_rules.json](https://github.com/folio-org/mod-source-record-manager/blob/master/mod-source-record-manager-server/src/main/resources/rules/marc_bib_rules.json)
or the customized rules from `GET /mapping-rules`
([mod-source-record-manager](https://github.com/folio-org/mod-source-record-manager))
— instead of the current hand-written `marc_instance` approximation. The rule
grammar is tractable for a bind-time-parsed scalar in the
`marc_validate_avram` mold: top-level keys are tags; entries carry `target`
(dot-path into the instance JSON), `subfield` lists, `rules` with `conditions`
of a known function vocabulary (`char_select`, `trim_punctuation`,
`concat_subfields_by_name`, `remove_ending_punc`, constant `value`, …).
Reference-data functions (`set_instance_type_id_by_name` etc.) resolve
against the ATTACHed tenant's reference tables when available and fall back
to emitting the name plus a `needs_reference_data` marker when not. Payoff:
per-tenant mapping dry runs, and the mapping-drift audit of §2 (compare
engine output against `mod_inventory_storage.instance.jsonb` column by
column). This also generalizes `marc_instance` rather than replacing it.

### 3.2 Data-export emulation from Inventory: port `rulesDefault.json` — M

The inverse direction: generate MARC for instances (and appended
holdings/items) straight from ATTACHed inventory tables, following
[rulesDefault.json](https://github.com/folio-org/mod-data-export/blob/master/src/main/resources/rules/rulesDefault.json)
and
[holdingsRulesDefault.json](https://github.com/folio-org/mod-data-export/blob/master/src/main/resources/rules/holdingsRulesDefault.json)
([mod-data-export](https://github.com/folio-org/mod-data-export)):
`$.instance.hrid`→001, `set_transaction_datetime`→005,
`set_fixed_length_data_elements`→008, per-type identifier rules, holdings and
item fields in 9XX. The record-construction machinery already exists
(`marc_from_delimited` builds records from arbitrary row data). Payoff:
full-tenant MARC export without job/S3 orchestration or its 200+ MiB per
million records memory profile, covering the FOLIO-source instances that have
no SRS record to copy — a pure read that never competes with the module's
role as the *operational* export path. Honor tenant `RULES_OVERRIDE` rules by
accepting the rules JSON as a parameter.

### 3.3 Linking-rules rulepack: `marc_linkable(fields)` / `marc_link_check` — S

Embed the instance-authority linking rule table
([instance-authority.json](https://github.com/folio-org/mod-entities-links/blob/master/src/test/resources/linking-rules/instance-authority.json),
semantics in
[mod-entities-links/doc/documentation.md](https://github.com/folio-org/mod-entities-links/blob/master/doc/documentation.md)):
bibField↔authorityField pairs, allowed `authoritySubfields`,
`subfieldModifications` (e.g. 240: authority `$t`→bib `$a`), existence
validation, `autoLinkingEnabled`. Two deliverables: (1) a validation macro
flagging `$9`s on non-linkable fields, linked fields whose subfields fall
outside the rule's allowed set, and `$0`/`$9` presence mismatches; (2) an
auto-link candidate report joining `marc_naco`-normalized bib headings to
authority 1XX/4XX (per rule pair) over files or the ATTACHed authority store
— the batch analog of `POST /records-editor/links/suggestion`. Small because
the rule table is ~20 rows and the heading machinery
(`marc_headings_naco`, `marc_authority_refs`, `marc_heading_flips`) exists.

### 3.4 Record-specifications converter: `marc_folio_spec_to_avram(spec)` — S

Convert a tenant's specification document
([mod-record-specifications](https://github.com/folio-org/mod-record-specifications),
rule behavior in
[record-validation.md](https://github.com/folio-org/mod-record-specifications/blob/master/docs/features/record-validation.md))
into the Avram subset `marc_validate_avram` consumes, carrying required/
repeatable flags, indicator and subfield codes, and local fields. Then one
GET of the tenant spec makes file validation match what quickMARC will
enforce at save time — including institution-defined local fields the shipped
LC-derived rulepacks cannot know. Consider a second column for FOLIO's
ERROR/WARNING severity split so pre-flight reports can say "blocks save" vs
"warns".

### 3.5 Match-profile preview: `marc_folio_match_preview(...)` — M

Given incoming records and the match criteria a
[mod-di-converter-storage](https://github.com/folio-org/mod-di-converter-storage)
match profile expresses (001/003, 035 normalized, `999 ff $s`/`$i`,
identifier types), report per record: would it MATCH (and which SRS
record/instance), MULTI-MATCH, or NO-MATCH — before the job is submitted.
Normalizers (`marc_oclc`, `marc_isbn13`, `marc_lccn`) and the SRS join
pattern exist; the work is encoding the profile criteria shapes. Payoff:
today the only way to learn a match profile's real behavior on a vendor file
is to run the import.

### 3.6 Derive macro: `marc_derive(leader, fields)` — S

One-call new-record derivation matching quickMARC's derive semantics
([ui-quick-marc](https://github.com/folio-org/ui-quick-marc)): drop
`999 ff`, 001/003, system 035s; set Leader/05 to `n`. Trivial composition of
existing macros; worth shipping because it encodes FOLIO's convention rather
than making each user rediscover it. (Optional companion: accept the
[mod-bulk-operations](https://github.com/folio-org/mod-bulk-operations)
`{tag, ind1, ind2, subfield, actions[]}` rule JSON as a driver for the
editing macros, giving bulk-edit parity from the same rule documents.)

---

## 4. Licensing

FOLIO is Apache-2.0; this extension is MIT and 100% dependency-free C++/SQL.
Consequences for the shortlist:

* **Port semantics, never vendor code.** Everything above is re-expressed as
  SQL macros or bind-time C++ over rule *data* — no Java from any
  `folio-org` repo may be translated wholesale or embedded. This matches the
  project's existing clean-room posture (NOTICE, audit/PROVENANCE.md,
  docs/audit/SIMILARITY.md).
* **Rule/data artifacts may be embedded verbatim — with attribution.** If
  `marc_bib_rules.json`, `rulesDefault.json`/`holdingsRulesDefault.json`, the
  instance-authority linking rules, or specification documents are shipped
  inside the extension (rather than always supplied by the user at query
  time), each needs an entry in NOTICE naming the source repo, its Apache-2.0
  license, and any modifications, per Apache-2.0 §4. The lower-friction
  default is to *accept these files as parameters* (fetched by the user from
  their own tenant, which also keeps tenant customizations in play) and embed
  only the small, stable linking-rules table.
* Behavioral facts learned from reading FOLIO source (e.g. which subfields a
  linking rule allows, what `char_select` does) are not copyrightable
  expression; documenting their origin, as this file does, is good practice
  regardless.

---

## 5. Closing summary

Of the **27** FOLIO cataloging capabilities surveyed:

* **8 REPLICATED** — batch MARC editing operations (2), specification-driven
  validation via Avram rulepacks (3), authority-record editing/validation
  (7), SRS read access incl. parsedRecord/envelope parsing (9),
  per-subfield field indexing à la `marc_indexers` (10), "modify MARC"
  action semantics (15), source-record export to `.mrc` (20), bulk-edit MARC
  rule semantics with preview (27).
* **7 REPLICABLE** — tenant validation-spec conversion (4, S), derive-new-
  record (5, S), the mapping-rules engine (11, L), match-profile preview
  (14, M), linking-rules rulepack + auto-link candidates (17, S / 18, M),
  inventory-to-MARC export emulation (21, M).
* **12 TANDEM** — quickMARC's interactive UI (1), optimistic locking (6),
  the SRS store with generations/snapshots (8), HRID/`999 ff` identifier
  minting (12), data-import orchestration (13), inventory entity storage and
  reference data (16), live authority-link maintenance (19), bulk remapping
  write-back (22), discovery search/browse (23), OAI-PMH serving (24),
  Z39.50/SRU serving (25), Connexion intake (26).

The pattern is consistent: what FOLIO expresses as **declarative rule data**
(validation specs, mapping rules, linking rules, export rules, bulk-edit
rules) the extension can replicate cheaply and faithfully — often gaining
whole-corpus speed FOLIO's per-record pipelines cannot offer. What FOLIO
implements as **stateful services** (storage, versioning, identifier minting,
Kafka-driven consistency, serving endpoints) the extension should never
replicate; it reads their state in place, prepares their inputs, and audits
their outputs.
