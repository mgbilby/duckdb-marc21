#!/bin/sh
# Functional tests for the xslt/ crosswalk library.
# Requires xsltproc and xmllint. Exits nonzero on the first missing tool
# and counts assertion failures otherwise.

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
XSL="$ROOT/xslt"
DATA="$ROOT/test/data"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

command -v xsltproc >/dev/null 2>&1 || { echo "xsltproc not found" >&2; exit 2; }
command -v xmllint  >/dev/null 2>&1 || { echo "xmllint not found"  >&2; exit 2; }

fails=0
checks=0

ok() { checks=$((checks + 1)); echo "  ok  - $1"; }
bad() { checks=$((checks + 1)); fails=$((fails + 1)); echo "  FAIL - $1"; }

# assert_grep <file> <pattern> <label>
assert_grep() {
    if grep -q "$2" "$1"; then ok "$3"; else bad "$3 (pattern not found: $2)"; fi
}

# assert_absent <file> <pattern> <label>
assert_absent() {
    if grep -q "$2" "$1"; then bad "$3 (unwanted pattern present: $2)"; else ok "$3"; fi
}

# assert_fgrep <file> <fixed-string> <label> ; literal match, for patterns
# full of backslashes and quotes (JSON / RIS escaping checks)
assert_fgrep() {
    if grep -qF "$2" "$1"; then ok "$3"; else bad "$3 (literal not found: $2)"; fi
}

# transform <stylesheet> <input> <output> <label>; asserts success + well-formed XML
transform() {
    if xsltproc "$XSL/$1" "$2" > "$OUT/$3" 2> "$OUT/$3.err"; then
        if xmllint --noout "$OUT/$3" 2>> "$OUT/$3.err"; then
            ok "$4"
            return 0
        fi
    fi
    bad "$4"
    sed 's/^/        /' "$OUT/$3.err"
    return 1
}

echo "== stylesheets are well-formed =="
for f in "$XSL"/marc-utils.xsl "$XSL"/marcxml-to-mods.xsl \
         "$XSL"/marcxml-to-oai_dc.xsl "$XSL"/marcxml-to-rdfdc.xsl \
         "$XSL"/marcxml-to-html.xsl "$XSL"/mods-to-marcxml.xsl \
         "$XSL"/oai_dc-to-marcxml.xsl "$XSL"/marcxml-to-dcterms.xsl \
         "$XSL"/marcxml-to-ead.xsl "$XSL"/marcxml-to-schemaorg.xsl \
         "$XSL"/marcxml-to-ris.xsl "$XSL"/marc21-to-unimarc-skeleton.xsl; do
    if xmllint --noout "$f" 2>/dev/null; then ok "$(basename "$f")"; else bad "$(basename "$f")"; fi
done

echo "== MARCXML -> MODS =="
transform marcxml-to-mods.xsl "$DATA/sample.xml" sample.mods.xml "sample.xml transforms"
assert_grep "$OUT/sample.mods.xml" '<modsCollection' "collection input yields modsCollection"
assert_grep "$OUT/sample.mods.xml" '<title>Łódź and the river</title>' "245 title, punctuation trimmed, diacritics intact"
assert_grep "$OUT/sample.mods.xml" '<subTitle>a study</subTitle>' "245b subtitle"
assert_grep "$OUT/sample.mods.xml" '<nonSort>The</nonSort>' "nonSort from 245 ind2"
assert_grep "$OUT/sample.mods.xml" '<namePart type="date">1970-</namePart>' "100d as date namePart"
assert_grep "$OUT/sample.mods.xml" '<geographic>Łódź</geographic>' "650z geographic subdivision"
assert_grep "$OUT/sample.mods.xml" 'authority="fast"' "subject scheme from ind2=7 \$2"
assert_grep "$OUT/sample.mods.xml" '<title>日本の歴史</title>' "CJK 245"
assert_grep "$OUT/sample.mods.xml" '<title>Nihon no rekishi</title>' "880 linked 245 becomes paired titleInfo"
n_groups=$(grep -c 'altRepGroup="t245"' "$OUT/sample.mods.xml")
if [ "$n_groups" = "2" ]; then ok "altRepGroup pairs 245 with its 880"; else bad "altRepGroup pair count ($n_groups)"; fi

