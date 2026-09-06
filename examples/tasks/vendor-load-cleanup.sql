-- task:        vendor-load-cleanup
-- description: Clean a vendor record file for loading: strip vendor 9XX local
--              fields and 856 $9 access tokens, stamp provenance (949 $a org
--              $d load date), and report what would load. See docs/TASKS.md.
-- requires:    marc21
-- params:      task_vendor_clean(fields, org_code)         -> fields
--              task_vendor_load(path, org_code)            -> TABLE(leader, fields)
--              task_vendor_report(path)                    -> TABLE(one row per record)
-- usage:       .read examples/tasks/vendor-load-cleanup.sql
--              SELECT * FROM task_vendor_report('vendor.mrc');
--              COPY (SELECT * FROM task_vendor_load('vendor.mrc', 'XX-MyOrg'))
--              TO 'load.mrc' (FORMAT marc);

-- One record's cleanup: drop all vendor 9XX locals, drop 856 $9 (proxy/vendor
-- tokens), then stamp our own 949 $a org_code $d <load date>.
CREATE OR REPLACE MACRO task_vendor_clean(fields, org_code) AS
    marc_stamp(
        marc_remove_subfield(
            marc_remove_fields(fields, '9..'),
            '856', '9'),
        org_code);

-- The whole file, cleaned, in COPY-ready shape.
CREATE OR REPLACE MACRO task_vendor_load(path, org_code) AS TABLE
    SELECT leader, task_vendor_clean(fields, org_code) AS fields
    FROM read_marc(path);

-- Pre-load QA: per record, the rulepack violations (dispatched on Leader/06),
-- an RDA-era snapshot, and what the cleanup would remove.
CREATE OR REPLACE MACRO task_vendor_report(path) AS TABLE
    SELECT record_no,
           control_number,
           marc_format(leader)                              AS format,
           marc_validate_format(leader, fields)             AS violations,
           len(marc_rda_check(leader, fields))              AS rda_issues,
           len(fields) - len(marc_remove_fields(fields, '9..')) AS vendor_9xx_dropped,
           marc_subfield(fields, '245', 'a')                AS title
    FROM read_marc(path);
