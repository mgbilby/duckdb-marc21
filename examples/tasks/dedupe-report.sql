-- task:        dedupe-report
-- description: Duplicate-record review (MarcEdit "Find Duplicate Records"
--              equivalent): exact match-key groups, fuzzy title-similarity
--              candidates, and a keeper suggestion per exact group using
--              marc_rank (encoding level + completeness).
-- requires:    marc21
-- params:      task_dedupe_exact(path)             -> TABLE(one row per dup group)
--              task_dedupe_fuzzy(path, threshold)  -> TABLE(scored pairs)
--              task_dedupe_keepers(path)           -> TABLE(group + keeper)
-- usage:       .read examples/tasks/dedupe-report.sql
--              SELECT * FROM task_dedupe_exact('bibs.mrc');
--              SELECT * FROM task_dedupe_fuzzy('bibs.mrc', 0.93);

-- Exact first pass: records sharing a marc_dedupe_key
-- (normalized title | ISBN | year).
CREATE OR REPLACE MACRO task_dedupe_exact(path) AS TABLE
    SELECT marc_dedupe_key(fields) AS matchkey,
           count(*)                AS records,
           list(control_number)    AS control_numbers,
           list(record_no)         AS record_nos
    FROM read_marc(path)
    WHERE marc_dedupe_key(fields) IS NOT NULL
    GROUP BY matchkey
    HAVING count(*) > 1
    ORDER BY records DESC, matchkey;

-- Fuzzy second pass: every record pair scored by Jaro-Winkler similarity of
-- NACO-normalized titles; exact-key pairs always included. Quadratic — fine
-- for review sets, block first for big files (docs/RECIPES.md section 6).
CREATE OR REPLACE MACRO task_dedupe_fuzzy(path, threshold) AS TABLE
    SELECT * FROM marc_dedupe_candidates(path, threshold)
    ORDER BY same_matchkey DESC, similarity DESC;

-- For each exact duplicate group, suggest the record to keep: highest
-- marc_rank total (encoding-level rank + field/subfield completeness).
CREATE OR REPLACE MACRO task_dedupe_keepers(path) AS TABLE
    SELECT marc_dedupe_key(fields)                                   AS matchkey,
           count(*)                                                  AS records,
           arg_max(control_number, marc_rank(leader, fields).total)  AS keep_control_number,
           arg_max(record_no, marc_rank(leader, fields).total)       AS keep_record_no,
           max(marc_rank(leader, fields).total)                      AS keeper_rank
    FROM read_marc(path)
    WHERE marc_dedupe_key(fields) IS NOT NULL
    GROUP BY matchkey
    HAVING count(*) > 1
    ORDER BY records DESC, matchkey;
