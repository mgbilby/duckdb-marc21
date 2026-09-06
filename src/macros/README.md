Additional SQL macro files, embedded after src/macros.sql in sorted filename
order at configure time. One file per feature area; files must be
self-contained (CREATE OR REPLACE MACRO only, may reference macros defined
earlier in sort order or in macros.sql). Never edit another area's file.