transform marcxml-to-mods.xsl "$DATA/xslt/collection.xml" coll.mods.xml "collection.xml transforms"
assert_grep "$OUT/coll.mods.xml" '<publisher>Mohr Siebeck</publisher>' "260b publisher"
assert_grep "$OUT/coll.mods.xml" '<publisher>AST</publisher>' "264b publisher"
assert_grep "$OUT/coll.mods.xml" 'eventType="publication"' "264 gets eventType"
assert_grep "$OUT/coll.mods.xml" '<copyrightDate>2021</copyrightDate>' "264/4 copyright date"
assert_grep "$OUT/coll.mods.xml" '<title>Рассказы о море</title>' "Cyrillic 880 title"
assert_grep "$OUT/coll.mods.xml" '<edition>2., überarbeitete Auflage</edition>' "250 edition with diacritics"
assert_grep "$OUT/coll.mods.xml" '<issuance>serial</issuance>' "leader/07 s issuance"
assert_grep "$OUT/coll.mods.xml" '<frequency>Weekly</frequency>' "310 frequency"
assert_grep "$OUT/coll.mods.xml" 'type="preceding"' "780 preceding entry"
assert_grep "$OUT/coll.mods.xml" 'type="succeeding"' "785 succeeding entry"
assert_grep "$OUT/coll.mods.xml" 'type="host"' "773 host entry"
assert_grep "$OUT/coll.mods.xml" '<identifier type="issn">1021-0067</identifier>' "773x issn"
assert_grep "$OUT/coll.mods.xml" 'invalid="yes"' "020z flagged invalid"
assert_grep "$OUT/coll.mods.xml" '<roleTerm type="code" authority="marcrelator">aut</roleTerm>' "100 \$4 relator code"
assert_grep "$OUT/coll.mods.xml" '<nonSort>The</nonSort>' "serial nonfiling article"

transform marcxml-to-mods.xsl "$DATA/xslt/single.xml" single.mods.xml "bare record transforms"
assert_absent "$OUT/single.mods.xml" '<modsCollection' "single record yields bare mods element"
assert_grep "$OUT/single.mods.xml" '<typeOfResource>moving image</typeOfResource>' "leader/06 g type"
assert_grep "$OUT/single.mods.xml" '<genre authority="lcgft">Documentary films</genre>' "655 genre"
assert_grep "$OUT/single.mods.xml" '<nonSort>Le</nonSort>' "French article nonSort"

echo "== MARCXML -> oai_dc =="
transform marcxml-to-oai_dc.xsl "$DATA/sample.xml" sample.dc.xml "sample.xml transforms"
assert_grep "$OUT/sample.dc.xml" '<dc:subject>Rivers--Poland--Łódź</dc:subject>' "subject subdivisions joined with --"
assert_grep "$OUT/sample.dc.xml" '<dc:title>Łódź and the river : a study</dc:title>' "title with subtitle"
assert_grep "$OUT/sample.dc.xml" '<dc:creator>Müller, Anna, 1970-</dc:creator>' "creator from 100"
assert_grep "$OUT/sample.dc.xml" '<dc:date>2020</dc:date>' "date from 008"
transform marcxml-to-oai_dc.xsl "$DATA/xslt/collection.xml" coll.dc.xml "collection.xml transforms"
assert_grep "$OUT/coll.dc.xml" '<dc:contributor>Møller, Käthe</dc:contributor>' "contributor from 700"
assert_grep "$OUT/coll.dc.xml" '<dc:language>ger</dc:language>' "008 language"
assert_grep "$OUT/coll.dc.xml" '<dc:language>fre</dc:language>' "041 extra language"
assert_grep "$OUT/coll.dc.xml" '<dc:relation>Nordische Bibliothek ; Band 17</dc:relation>' "490 series relation"
transform marcxml-to-oai_dc.xsl "$DATA/xslt/single.xml" single.dc.xml "bare record transforms"
assert_grep "$OUT/single.dc.xml" '<oai_dc:dc ' "single record yields oai_dc:dc root"
assert_absent "$OUT/single.dc.xml" '<dcRecords' "no wrapper for a single record"

