#!/bin/sh
# Functional tests for the BIBFRAME 2 crosswalks in xslt/.
# Requires xsltproc and xmllint. Exits nonzero on the first missing tool
# and counts assertion failures otherwise. Self-contained: uses only
# xslt/ stylesheets and test/data/bibframe/ fixtures.

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
XSL="$ROOT/xslt"
DATA="$ROOT/test/data/bibframe"
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

echo "== stylesheets are well-formed =="
for f in "$XSL"/marcxml-to-bibframe2.xsl "$XSL"/bibframe2-to-marcxml.xsl; do
    if xmllint --noout "$f" 2>/dev/null; then ok "$(basename "$f")"; else bad "$(basename "$f")"; fi
done

echo "== MARCXML -> BIBFRAME 2 =="
if xsltproc "$XSL/marcxml-to-bibframe2.xsl" "$DATA/sample.xml" > "$OUT/bf.xml" 2> "$OUT/bf.err" \
   && xmllint --noout "$OUT/bf.xml" 2>> "$OUT/bf.err"; then
    ok "sample.xml transforms to well-formed RDF/XML"
else
    bad "sample.xml transforms to well-formed RDF/XML"
    sed 's/^/        /' "$OUT/bf.err"
fi

# Work/Instance/Item split and node identity
assert_grep "$OUT/bf.xml" '<bf:Work rdf:about="http://example.org/bf0000001#Work">' "Work URI minted from default baseuri + 001"
assert_grep "$OUT/bf.xml" '<bf:Instance rdf:about="http://example.org/bf0000001#Instance">' "Instance node present"
assert_grep "$OUT/bf.xml" '<bf:instanceOf rdf:resource="http://example.org/bf0000001#Work"/>' "instanceOf back-link"
assert_grep "$OUT/bf.xml" '<bf:hasInstance rdf:resource="http://example.org/bf0000001#Instance"/>' "hasInstance link"
assert_grep "$OUT/bf.xml" '<bf:Item rdf:about="http://example.org/bf0000001#Item">' "852 yields an Item"
assert_grep "$OUT/bf.xml" '<rdfs:label>Main Library Stacks</rdfs:label>' "Item heldBy label from 852ab"
assert_absent "$OUT/bf.xml" 'bf0000002#Item' "no Item without an 852"

# Work types from Leader/06
assert_grep "$OUT/bf.xml" 'rdf:type rdf:resource="http://id.loc.gov/ontologies/bibframe/Text"' "leader/06 a types the Work bf:Text"

# title
assert_grep "$OUT/bf.xml" '<bf:mainTitle>Whale watchers</bf:mainTitle>' "245a mainTitle, ISBD colon chomped"
assert_grep "$OUT/bf.xml" '<bf:subtitle>a guide to the cetaceans</bf:subtitle>' "245b subtitle, slash chomped"
assert_grep "$OUT/bf.xml" '<bf:mainTitle>Revue des cétacés</bf:mainTitle>' "diacritics intact in the serial title"

# contribution with roles
assert_grep "$OUT/bf.xml" 'rdf:type rdf:resource="http://id.loc.gov/ontologies/bflc/PrimaryContribution"' "100 typed PrimaryContribution"
assert_grep "$OUT/bf.xml" '<rdfs:label>Berger, Melvin</rdfs:label>' "100a agent label"
assert_grep "$OUT/bf.xml" '<bf:role rdf:resource="http://id.loc.gov/vocabulary/relators/aut"/>' "100 \$4 relator URI"
assert_grep "$OUT/bf.xml" '<rdfs:label>illustrator</rdfs:label>' "700 \$e role label"
assert_grep "$OUT/bf.xml" '<bf:Organization>' "710 agent is an Organization"

# subjects
assert_grep "$OUT/bf.xml" '<rdfs:label>Whales--Guidebooks</rdfs:label>' "650 subdivisions joined"
assert_grep "$OUT/bf.xml" 'bf:Topic rdf:about="http://id.loc.gov/authorities/subjects/sh85146200"' "650 \$0 as subject URI"
assert_grep "$OUT/bf.xml" '<bf:Place>' "651 as bf:Place"

# language from 008/35-37
assert_grep "$OUT/bf.xml" '<bf:language rdf:resource="http://id.loc.gov/vocabulary/languages/eng"/>' "008/35-37 eng language URI"
assert_grep "$OUT/bf.xml" '<bf:language rdf:resource="http://id.loc.gov/vocabulary/languages/fre"/>' "serial 008 fre language URI"

# classification
assert_grep "$OUT/bf.xml" '<bf:classificationPortion>QL737.C4</bf:classificationPortion>' "050a classification portion"
assert_grep "$OUT/bf.xml" '<bf:itemPortion>B47 1989</bf:itemPortion>' "050b item portion"
assert_grep "$OUT/bf.xml" '<bf:ClassificationDdc>' "082 as Ddc"

# provision activity
assert_grep "$OUT/bf.xml" '<rdfs:label>New York</rdfs:label>' "264a publication place"
assert_grep "$OUT/bf.xml" '<rdfs:label>Pond Press</rdfs:label>' "264b publisher agent"
assert_grep "$OUT/bf.xml" '<bf:date>1989</bf:date>' "264c date, period chomped"

# identifiers
assert_grep "$OUT/bf.xml" '<rdf:value>0-306-40615-2 (pbk.)</rdf:value>' "020a as bf:Isbn value"
assert_grep "$OUT/bf.xml" '<bf:Isbn>' "bf:Isbn class"
assert_grep "$OUT/bf.xml" '<rdf:value>2049-3630</rdf:value>' "022a as bf:Issn value"
assert_grep "$OUT/bf.xml" '<rdf:value>89012345</rdf:value>' "010a as bf:Lccn value"
assert_grep "$OUT/bf.xml" '<rdf:value>ocm00012345</rdf:value>' "035 OCoLC number kept"

