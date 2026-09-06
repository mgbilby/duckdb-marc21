# Distinctness of the xslt/ crosswalk library

The stylesheets in the repository's `xslt/` directory were written for
this project from the published **mapping specifications** — the Library
of Congress
*MARC to MODS*, *MODS to MARC*, and *MARC to Dublin Core* mapping
documents — not from anyone's stylesheet code. Because widely used XSLT
implementations of the same mappings exist (Library of Congress
`MARC21slim2MODS3-7.xsl` and friends; MarcEdit's published XSLT library),
this file records a fuzzy-match check demonstrating that this library is
not derived from them.

## Methodology

`audit/tools/xslt_distinctness.py` compares every stylesheet in `xslt/`
against every stylesheet in a set of reference corpora:

1. XML comments are stripped, whitespace collapsed, text lowercased and
   tokenized into name/attribute words and punctuation;
2. overlapping **5-token shingles** are formed per file;
3. each pair is scored with Jaccard similarity `|A∩B| / |A∪B|` and
   containment `|A∩B| / min(|A|,|B|)`.

Raw shingle overlap between *any* two MARC stylesheets is dominated by
forced content: XSLT syntax runs (`</xsl:template> <xsl:template
match=`), MARC selection idiom (`marc:datafield[@tag=...]`), and — for
two crosswalks with the same target — the output vocabulary itself
(`</dc:title> <dc:creator>`). Measured empirically, **unrelated**
third-party stylesheets score up to ≈0.16 raw Jaccard from this alone, so
the tool computes a second, discriminating score: **rare-shingle
Jaccard**, which excludes every shingle occurring in ≥3 distinct
reference files (if three independent stylesheets contain it, it is
shared idiom, not evidence of copying). A real derivation cannot avoid
sharing its donor's *distinctive* template bodies, so it scores high on
both measures.

Thresholds: fail at rare-Jaccard ≥ 0.05 or raw-Jaccard ≥ 0.30.

### Reference corpora (cloned at check time, not committed)

| corpus | source |
|---|---|
| MarcEdit shared XSLTs | `github.com/reeset/marcedit_xslt_files` |
| MarcEdit translation XSLTs | `github.com/reeset/marcedit-xslts` |
| Library of Congress standards (authoritative: `marcxml/xslt`, `mods/v3`) | `github.com/lcnetdev/lcstandards` |
| FLVC Islandora XSLTs (LC-derived MODS/HTML/reverse) | `github.com/cnelsonFLVC/FLVC_Islandora_XSLTs` |
| NAL MARC21slim2MODS 3.7 (LC-derived) | `github.com/CarlosMartinez-USDA/NAL-MARC21slim2MODS3-7` |

235 reference stylesheets in total; 73,333 distinct shingles, of which
39,550 were classified generic (document frequency ≥ 3).

### Positive control

The method detects real derivation loudly. MarcEdit's
`MARC21slim2RDFDC.xsl` — which *is* an adaptation of the LC stylesheet —
scored against the LC corpus:

| pair | rare J | raw J |
|---|---|---|
| MarcEdit RDFDC ~ LC `MARC21slim2RDFDC.xsl` | **0.795** | **0.909** |
| MarcEdit RDFDC ~ LC `MARC21slim2OAIDC.xsl` | 0.400 | 0.787 |

## Results

Worst match per stylesheet across all 235 reference files (selected by
rare-shingle Jaccard, the discriminating score):

| ours | rare J | raw J | worst-matching reference file |
|---|---|---|---|
| `marc-utils.xsl` | 0.008 | 0.079 | FLVC `FLVC_MODS_postprocessing.xsl` |
| `marcxml-to-html.xsl` | 0.007 | 0.063 | NAL `add-record-numbers.xsl` |
| `marcxml-to-mods.xsl` | 0.003 | 0.021 | NAL `add-record-numbers.xsl` |
| `marcxml-to-oai_dc.xsl` | 0.014 | 0.205 | LC `MARC21slim2OAIDC.xsl` |
| `marcxml-to-rdfdc.xsl` | 0.008 | 0.112 | MarcEdit `MARC21slim2RDFDC.xsl` |
| `mods-to-marcxml.xsl` | 0.012 | 0.109 | MarcEdit `ArchivealWare2MARC21slim.xsl` |

Focused matrix against the direct same-purpose comparators
(rare J / raw J):

| ours | LC MODS 3.7 | LC OAIDC | LC RDFDC | LC HTML | LC MODS→MARC | LC Utils | MarcEdit RDFDC | MarcEdit Utils |
|---|---|---|---|---|---|---|---|---|
| `marc-utils.xsl` | .000/.018 | .000/.063 | .000/.062 | .000/.056 | .000/.036 | .002/.127 | .000/.062 | .002/.115 |
| `marcxml-to-html.xsl` | .000/.017 | .000/.078 | .000/.079 | .002/.157 | .000/.041 | .000/.092 | .000/.075 | .000/.076 |
| `marcxml-to-mods.xsl` | .000/.110 | .000/.071 | .000/.067 | .000/.024 | .000/.038 | .000/.037 | .000/.070 | .000/.039 |
| `marcxml-to-oai_dc.xsl` | .000/.030 | .014/.205 | .000/.179 | .000/.045 | .000/.042 | .000/.070 | .000/.175 | .000/.062 |
| `marcxml-to-rdfdc.xsl` | .000/.033 | .000/.096 | .003/.105 | .000/.048 | .000/.041 | .000/.062 | .008/.112 | .000/.060 |
| `mods-to-marcxml.xsl` | .000/.019 | .000/.037 | .000/.036 | .000/.027 | .000/.138 | .000/.049 | .000/.035 | .000/.050 |

Every rare-shingle score is ≤ 0.014 — two orders of magnitude below the
positive control (0.795) and comfortably under the 0.05 gate. The
highest raw score (0.205, ours-DC vs LC-OAIDC) sits inside the measured
noise band for independent stylesheets sharing an output vocabulary, and
its rare-shingle residue (0.014) shows the overlap is entirely idiom and
`dc:` element names, not template structure.

## Reproducing

```sh
scratch=$(mktemp -d)
git clone --depth 1 https://github.com/reeset/marcedit_xslt_files "$scratch/marcedit_xslt_files"
git clone --depth 1 https://github.com/reeset/marcedit-xslts     "$scratch/marcedit-xslts"
git clone --depth 1 --filter=blob:none --sparse \
    https://github.com/lcnetdev/lcstandards "$scratch/lcstandards"
git -C "$scratch/lcstandards" sparse-checkout set marcxml/xslt mods/v3
git clone --depth 1 https://github.com/cnelsonFLVC/FLVC_Islandora_XSLTs "$scratch/flvc"
git clone --depth 1 https://github.com/CarlosMartinez-USDA/NAL-MARC21slim2MODS3-7 "$scratch/nal"

python3 audit/tools/xslt_distinctness.py xslt \
    "$scratch/marcedit_xslt_files" "$scratch/marcedit-xslts" \
    "$scratch/lcstandards" "$scratch/flvc" "$scratch/nal"
```

Add `--matrix` for the full pairwise table. The reference clones are
deliberately not committed to this repository.