echo "== MARCXML -> RDF (dcterms) =="
transform marcxml-to-rdfdc.xsl "$DATA/sample.xml" sample.rdf.xml "sample.xml transforms"
assert_grep "$OUT/sample.rdf.xml" 'rdf:about="https://example.org/x"' "856u becomes rdf:about"
assert_grep "$OUT/sample.rdf.xml" '<dcterms:identifier>urn:isbn:9780000000001</dcterms:identifier>' "isbn as urn"
assert_grep "$OUT/sample.rdf.xml" 'rdf:resource="http://purl.org/dc/dcmitype/Text"' "DCMI type reference"
assert_grep "$OUT/sample.rdf.xml" '<dcterms:alternative>Nihon no rekishi</dcterms:alternative>' "880 title as alternative"
transform marcxml-to-rdfdc.xsl "$DATA/xslt/collection.xml" coll.rdf.xml "collection.xml transforms"
assert_grep "$OUT/coll.rdf.xml" '<dcterms:isPartOf>Nordische Studien</dcterms:isPartOf>' "773 as isPartOf"
assert_grep "$OUT/coll.rdf.xml" '<dcterms:replaces>Economic weekly bulletin</dcterms:replaces>' "780 as replaces"
assert_grep "$OUT/coll.rdf.xml" '<dcterms:isReplacedBy>The new économiste</dcterms:isReplacedBy>' "785 as isReplacedBy"

echo "== MARCXML -> HTML =="
if xsltproc "$XSL/marcxml-to-html.xsl" "$DATA/xslt/collection.xml" > "$OUT/coll.html" 2> "$OUT/coll.html.err"; then
    ok "collection.xml renders"
else
    bad "collection.xml renders"; sed 's/^/        /' "$OUT/coll.html.err"
fi
assert_grep "$OUT/coll.html" 'Die Erzählungen des Nordens' "245 heading present"
assert_grep "$OUT/coll.html" 'Чехова, Мария' "Cyrillic 880 rendered"
assert_grep "$OUT/coll.html" '<td class="tg">LDR</td>' "leader row present"
assert_grep "$OUT/coll.html" 'MARC records (3)' "record count in heading"

echo "== round trip: MARCXML -> MODS -> MARCXML =="
transform mods-to-marcxml.xsl "$OUT/sample.mods.xml" sample.rt.xml "sample round-trips"
assert_grep "$OUT/sample.rt.xml" '<subfield code="a">Łódź and the river :</subfield>' "245a text and ISBD colon regenerated"
assert_grep "$OUT/sample.rt.xml" '<subfield code="b">a study</subfield>' "245b survives"
assert_grep "$OUT/sample.rt.xml" '<subfield code="d">1970-</subfield>' "100d survives"
assert_grep "$OUT/sample.rt.xml" '<subfield code="z">Poland</subfield>' "650z survives"
assert_grep "$OUT/sample.rt.xml" '<subfield code="2">fast</subfield>' "ind2=7 \$2 scheme survives"
assert_grep "$OUT/sample.rt.xml" '<controlfield tag="001">ocm00000001</controlfield>' "001 survives"
assert_grep "$OUT/sample.rt.xml" '<controlfield tag="003">OCoLC</controlfield>' "003 survives"
assert_grep "$OUT/sample.rt.xml" 'tag="245" ind2="4"' "nonSort skip count restored on The"
assert_grep "$OUT/sample.rt.xml" 's2020' "008 date type+year rebuilt"
assert_grep "$OUT/sample.rt.xml" '<subfield code="a">9780000000001</subfield>' "020a survives"

transform mods-to-marcxml.xsl "$OUT/coll.mods.xml" coll.rt.xml "collection round-trips"
assert_grep "$OUT/coll.rt.xml" '<subfield code="b">AST</subfield>' "264b survives"
assert_grep "$OUT/coll.rt.xml" '<subfield code="c">©2021</subfield>' "copyright date back to 264/4"
assert_grep "$OUT/coll.rt.xml" '<subfield code="a">0951-9998</subfield>' "022 survives"
assert_grep "$OUT/coll.rt.xml" 'tag="504"' "bibliography note back to 504"
assert_grep "$OUT/coll.rt.xml" 'tag="310"' "frequency back to 310"
assert_grep "$OUT/coll.rt.xml" '<subfield code="x">1021-0067</subfield>' "773x issn survives"
assert_grep "$OUT/coll.rt.xml" 'tag="600".*ind2="0"' "600 heading returns as 600"
assert_grep "$OUT/coll.rt.xml" '(Hans Christian)' "600q content survives inside the heading"
# leader/07 for the serial record
assert_grep "$OUT/coll.rt.xml" '<leader>00000nas' "serial leader rebuilt"

