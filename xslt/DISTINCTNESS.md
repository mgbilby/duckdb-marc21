# Distinctness verification

The XSLT library's originality is verified quantitatively (token-shingle
similarity against the MarcEdit and Library of Congress stylesheet corpora,
with calibrated derivation baselines). The tooling
(`audit/tools/xslt_distinctness.py`) and full report
(`audit/XSLT-DISTINCTNESS.md`) live in this repository. Headline result:
worst-pair rare-shingle Jaccard 0.014 vs 0.795 for a known derived
stylesheet.

## Per-file provenance

The stylesheets below were each written from scratch against the target
format's own published specification. No
MarcEdit stylesheet (or any other non-public-domain XSLT) was fetched,
read, or paraphrased while writing them; the only shared code is this
project's own `marc-utils.xsl`.

**oai_dc-to-marcxml.xsl** — written from the DCMES 1.1 element
definitions (dublincore.org), the DCMI Type Vocabulary, and the Library
of Congress "Dublin Core to MARC" mapping plus the MARC 21 bibliographic
format documentation (leader/008 construction, identifier fields). The
identifier-discrimination cascade (URI scheme test, ISBN shape with
ISO 2108 ISBN-13 recomputation, ISSN `NNNN-NNNC` shape, 024 fallback)
is original logic for this project.

**marcxml-to-dcterms.xsl** — written from the DCMI Metadata Terms
specification (the `dcterms` namespace's refinement semantics:
alternative, issued, extent, medium, spatial, temporal, abstract,
tableOfContents, isPartOf, bibliographicCitation, accessRights,
provenance, audience) and the MARC 21 format documentation for sources.
The no-namespace `qdcRecords`/`qdcRecord` container is this project's
own convention (DCMI defines no record container), mirroring the
`dcRecords` convention already used by `marcxml-to-oai_dc.xsl`.

**marcxml-to-ead.xsl** — written from the EAD3 schema and tag library
published by the Library of Congress and the Society of American
Archivists (control/recordid/filedesc/maintenance elements, archdesc/
did, controlaccess) and the MARC 21 format documentation. The choice of
a collection-level skeleton with `maintenancestatus value="derived"`
and a machine maintenance event is original to this project.

**marcxml-to-schemaorg.xsl** — written from the schema.org vocabulary
documentation and RFC 8259 (string escaping). It deliberately mirrors
this project's own `marc_jsonld` SQL macro (`src/macros/formats.sql`) —
same key set, same leader-to-`@type` table, same field sources — so the
SQL and XSLT export paths agree; that macro is itself original work in
this repository.

**marcxml-to-ris.xsl** — written from the widely mirrored RIS tag-list
documentation (tagged `XX  - value` lines, TY/ER framing) and the
MARC 21 format documentation. The leader-to-TY table and line-emission
helper are original.

**marc21-to-unimarc-skeleton.xsl** — written from the IFLA UNIMARC
Bibliographic format documentation (record label, 100 general
processing data layout, 101/200/210/215/606/700-701 field and subfield
definitions) and the MARC 21 format documentation. Its header states
the exact field subset covered and that full UNIMARC semantics are out
of scope.

The shared helpers added to `marc-utils.xsl` for these sheets
(`mu-replace-all`, `mu-json-escape`, `mu-isbn13`, `mu-first-year`) are
original implementations of, respectively, textbook XSLT 1.0 string
recursion, RFC 8259 escaping, the ISO 2108 ISBN-13 conversion rule, and
a four-digit-run scan.
