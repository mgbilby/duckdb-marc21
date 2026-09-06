-- ---------------------------------------------------------------------------
-- XSLT crosswalk registry: the command line that runs a registered sheet.
--
-- The catalog and the stylesheet text live inside the extension binary
-- (xslt/registry.tsv, embedded at configure time; marc_xslt_functions(),
-- marc_xslt_stylesheet(), marc_xslt_library() in src/marc_xslt.cpp).  This
-- extension does not execute XSLT — that is xsltproc, Saxon, or the
-- browser's XSLTProcessor, per docs/ECOSYSTEM.md — so the SQL side stops at
-- naming the transform and printing the command that performs it.
--
-- The workflow the command assumes: export the sheet and the helper library
-- once, then run it.
--
--   COPY (SELECT rtrim(marc_xslt_stylesheet('MARC=>MODS'), chr(10)))
--     TO 'work/marcxml-to-mods.xsl' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
--   COPY (SELECT rtrim(marc_xslt_library(), chr(10)))
--     TO 'work/lib/marc-utils.xsl'  (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
--   SELECT marc_xslt_command('MARC=>MODS', 'records.xml', 'records.mods.xml');
--
-- Every sheet includes the library as lib/marc-utils.xsl, so the command
-- names the sheet by its bare filename and expects to run in the directory
-- that holds it and the lib/ subdirectory beside it.
--
-- WHY THERE IS NO USER-REGISTRY MACRO HERE.  Scalar macros bind at extension
-- load: their bodies may use only core DuckDB and this extension's own
-- functions, and every table they name must already exist.  A macro that
-- UNIONed the shipped catalog with a local marc_xslt_user table would
-- therefore fail to bind for everyone who has not created that table.  The
-- CREATE TABLE marc_xslt_user(...) + CREATE VIEW recipe that unions the two
-- lives in docs/XSLT.md instead, where it can be run per database.
-- ---------------------------------------------------------------------------

-- One command-line argument, single-quoted for a POSIX shell (an embedded
-- single quote is closed, escaped and reopened).
CREATE OR REPLACE MACRO marc_xslt_shell_arg(s) AS
    '''' || replace(s::VARCHAR, '''', '''\''''') || '''';

-- The filename a registered sheet is exported as: the basename of its
-- registry path.  NULL when the alias (or path) is not in the catalog.
CREATE OR REPLACE MACRO marc_xslt_sheet_file(alias_or_path) AS (
    SELECT regexp_extract(x.path, '[^/]+$')
    FROM marc_xslt_functions() AS x
    WHERE upper(x.alias) = upper(alias_or_path) OR x.path = alias_or_path
    LIMIT 1
);

-- The xsltproc invocation for one registered crosswalk.  NULL for an unknown
-- alias, so a missing crosswalk is visible rather than silently unrunnable.
-- The first parameter is deliberately not called "alias": a macro parameter
-- that shares its name with a column of the catalog the body queries makes
-- the two ambiguous and the macro fails to bind.
CREATE OR REPLACE MACRO marc_xslt_command(crosswalk, input_path, output_path) AS
    'xsltproc --output ' || marc_xslt_shell_arg(output_path) || ' ' ||
    marc_xslt_shell_arg(marc_xslt_sheet_file(crosswalk)) || ' ' ||
    marc_xslt_shell_arg(input_path);