echo "== oai_dc -> MARCXML =="
transform oai_dc-to-marcxml.xsl "$DATA/xslt/dc-input.xml" dc2marc.xml "dc-input.xml transforms"
assert_grep "$OUT/dc2marc.xml" '<marc:leader>00000nam a2200000 a 4500</marc:leader>' "Text type synthesizes a book leader"
assert_grep "$OUT/dc2marc.xml" '<marc:leader>00000nic' "Sound + Collection types set leader/06-07"
assert_grep "$OUT/dc2marc.xml" '000000s2019' "008 date type s + year from dc:date"
assert_grep "$OUT/dc2marc.xml" 'dan d</marc:controlfield>' "008 language from three-letter dc:language"
# the first 008 must be exactly 40 characters
len8=$(sed -n 's/.*<marc:controlfield tag="008">\(.*\)<\/marc:controlfield>.*/\1/p' "$OUT/dc2marc.xml" | head -1 | wc -c)
if [ "$len8" = "41" ]; then ok "synthesized 008 is 40 characters"; else bad "synthesized 008 length ($((len8 - 1)))"; fi
n_isbn=$(grep -c '<marc:subfield code="a">9780198526636</marc:subfield>' "$OUT/dc2marc.xml")
if [ "$n_isbn" = "2" ]; then ok "ISBN identifiers (hyphenated 13 and urn:ISBN 10) both land in 020 normalized"; else bad "normalized ISBN count ($n_isbn)"; fi
assert_grep "$OUT/dc2marc.xml" 'tag="022"' "ISSN-shaped identifier discriminated to 022"
assert_grep "$OUT/dc2marc.xml" '<marc:subfield code="u">https://example.org/graenseland</marc:subfield>' "URI identifier discriminated to 856\$u"
assert_grep "$OUT/dc2marc.xml" 'tag="024" ind1="8"' "opaque identifier falls back to 024 8#"
assert_grep "$OUT/dc2marc.xml" '<marc:subfield code="a">Østergaard, Pia</marc:subfield>' "first creator kept (diacritics intact)"
n_700=$(grep -c 'tag="700"' "$OUT/dc2marc.xml")
if [ "$n_700" = "2" ]; then ok "second creator and contributor both become 700s"; else bad "700 count ($n_700)"; fi
assert_grep "$OUT/dc2marc.xml" 'tag="246"' "second title becomes 246"
assert_grep "$OUT/dc2marc.xml" '<marc:subfield code="a">Norwegian</marc:subfield>' "non-code language kept in 041 only"
assert_grep "$OUT/dc2marc.xml" '<marc:subfield code="c">Recorded c1978.</marc:subfield>' "verbatim dc:date kept in 264\$c"
# reverse then forward: the title survives a DC -> MARC -> DC pass
if xsltproc "$XSL/marcxml-to-oai_dc.xsl" "$OUT/dc2marc.xml" > "$OUT/dc2marc2dc.xml" 2>/dev/null \
   && grep -q '<dc:title>Grænselandets fortællinger</dc:title>' "$OUT/dc2marc2dc.xml"; then
    ok "DC -> MARC -> DC keeps the title"
else
    bad "DC -> MARC -> DC keeps the title"
fi