# extent
assert_grep "$OUT/bf.xml" '<rdfs:label>xii, 178 pages</rdfs:label>' "300a extent"

# 336-338 vocabulary URIs
assert_grep "$OUT/bf.xml" '<bf:content rdf:resource="http://id.loc.gov/vocabulary/contentTypes/txt"/>' "336b content URI on the Work"
assert_grep "$OUT/bf.xml" '<bf:media rdf:resource="http://id.loc.gov/vocabulary/mediaTypes/n"/>' "337b media URI"
assert_grep "$OUT/bf.xml" '<bf:carrier rdf:resource="http://id.loc.gov/vocabulary/carriers/nc"/>' "338b carrier URI"
assert_grep "$OUT/bf.xml" '<bf:carrier rdf:resource="http://id.loc.gov/vocabulary/carriers/cr"/>' "online serial carrier cr"

# 856
assert_grep "$OUT/bf.xml" '<bf:electronicLocator rdf:resource="https://example.org/whales"/>' "856u electronic locator"

echo "== baseuri parameter =="
if xsltproc --stringparam baseuri "https://data.example.edu/bib/" \
       "$XSL/marcxml-to-bibframe2.xsl" "$DATA/sample.xml" > "$OUT/bf-base.xml" 2>/dev/null; then
    ok "transform with explicit baseuri"
else
    bad "transform with explicit baseuri"
fi
assert_grep "$OUT/bf-base.xml" 'rdf:about="https://data.example.edu/bib/bf0000001#Work"' "rdf:about uses the baseuri parameter"
assert_absent "$OUT/bf-base.xml" 'http://example.org/' "default baseuri fully replaced"

echo "== round trip: MARCXML -> BIBFRAME 2 -> MARCXML =="
if xsltproc "$XSL/bibframe2-to-marcxml.xsl" "$OUT/bf.xml" > "$OUT/rt.xml" 2> "$OUT/rt.err" \
   && xmllint --noout "$OUT/rt.xml" 2>> "$OUT/rt.err"; then
    ok "BIBFRAME output round-trips to well-formed MARCXML"
else
    bad "BIBFRAME output round-trips to well-formed MARCXML"
    sed 's/^/        /' "$OUT/rt.err"
fi
assert_grep "$OUT/rt.xml" '<subfield code="a">Whale watchers :</subfield>' "245a regenerated with ISBD colon"
assert_grep "$OUT/rt.xml" '<subfield code="b">a guide to the cetaceans</subfield>' "245b regenerated"
assert_grep "$OUT/rt.xml" '<subfield code="a">Berger, Melvin</subfield>' "100a regenerated"
assert_grep "$OUT/rt.xml" 'tag="100" ind1="1"' "primary contribution back as 100"
assert_grep "$OUT/rt.xml" '<subfield code="4">aut</subfield>' "relator URI back to \$4"
assert_grep "$OUT/rt.xml" '<subfield code="a">0-306-40615-2 (pbk.)</subfield>' "020a regenerated"
assert_grep "$OUT/rt.xml" '<subfield code="a">2049-3630</subfield>' "022a regenerated"
assert_grep "$OUT/rt.xml" '<subfield code="a">Whales</subfield>' "650a regenerated from the subject label"
assert_grep "$OUT/rt.xml" '<subfield code="x">Guidebooks</subfield>' "subject subdivision back as \$x"
assert_grep "$OUT/rt.xml" '<subfield code="0">http://id.loc.gov/authorities/subjects/sh85146200</subfield>' "subject URI back as \$0"
assert_grep "$OUT/rt.xml" 'tag="264" ind1=" " ind2="1"' "publication back as 264 _1"
assert_grep "$OUT/rt.xml" '<subfield code="b">Pond Press,</subfield>' "264b regenerated with ISBD comma"
assert_grep "$OUT/rt.xml" '<subfield code="b">txt</subfield>' "336b regenerated"
assert_grep "$OUT/rt.xml" '<subfield code="2">rdacontent</subfield>' "336 \$2 rdacontent restored"
assert_grep "$OUT/rt.xml" '<subfield code="2">rdamedia</subfield>' "337 \$2 rdamedia restored"
assert_grep "$OUT/rt.xml" '<subfield code="2">rdacarrier</subfield>' "338 \$2 rdacarrier restored"
assert_grep "$OUT/rt.xml" '<subfield code="u">https://example.org/whales</subfield>' "856u regenerated"
assert_grep "$OUT/rt.xml" '<leader>00000nam a2200000 a 4500</leader>' "plausible monograph leader rebuilt"
assert_grep "$OUT/rt.xml" '<leader>00000nas a2200000 a 4500</leader>' "serial leader rebuilt from the Issn"
assert_grep "$OUT/rt.xml" '<controlfield tag="001">bf0000001</controlfield>' "001 restored from admin metadata"
assert_grep "$OUT/rt.xml" 's1989    xx' "008 year rebuilt from the provision date"
assert_grep "$OUT/rt.xml" 'eng d</controlfield>' "008 language rebuilt from the language URI"
# 008 must be exactly 40 characters
n008=$(grep -o '<controlfield tag="008">[^<]*' "$OUT/rt.xml" | head -1 | sed 's/.*>//' | wc -c)
if [ "$n008" = "41" ]; then ok "regenerated 008 is 40 characters"; else bad "regenerated 008 length ($((n008 - 1)))"; fi

echo
echo "$checks checks, $fails failures"
[ "$fails" -eq 0 ] || exit 1
exit 0
