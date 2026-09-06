# Task bundles

The marc21 answer to MarcEdit's Tasks: a **task bundle** is a plain `.sql`
file of `CREATE OR REPLACE MACRO` statements plus a header comment block. It
records a reusable workflow — vendor-file cleanup, an RDA upgrade pass, a
dedupe review — as named macros you load once and apply with ordinary SQL.
Because macros are pure SQL over the extension's functions, a bundle needs no
plugin system, no install step and no runtime of its own: it is a text file
you check into your repository, review in a pull request and share by
copying.

## The convention

A bundle file has two parts.

**1. The header** — comment lines at the top, one `key: value` per line:

```sql
-- task:        vendor-load-cleanup
-- description: What the bundle does, in a sentence or two.
-- requires:    marc21
-- params:      task_vendor_clean(fields, org_code)  -> fields
--              task_vendor_load(path, org_code)     -> TABLE(leader, fields)
-- usage:       .read examples/tasks/vendor-load-cleanup.sql
--              COPY (SELECT * FROM task_vendor_load('vendor.mrc', 'XX-MyOrg'))
--              TO 'load.mrc' (FORMAT marc);
```

Required keys: `task` (the bundle name, matching the filename), `description`,
`requires` (extensions the macros assume are loaded), `params` (every macro
the bundle defines, with its signature and what it returns), `usage` (at
least one copy-pasteable invocation).

**2. The macros** — nothing but `CREATE OR REPLACE MACRO` statements
(scalar or `AS TABLE`), so loading a bundle is idempotent and never touches
data. By convention:

* macro names carry a `task_` prefix plus the bundle's noun
  (`task_vendor_clean`, `task_rda_profile`) so bundles don't collide with
  the extension's `marc_` namespace or each other;
* scalar macros take and return values (`fields`, or a
  `STRUCT(leader, fields)` when the leader changes too) so they compose
  inside other SQL;
* table macros over a file take `path` first and come in two flavors:
  reports (arbitrary columns) and `TABLE(leader, fields)` shapes ready for
  `COPY ... (FORMAT marc)`;
* a bundle only *defines* macros — the user runs the `COPY`, so nothing is
  written without an explicit statement in their session.

## Running a bundle

Interactively, or in a script, load then apply:

```sql
.read examples/tasks/rda-upgrade.sql
SELECT * FROM task_rda_profile('bibs.mrc');
COPY (SELECT * FROM task_rda_upgrade_file('bibs.mrc'))
TO 'bibs_rda.mrc' (FORMAT marc);
```

Non-interactively, `-init` loads the bundle before the commands run:

```sh
duckdb -init examples/tasks/rda-upgrade.sql \
  -c "COPY (SELECT * FROM task_rda_upgrade_file('bibs.mrc')) TO 'bibs_rda.mrc' (FORMAT marc);"
```

(Have `INSTALL marc21 FROM community; LOAD marc21;` in `~/.duckdbrc`, or put
those two lines at the top of a site-local copy of the bundle.) Several
bundles can be `.read` into one session; the `task_` prefix keeps them
apart.

## The example bundles

Three tested bundles ship in `examples/tasks/`, each built entirely from
existing marc21 functions and exercised end to end against `test/data`
fixtures:

| bundle | macros | job |
|---|---|---|
| `dedupe-report.sql` | `task_dedupe_exact`, `task_dedupe_fuzzy`, `task_dedupe_keepers` | exact match-key groups, fuzzy title-similarity pairs, per-group keeper by `marc_rank` |
| `rda-upgrade.sql` | `task_rda_profile`, `task_rda_worklist`, `task_rda_upgrade`, `task_rda_upgrade_file` | the RDA Helper flow: profile, worklist, mechanical upgrade (33X, abbreviations, GMD, 040 `$e`, Leader/18) |
| `vendor-load-cleanup.sql` | `task_vendor_clean`, `task_vendor_load`, `task_vendor_report` | strip vendor 9XX and 856 `$9`, stamp provenance, pre-load QA report |

A worked session with the dedupe bundle:

```sql
.read examples/tasks/dedupe-report.sql
SELECT * FROM task_dedupe_exact('bibs.mrc');
-- matchkey | records | control_numbers | record_nos
SELECT * FROM task_dedupe_keepers('bibs.mrc');
-- matchkey | records | keep_control_number | keep_record_no | keeper_rank
```

## Writing your own

Start from the closest example, and keep three habits:

* **compose, don't copy** — reach for `marc_*` functions and other macros;
  if a step needs logic no function provides, that is a feature request for
  the extension, not a reason to inline C++-shaped SQL;
* **report before you write** — pair every `task_*_file` transform with a
  `task_*_report` so the operator can see what a load would do first;
* **test against fixtures** — run each macro over `test/data/sample_utf8.mrc`
  (or your own small file) and check the output before pointing it at a
  million records. Bundles are candidates for `test/sql/` sqllogictests if
  they graduate into the repository.