echo "== MARCXML -> dcterms =="
transform marcxml-to-dcterms.xsl "$DATA/xslt/collection.xml" coll.qdc.xml "collection.xml transforms"
assert_grep "$OUT/coll.qdc.xml" '<qdcRecords' "collection input yields qdcRecords wrapper"
assert_grep "$OUT/coll.qdc.xml" '<dcterms:title>Die Erzählungen des Nordens : Übersetzungen aus dem Dänischen</dcterms:title>' "245 title with subtitle"
assert_grep "$OUT/coll.qdc.xml" '<dcterms:alternative>Рассказы о море</dcterms:alternative>' "880-linked 245 becomes alternative"
assert_grep "$OUT/coll.qdc.xml" '<dcterms:issued>1998</dcterms:issued>' "260c becomes issued"
assert_grep "$OUT/coll.qdc.xml" '<dcterms:extent>xii, 340 pages</dcterms:extent>' "300a becomes extent"
assert_grep "$OUT/coll.qdc.xml" '<dcterms:medium>illustrations</dcterms:medium>' "300b becomes medium"
assert_grep "$OUT/coll.qdc.xml" '<dcterms:spatial>Great Britain</dcterms:spatial>' "650z becomes spatial"
assert_grep "$OUT/coll.qdc.xml" '<dcterms:temporal>19th century</dcterms:temporal>' "650y becomes temporal"
assert_grep "$OUT/coll.qdc.xml" '<dcterms:isPartOf>Nordische Studien</dcterms:isPartOf>' "773 becomes isPartOf"
assert_grep "$OUT/coll.qdc.xml" '<dcterms:bibliographicCitation>Jahrgang 12</dcterms:bibliographicCitation>' "773g becomes bibliographicCitation"
assert_grep "$OUT/coll.qdc.xml" '<dcterms:identifier>urn:isbn:9783161484100</dcterms:identifier>' "020a normalized to urn:isbn ISBN-13"
assert_grep "$OUT/coll.qdc.xml" '<dcterms:replaces>Economic weekly bulletin</dcterms:replaces>' "780 becomes replaces"
assert_grep "$OUT/coll.qdc.xml" '<dcterms:language>fre</dcterms:language>' "extra 041 language kept"
transform marcxml-to-dcterms.xsl "$DATA/xslt/single.xml" single.qdc.xml "bare record transforms"
assert_absent "$OUT/single.qdc.xml" '<qdcRecords' "single record yields bare qdcRecord"
assert_grep "$OUT/single.qdc.xml" '<dcterms:type>MovingImage</dcterms:type>' "leader/06 g becomes MovingImage"

echo "== MARCXML -> EAD3 =="
transform marcxml-to-ead.xsl "$DATA/xslt/collection.xml" coll.ead.xml "collection.xml transforms"
assert_grep "$OUT/coll.ead.xml" '<recordid>DKDLA-xslt-fx-0001</recordid>' "recordid from 003+001"
assert_grep "$OUT/coll.ead.xml" '<titleproper>Die Erzählungen des Nordens : Übersetzungen aus dem Dänischen</titleproper>' "titleproper from 245"
assert_grep "$OUT/coll.ead.xml" '<maintenancestatus value="derived"/>' "maintenancestatus derived"
assert_grep "$OUT/coll.ead.xml" '<eventdatetime>190315</eventdatetime>' "maintenance event date from 008/00-05"
assert_grep "$OUT/coll.ead.xml" '<unitdate normal="1998">1998</unitdate>' "unitdate with normalized year from 260c"
assert_grep "$OUT/coll.ead.xml" '<part>Kjærgaard, Søren, 1954-2011</part>' "origination persname from 100"
assert_grep "$OUT/coll.ead.xml" '<physdesc>xii, 340 pages : illustrations ; 24 cm</physdesc>' "physdesc from 300"
assert_grep "$OUT/coll.ead.xml" '<p>A German translation of Danish short prose, with commentary.</p>' "scopecontent from 520"
assert_grep "$OUT/coll.ead.xml" '<subject source="lcsh">' "650 ind2=0 subject with lcsh source"
assert_grep "$OUT/coll.ead.xml" '<genreform source="lcgft">' "655 \$2 genreform source"
assert_grep "$OUT/coll.ead.xml" 'langcode="ger"' "language declaration from 008/35-37"
transform marcxml-to-ead.xsl "$DATA/xslt/single.xml" single.ead.xml "bare record transforms"
assert_absent "$OUT/single.ead.xml" '<eadRecords' "single record yields bare ead"
assert_grep "$OUT/single.ead.xml" '<unittitle>Le voyage extraordinaire</unittitle>' "unittitle from 245"
assert_grep "$OUT/single.ead.xml" '<part>Documentary films</part>' "genreform from 655"

