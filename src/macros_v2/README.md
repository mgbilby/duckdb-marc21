SQL macro files that require DuckDB v2.0 syntax and are therefore embedded
and registered only when marc21 is built against v2.0 or newer. Same rules as
src/macros/: one file per feature area, CREATE OR REPLACE MACRO only, files
self-contained apart from macros defined in src/macros.sql and src/macros/.

A body here may use v2.0-only grammar (the NEAREST BY join clause), which the
v1.5.x parser rejects outright — the whole macro layer is parsed in one go at
LOAD, so a single v2.0-only statement reaching a v1.5.x build would make the
extension unloadable. That is why these files are a separate directory rather
than more entries in src/macros/.
