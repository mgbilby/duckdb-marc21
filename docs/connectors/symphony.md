# SirsiDynix Symphony

| | |
|---|---|
| Canonical MARC store | Symphony catalog; interchange is file/pipe oriented |
| Fetch | `catalogdump` → `flatskip` → `read_marc`; live lookups via `read_z3950` |
| Auth | server shell for the dump loop; Z39.50 usually anonymous inside the network |
| Write-back | **catalogload** |

Symphony has no MARC-returning REST endpoint for this extension to compose
URLs against — its interchange runs through the API-server toolchain of
filters, which pipe together on the Symphony host. The connector pattern is
therefore a file loop plus Z39.50 for record-at-a-time retrieval.

## The catalogdump / flatskip file loop

On the Symphony server, `catalogdump` emits the catalog (or a selection) as
Symphony *flat* ASCII, and `flatskip` converts flat records to standard
MARC:

```
# all bib records, selection tools (selcatalog etc.) compose upstream
catalogdump -om | flatskip -aMARC -im -om > full_dump.mrc
```

Ship `full_dump.mrc` over and everything in the extension applies:

```sql
LOAD marc21;

-- Warm-up: what does the dump contain?
SELECT * FROM marc_report_tags('full_dump.mrc');

-- Symphony call numbers / items ride in 999 (default entries: $a call
-- number, $w class scheme, $i barcode, $l home location, $t item type)
SELECT control_number,
       marc_subfield(fields, '245', 'a')  AS title,
       marc_subfield(fields, '999', 'a')  AS call_number,
       marc_subfields(fields, '999', 'i') AS barcodes
FROM read_marc('full_dump.mrc');
```

Note the flat format itself (`*** DOCUMENT BOUNDARY ***` / `.245. |a...`)
is not MarcEdit breaker text — `read_marc_breaker` will not read it. Always
convert with `flatskip` on the way out.

## Live lookups: Z39.50

Symphony ships a Z39.50 server; inside the network it is the practical
record-at-a-time connector, with no file round trip:

```sql
-- (host, port, database, PQF query) — Symphony's bib database is
-- conventionally named 'unicorn'; port and names are site-configured
SELECT control_number, marc_subfield(fields, '245', 'a') AS title
FROM read_z3950('symphony.mylib.example', 2200, 'unicorn',
                '@attr 1=12 1000234', max_records := 5);
```

`@attr 1=12` searches the local record id (title control number); `@attr
1=7` ISBN, `@attr 1=4` title — standard Bib-1 attributes.

## Edit and write back

The return path is **catalogload** on the Symphony server. Produce clean
UTF-8 MARC here, convert/load there:

```sql
-- Batch edit: stamp 040 $d, drop stale local 9XX except items
COPY (
    SELECT leader,
           marc_set_subfield(marc_remove_fields(fields, '59.'), '040', 'd', 'MyORG') AS fields
    FROM read_marc('full_dump.mrc')
    WHERE len(marc_validate(leader, fields)) = 0
) TO 'for_symphony.mrc' (FORMAT marc);
```

```
# server side: convert to flat and load (update-if-matched policies are
# catalogload switches; -m updates, title control number keys the match)
flatskip -im -aMARC -of < for_symphony.mrc | catalogload -im -m -b -om > load_report.log
```

Symphony sites differ in `catalogload` policy switches (record match key,
item handling, authority processing) — mirror whatever the site's existing
load reports use. Keep `001` (title control number, e.g. `a1000234`) intact:
it is the match key that turns the loop into an update instead of a
duplicate.