echo "== MARCXML -> schema.org JSON-LD =="
if xsltproc "$XSL/marcxml-to-schemaorg.xsl" "$DATA/xslt/edge.xml" > "$OUT/edge.jsonld" 2> "$OUT/edge.jsonld.err"; then
    ok "edge.xml transforms"
else
    bad "edge.xml transforms"; sed 's/^/        /' "$OUT/edge.jsonld.err"
fi
assert_fgrep "$OUT/edge.jsonld" '"name":"Der \"spezielle\" Pfad C:\\home zurück"' "quotes and backslash escaped, empty 245\$b dropped"
assert_fgrep "$OUT/edge.jsonld" 'summary.\nSecond' "raw newline escaped as \\n"
assert_fgrep "$OUT/edge.jsonld" '{"@type":"Person","name":"O'"'"'Really, \"Tim\""}' "contributor Person node with escaped quotes"
assert_fgrep "$OUT/edge.jsonld" '"isbn":"9780198526636"' "ISBN-10 normalized to 13 digits"
assert_fgrep "$OUT/edge.jsonld" '"sameAs":["http://id.loc.gov/authorities/names/n00000000"]' "\$0 authority URI as sameAs"
assert_fgrep "$OUT/edge.jsonld" '"inLanguage":"ger"' "inLanguage from 008"
if xsltproc "$XSL/marcxml-to-schemaorg.xsl" "$DATA/xslt/collection.xml" > "$OUT/coll.jsonld" 2>/dev/null; then
    ok "collection.xml transforms"
else
    bad "collection.xml transforms"
fi
n_lines=$(grep -c '^{"@context":"https://schema.org","@type":".*}$' "$OUT/coll.jsonld")
if [ "$n_lines" = "3" ]; then ok "one brace-delimited JSON object per record"; else bad "NDJSON line count ($n_lines)"; fi
n_book=$(grep -c '"@type":"Book"' "$OUT/coll.jsonld")
if [ "$n_book" = "2" ]; then ok "leader a+m maps to Book"; else bad "Book count ($n_book)"; fi
assert_fgrep "$OUT/coll.jsonld" '"@type":"Periodical"' "leader a+s maps to Periodical (marc_jsonld_type parity)"
assert_fgrep "$OUT/coll.jsonld" '"issn":"0951-9998"' "022a as issn"
assert_fgrep "$OUT/coll.jsonld" '"publisher":{"@type":"Organization","name":"Mohr Siebeck"}' "publisher Organization node"
assert_fgrep "$OUT/coll.jsonld" '"about":["Andersen, H. C.","Danish literature","Short stories"]' "6XX \$a values as about array"
assert_absent "$OUT/coll.jsonld" '"isbn":""' "absent data drops its key (no empty members)"

echo "== MARCXML -> RIS =="
if xsltproc "$XSL/marcxml-to-ris.xsl" "$DATA/xslt/edge.xml" > "$OUT/edge.ris" 2> "$OUT/edge.ris.err"; then
    ok "edge.xml transforms"
else
    bad "edge.xml transforms"; sed 's/^/        /' "$OUT/edge.ris.err"
fi
assert_grep "$OUT/edge.ris" '^TY  - BOOK$' "TY BOOK from leader"
assert_fgrep "$OUT/edge.ris" 'TI  - Der "spezielle" Pfad C:\home zurück' "quotes and backslash pass through RIS unaltered"
assert_fgrep "$OUT/edge.ris" 'N1  - First line of the summary. Second line after a raw newline.' "embedded newline collapsed to one RIS line"
assert_grep "$OUT/edge.ris" '^AU  - Grünbaum, Jürgen, 1930-2001$' "AU from 100 with dates"
assert_fgrep "$OUT/edge.ris" 'A2  - O'"'"'Really, "Tim"' "A2 from 700"
assert_grep "$OUT/edge.ris" '^SN  - 0-19-852663-6$' "SN from 020a"
assert_grep "$OUT/edge.ris" '^UR  - https://example.org/path?a=1&b=2$' "UR from 856u"
if xsltproc "$XSL/marcxml-to-ris.xsl" "$DATA/xslt/collection.xml" > "$OUT/coll.ris" 2>/dev/null; then
    ok "collection.xml transforms"
