-- task:        rda-upgrade
-- description: Batch-upgrade AACR2-era bibliographic records toward RDA
--              (MarcEdit "RDA Helper" equivalent): derive the 336/337/338
--              trio from the leader, spell out AACR2 abbreviations, drop the
--              245 $h GMD, add 040 $e rda, flip Leader/18 to 'i'. Records
--              with no marc_rda_check issues pass through untouched.
--              Judgment calls (260->264, [S.l.]/[s.n.], relators) are
--              reported, not edited — see docs/RECIPES.md section 7.
-- requires:    marc21
-- params:      task_rda_profile(path)          -> TABLE(issue, records)
--              task_rda_worklist(path)         -> TABLE(worst records first)
--              task_rda_upgrade(leader, fields)-> STRUCT(leader, fields)
--              task_rda_upgrade_file(path)     -> TABLE(leader, fields)
-- usage:       .read examples/tasks/rda-upgrade.sql
--              SELECT * FROM task_rda_profile('bibs.mrc');
--              COPY (SELECT * FROM task_rda_upgrade_file('bibs.mrc'))
--              TO 'bibs_rda.mrc' (FORMAT marc);

-- Issue histogram over a file: which AACR2-era problems, how often.
CREATE OR REPLACE MACRO task_rda_profile(path) AS TABLE
    SELECT issue, count(*) AS records
    FROM (SELECT unnest(marc_rda_check(leader, fields)) AS issue
          FROM read_marc(path))
    GROUP BY issue
    ORDER BY records DESC, issue;

-- The records with the most to fix, worst first.
CREATE OR REPLACE MACRO task_rda_worklist(path) AS TABLE
    SELECT record_no, control_number,
           marc_subfield(fields, '245', 'a') AS title,
           marc_rda_check(leader, fields)    AS issues
    FROM read_marc(path)
    WHERE len(marc_rda_check(leader, fields)) > 0
    ORDER BY len(marc_rda_check(leader, fields)) DESC, record_no;

-- One record's mechanical upgrade. marc_set_subfield appends $e rda only to
-- an existing 040; records without an 040 keep flagging no_040e_rda for
-- cataloger attention rather than getting a fabricated one.
CREATE OR REPLACE MACRO task_rda_upgrade(leader, fields) AS
    {'leader': substr(leader, 1, 18) || 'i' || substr(leader, 20),
     'fields': marc_set_subfield(
                   marc_rda_expand(
                       marc_generate_33x(leader,
                           marc_remove_subfield(fields, '245', 'h'))),
                   '040', 'e', 'rda')};

-- The whole file in COPY-ready shape; clean records pass through unchanged.
CREATE OR REPLACE MACRO task_rda_upgrade_file(path) AS TABLE
    SELECT CASE WHEN len(marc_rda_check(leader, fields)) > 0
                THEN task_rda_upgrade(leader, fields)
                ELSE {'leader': leader, 'fields': fields} END.leader AS leader,
           CASE WHEN len(marc_rda_check(leader, fields)) > 0
                THEN task_rda_upgrade(leader, fields)
                ELSE {'leader': leader, 'fields': fields} END.fields AS fields
    FROM read_marc(path);
