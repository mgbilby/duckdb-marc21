# Contributing to duckdb-marc21

Thanks for helping. This page covers the build, the two test loops, the
macro-file convention, the clean-room policy and the release cadence. Keep
pull requests small and tested; every behavior change needs a test.

## Prerequisites and first build

The extension uses DuckDB's shared extension build system, vendored as git
submodules (`duckdb/`, `extension-ci-tools/`):

```sh
git clone --recurse-submodules https://github.com/mgbilby/duckdb-marc21
# or, in an existing clone / worktree:
git submodule update --init --recursive
```

You need a C++17 compiler, CMake ≥ 3.15, GNU make and (recommended) ninja:

```sh
GEN=ninja make release        # optimized build
GEN=ninja make debug          # assertions + symbols
```

`make release` produces `build/release/duckdb` (a shell with the extension
statically linked), `build/release/test/unittest` (the sqllogictest runner)
and `build/release/extension/marc21/marc21.duckdb_extension` (the loadable
build). The first build compiles all of DuckDB and takes a while; later
builds are incremental. `GEN=ninja` needs ninja + ccache installed and is
much faster on rebuilds.

## The fast loop: standalone core tests

Everything under `src/core/` is dependency-free C++17 that never touches
DuckDB headers, and `test/cpp/` holds standalone harnesses for it. That
gives a compile-and-run loop measured in seconds, no CMake involved:

```sh
make core_test                # the Makefile target: core, z3950, z3950_socket
# or any single harness by hand:
g++ -std=c++17 -Wall -O2 -pthread -Isrc/include \
    src/core/*.cpp test/cpp/core_test.cpp -o build/core_test && ./build/core_test
# -> core_test: all checks passed
```

Swap in any `test/cpp/*_test.cpp` (`edit_test`, `formats_test`,
`idnorm_test`, `callnum_test`, ...); `fuzz_check.cpp` is the differential
fuzzing harness. Work on parsing, encodings, editing or normalization should
iterate here first and only fall back to the full build to wire results into
SQL functions.

## The SQL loop: sqllogictests

Integration tests are DuckDB sqllogictests in `test/sql/*.test`, run with
the standard runner:

```sh
make test                                             # everything
build/release/test/unittest "test/sql/marc_edge.test" # one file
```

Conventions (see any existing file):

* header comment block: `# name:`, `# description:`, `# group: [marc]`;
* `require marc21` before the first statement;
* fixture inputs live in `test/data/` (edge cases under `test/data/edge/`)
  and are referenced by relative path — the runner executes from the repo
  root; write outputs to `__TEST_DIR__`;
* assert error behavior with `statement error` plus a stable substring of
  the message, not the whole text;
* keep expected values byte-exact (the MARC-8/Unicode tests exist to catch
  one-codepoint drift — that is a feature).

New fixtures should be small (a handful of records), constructed with the
extension's own writers where possible, and committed as binary `.mrc` /
text files — never as generator scripts.

## Macro files

SQL-defined functions live in `src/macros.sql` plus one file per feature
area in `src/macros/*.sql`. At configure time CMake embeds `macros.sql`
followed by every `src/macros/*.sql` in sorted filename order into the
extension, which registers them at `LOAD`. Rules (also in
`src/macros/README.md`):

* files contain `CREATE OR REPLACE MACRO` statements only;
* a file may reference macros defined earlier in sort order (or in
  `macros.sql`), never later;
* one feature area per file; do not edit another area's file;
* adding or renaming a file means a fresh CMake configure — rerun `make`.

Reusable *workflows* built on top of the public functions belong in
`examples/tasks/` as task bundles (see `docs/TASKS.md`), not in
`src/macros/`.

## Clean-room policy

This extension is implemented from **specifications only**: ISO 2709, the
Library of Congress MARC 21 / MARC-8 / MARCXML / MARC-in-JSON documents, the
Z39.50-1995 standard, MARCspec, Avram, NISO RP-9 (KBART). Contributions
must keep it that way:

* **no code, tables or test data copied from other MARC software** —
  neither GPL/copyleft implementations nor closed-source tools (MarcEdit
  included). Do not port, transcribe or "translate" their source; do not
  paste their lookup tables.
* *describing documented behavior is fine* — `docs/MIGRATING-FROM-MARCEDIT.md`
  maps MarcEdit's documented tools to our SQL, which is comparison, not
  derivation.
* where an independent open-source implementation exists, we verify
  independence and correctness by **differential fuzzing**
  (`test/cpp/fuzz_check.cpp`) rather than by reading its code and matching
  it.
* character-set tables must cite the LC code table they were generated
  from.

If you have studied another implementation's source in depth, say so in the
PR so review can keep derived expression out.

## Release cadence

The extension tracks **DuckDB stable releases** (it is distributed as a
DuckDB Community Extension, which rebuilds per DuckDB version):

* the `duckdb` submodule pins the latest stable DuckDB; expect a bump PR
  shortly after each DuckDB release, paired with an `extension-ci-tools`
  bump to the matching branch;
* extension ABI follows DuckDB — a build made against one stable release
  loads only on that release, so users on the community repository get new
  extension versions with their DuckDB upgrade;
* features merge to `main` continuously; there is no separate LTS branch.
  Anything not yet released is available by building from source as above.

## Housekeeping

* Commit messages: imperative summary line; reference issues where they
  exist.
* New SQL surface (functions, macros, COPY options) must be documented in
  `docs/REFERENCE.md` in the same PR, with a recipe in `docs/RECIPES.md`
  when it enables a workflow.
* Do not commit build outputs (`build/`) or editor state; verification
  and generator scripts belong under `audit/tools/`.

## Scope: compose, don't rebuild

This extension keeps to one niche — the MARC 21 record model and
cataloging semantics in SQL. Generic capabilities (transports, non-MARC
file formats, search indexes, fuzzy-matching algorithms) belong to DuckDB
core or sibling community extensions and should be *composed with*, not
reimplemented here. Read `docs/ECOSYSTEM.md` before proposing a feature;
PRs that rebuild something `httpfs`, `json`, `webbed`, `zipfs`,
`sheetreader`, `http_client`, `fts`, `rapidfuzz` or the like already
provide will be redirected to a recipe or thin composing macro instead.