else
    bad "collection.xml transforms"
fi
assert_grep "$OUT/coll.ris" '^TY  - JOUR$' "serial leader maps to JOUR"
assert_grep "$OUT/coll.ris" '^T2  - Nordische Studien$' "host title as T2"
assert_grep "$OUT/coll.ris" '^PY  - 1985$' "year extracted from open-ended 1985-"
assert_grep "$OUT/coll.ris" '^CY  - Tübingen$' "place as CY"
assert_grep "$OUT/coll.ris" '^KW  - Danish literature$' "6XX as KW"
n_er=$(grep -c '^ER  - $' "$OUT/coll.ris")
if [ "$n_er" = "3" ]; then ok "every record gets an ER terminator"; else bad "ER count ($n_er)"; fi

echo "== MARC21 -> UNIMARC skeleton =="
transform marc21-to-unimarc-skeleton.xsl "$DATA/xslt/edge.xml" edge.uni.xml "edge.xml transforms"
assert_grep "$OUT/edge.uni.xml" '<marc:leader>00000nam  2200000   450 </marc:leader>' "record label rebuilt for a monograph"
assert_grep "$OUT/edge.uni.xml" '<marc:subfield code="a">20220101d2022' "100\$a processing data: expanded date + type d + date1"
# UNIMARC 100$a must be exactly 36 characters (100 is the first datafield,
# so its $a is the first subfield in the document)
len100=$(sed -n 's/.*<marc:subfield code="a">\(.*\)<\/marc:subfield>.*/\1/p' "$OUT/edge.uni.xml" | head -1 | wc -m)
if [ "$len100" = "37" ]; then ok "100\$a is 36 characters"; else bad "100\$a length ($((len100 - 1)))"; fi
assert_grep "$OUT/edge.uni.xml" 'tag="101"' "101 language field emitted"
assert_grep "$OUT/edge.uni.xml" '<marc:subfield code="a">Der "spezielle" Pfad C:.home zurück</marc:subfield>' "200a title from 245a (empty 245b dropped)"
assert_grep "$OUT/edge.uni.xml" '<marc:subfield code="f">Jürgen Grünbaum</marc:subfield>' "200f statement of responsibility from 245c"
assert_grep "$OUT/edge.uni.xml" '<marc:subfield code="c">Beispiel-Verlag "Süd"</marc:subfield>' "210c publisher name from 260/264b"
assert_grep "$OUT/edge.uni.xml" '<marc:subfield code="d">23 cm</marc:subfield>' "215d dimensions from 300c"
assert_grep "$OUT/edge.uni.xml" '<marc:subfield code="y">Germany</marc:subfield>' "606: MARC21 \$z geographic re-lettered to UNIMARC \$y"
assert_grep "$OUT/edge.uni.xml" '<marc:subfield code="z">20th century</marc:subfield>' "606: MARC21 \$y chronological re-lettered to UNIMARC \$z"
assert_grep "$OUT/edge.uni.xml" '<marc:subfield code="b">Jürgen</marc:subfield>' "700: forename split into \$b"
assert_grep "$OUT/edge.uni.xml" '<marc:subfield code="f">1930-2001</marc:subfield>' "700f dates from 100d"
assert_grep "$OUT/edge.uni.xml" 'tag="701"' "MARC21 700 becomes UNIMARC 701"
transform marc21-to-unimarc-skeleton.xsl "$DATA/xslt/collection.xml" coll.uni.xml "collection.xml transforms"
assert_grep "$OUT/coll.uni.xml" '<marc:leader>00000nas' "serial label keeps type a level s"
assert_grep "$OUT/coll.uni.xml" '<marc:subfield code="a">fre</marc:subfield>' "extra 041 language joins 101"
transform marc21-to-unimarc-skeleton.xsl "$DATA/xslt/single.xml" single.uni.xml "bare record transforms"
assert_grep "$OUT/single.uni.xml" '<marc:leader>00000ngm' "projected-media type g survives"

echo
echo "$checks checks, $fails failures"
[ "$fails" -eq 0 ] || exit 1
exit 0
