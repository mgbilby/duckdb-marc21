-- Total INSTALL-event downloads for duckdb-marc21, summed over all published weekly
-- stat files. duckdb-marc21 first appeared in ISO week 38 of 2026 (week of 2026-09-14).
-- The + INTERVAL 1 DAY ensures the in-progress current week's file is included.
SELECT
    sum(marc21)::BIGINT AS total_downloads
FROM read_json([
    printf(
        'https://community-extensions.duckdb.org/download-stats-weekly/%s/%s.json',
        week.strftime('%Y'),
        week.strftime('%V').regexp_replace('^0', '')
    )
    FOR week
    IN range(
        TIMESTAMP '2026-09-14',
        now()::TIMESTAMP + INTERVAL 1 DAY,
        INTERVAL 1 WEEK
    )
    IF strftime(week, '%V') != '53'
], union_by_name := true, columns = { 'marc21': 'BIGINT' });