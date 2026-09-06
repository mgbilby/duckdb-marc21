#!/bin/sh
# Functional tests for the international crosswalks in xslt/
# (UNIMARC both directions, ONIX 3.x, EDM, MADS). Requires xsltproc and
# xmllint; modeled on test/xslt/run.sh. Exits nonzero on the first missing
# tool and counts assertion failures otherwise.

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
XSL="$ROOT/xslt"
DATA="$ROOT/test/data/intl"
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

# transform <stylesheet> <input> <output> <label> [xsltproc args...]
transform() {
    xsl=$1; in=$2; out=$3; label=$4; shift 4
    if xsltproc "$@" "$XSL/$xsl" "$in" > "$OUT/$out" 2> "$OUT/$out.err"; then
        if xmllint --noout "$OUT/$out" 2>> "$OUT/$out.err"; then
            ok "$label"
            return 0
        fi
    fi
    bad "$label"
    sed 's/^/        /' "$OUT/$out.err"
    return 1
}

echo "== stylesheets are well-formed =="
for f in "$XSL"/unimarc-to-marc21.xsl "$XSL"/marc21-to-unimarc.xsl \
         "$XSL"/marcxml-to-onix3.xsl "$XSL"/marcxml-to-edm.xsl \
         "$XSL"/marcxml-to-mads.xsl \
         "$XSL"/rusmarc-to-marc21.xsl "$XSL"/marc21-to-rusmarc.xsl \
         "$XSL"/kormarc-to-marc21.xsl "$XSL"/marc21-to-kormarc.xsl \
         "$XSL"/intermarc-to-marc21.xsl "$XSL"/marc21-to-intermarc.xsl \
         "$XSL"/japanmarc-normalize.xsl \
         "$XSL"/ibermarc-to-marc21.xsl "$XSL"/mab2-to-marc21.xsl; do
    if xmllint --noout "$f" 2>/dev/null; then ok "$(basename "$f")"; else bad "$(basename "$f")"; fi
done

echo "== UNIMARC -> MARC 21 =="
transform unimarc-to-marc21.xsl "$DATA/unimarc.xml" u2m.xml "unimarc.xml transforms"
assert_absent "$OUT/u2m.xml" '<collection' "bare record stays bare"
assert_grep "$OUT/u2m.xml" '<leader>00000nam a2200000 i 4500</leader>' "record label converted to MARC 21 leader"
assert_grep "$OUT/u2m.xml" '<controlfield tag="001">UNIX0001</controlfield>' "001 copied"
assert_grep "$OUT/u2m.xml" '240101s2020    fr |||||||||||||||||fre d' "008 rebuilt from 100/101/102 (dates, country, language)"
assert_grep "$OUT/u2m.xml" 'tag="020"' "010 ISBN becomes 020"
assert_grep "$OUT/u2m.xml" '<subfield code="a">2-07-036822-X</subfield>' "010a ISBN value survives"
assert_grep "$OUT/u2m.xml" '<subfield code="c">9,90 EUR</subfield>' "010d price becomes 020c"
assert_grep "$OUT/u2m.xml" '<subfield code="a">BNF</subfield>' "801/0 agency becomes 040a"
assert_grep "$OUT/u2m.xml" '<subfield code="b">fre</subfield>' "language of cataloguing (100/22-24) becomes 040b"
assert_grep "$OUT/u2m.xml" '<subfield code="e">AFNOR</subfield>' "801g rules become 040e"
assert_grep "$OUT/u2m.xml" 'tag="041" ind1="1"' "101 ind1 translation flag becomes 041 ind1"
assert_grep "$OUT/u2m.xml" '<subfield code="h">eng</subfield>' "101c original language becomes 041h"
assert_grep "$OUT/u2m.xml" '<subfield code="c">FR</subfield>' "102 ISO country kept in 044c"
assert_grep "$OUT/u2m.xml" '<subfield code="a">Les oiseaux de Loire</subfield>' "200a title proper becomes 245a"
assert_grep "$OUT/u2m.xml" '<subfield code="b">guide illustré</subfield>' "200e other title becomes 245b"
assert_grep "$OUT/u2m.xml" '<subfield code="c">Jean Aubry ; traduit par Marie Petit</subfield>' "200f+g responsibility joined into 245c"
assert_grep "$OUT/u2m.xml" 'tag="100" ind2=" " ind1="1"' "700 entry form maps to 100 ind1"
assert_grep "$OUT/u2m.xml" '<subfield code="a">Aubry, Jean</subfield>' "700 a+b rejoined as inverted 100a"
assert_grep "$OUT/u2m.xml" '<subfield code="4">aut</subfield>' "UNIMARC relator 070 becomes aut"
assert_grep "$OUT/u2m.xml" '<subfield code="a">Petit, Marie</subfield>' "702 becomes added-entry 700"
assert_grep "$OUT/u2m.xml" '<subfield code="4">trl</subfield>' "UNIMARC relator 730 becomes trl"
assert_grep "$OUT/u2m.xml" '<subfield code="a">3e édition</subfield>' "205 edition becomes 250"
assert_grep "$OUT/u2m.xml" '<subfield code="b">Éditions Fluviales</subfield>' "210c publisher becomes 260b"
assert_grep "$OUT/u2m.xml" '<subfield code="b">ill. en coul.</subfield>' "215c details become 300b"
assert_grep "$OUT/u2m.xml" '<subfield code="a">Nature en France</subfield>' "225 series becomes 490"
assert_grep "$OUT/u2m.xml" 'tag="500".*$' "300 note becomes 500"
assert_grep "$OUT/u2m.xml" '<subfield code="a">Bibliogr. p. 170-174</subfield>' "320 becomes 504"
assert_grep "$OUT/u2m.xml" '<subfield code="a">Guide illustré des oiseaux de la vallée de la Loire.</subfield>' "330 summary becomes 520"
assert_grep "$OUT/u2m.xml" 'tag="650" ind1=" " ind2="7"' "606 with source becomes 650 ind2 7"
assert_grep "$OUT/u2m.xml" '<subfield code="z">Loire (France)</subfield>' "UNIMARC y geographic swaps to MARC z"
assert_grep "$OUT/u2m.xml" '<subfield code="y">21e siècle</subfield>' "UNIMARC z chronological swaps to MARC y"
assert_grep "$OUT/u2m.xml" '<subfield code="2">rameau</subfield>' "subject source system carried in \$2"
assert_grep "$OUT/u2m.xml" '<subfield code="a">Loire, Vallée de la (France)</subfield>' "607 becomes 651"
assert_grep "$OUT/u2m.xml" 'tag="610" ind1="2" ind2="7"' "601 corporate subject becomes 610"
assert_grep "$OUT/u2m.xml" '<subfield code="d">1950-....</subfield>' "600f dates become 600d"
assert_grep "$OUT/u2m.xml" '<subfield code="a">QL690</subfield>' "680 LCC becomes 050"
assert_grep "$OUT/u2m.xml" 'tag="080"' "675 UDC becomes 080"
assert_grep "$OUT/u2m.xml" '<subfield code="a">598.29445</subfield>' "676 DDC becomes 082"
assert_grep "$OUT/u2m.xml" '<subfield code="2">23</subfield>' "676v edition becomes 082 \$2"
assert_grep "$OUT/u2m.xml" 'tag="765"' "454 translation-of becomes 765"
assert_grep "$OUT/u2m.xml" '<subfield code="t">Birds of the Loire</subfield>' "454t title survives"
assert_grep "$OUT/u2m.xml" '<subfield code="u">https://example.org/loire</subfield>' "856 copied verbatim"

echo "== MARC 21 -> UNIMARC =="
transform marc21-to-unimarc.xsl "$DATA/bib.xml" m2u.xml "bib.xml transforms"
assert_grep "$OUT/m2u.xml" '<collection' "collection stays a collection"
assert_grep "$OUT/m2u.xml" '<leader>00000nam0 2200000   450 </leader>' "leader converted to UNIMARC record label"
assert_grep "$OUT/m2u.xml" '<subfield code="a">20240101d2021    u  y0frey50' "100a processing data rebuilt from 008 + 040b"
assert_grep "$OUT/m2u.xml" 'tag="101" ind2=" " ind1="0"' "101 built from 041"
assert_grep "$OUT/m2u.xml" '<subfield code="a">eng</subfield>' "second 041a language carried"
assert_grep "$OUT/m2u.xml" '<subfield code="a">FR</subfield>' "008/15-17 fr maps to 102 ISO FR"
assert_grep "$OUT/m2u.xml" '<subfield code="a">0-306-40615-2</subfield>' "020 ISBN becomes 010"
assert_grep "$OUT/m2u.xml" '<subfield code="a">Les canards du Saint-Laurent</subfield>' "245a becomes 200a (punctuation trimmed)"
assert_grep "$OUT/m2u.xml" "<subfield code=\"e\">guide d'observation</subfield>" "245b becomes 200e"
assert_grep "$OUT/m2u.xml" '<subfield code="f">Amélie Côté</subfield>' "245c becomes 200f"
assert_grep "$OUT/m2u.xml" '<subfield code="a">2e édition</subfield>' "250 becomes 205"
assert_grep "$OUT/m2u.xml" 'tag="214" ind1=" " ind2="0"' "264/_1 publication becomes 214/_0"
assert_grep "$OUT/m2u.xml" '<subfield code="c">Éditions du Lac</subfield>' "264b becomes 214c"
assert_grep "$OUT/m2u.xml" '<subfield code="d">2021</subfield>' "264c becomes 214d"
assert_grep "$OUT/m2u.xml" '<subfield code="a">214 pages</subfield>' "300a becomes 215a"
assert_grep "$OUT/m2u.xml" '<subfield code="d">23 cm</subfield>' "300c dimensions become 215d"
assert_grep "$OUT/m2u.xml" '<subfield code="a">Faune du Québec</subfield>' "490 becomes 225"
assert_grep "$OUT/m2u.xml" '<subfield code="a">Comprend un index.</subfield>' "500 becomes 300"
assert_grep "$OUT/m2u.xml" '<subfield code="a">Comprend des références bibliographiques.</subfield>' "504 becomes 320"
assert_grep "$OUT/m2u.xml" 'tag="330"' "520 summary becomes 330"
assert_grep "$OUT/m2u.xml" '<subfield code="y">Québec (Province)</subfield>' "MARC z geographic swaps to UNIMARC y"
assert_grep "$OUT/m2u.xml" '<subfield code="z">21st century</subfield>' "MARC y chronological swaps to UNIMARC z"
assert_grep "$OUT/m2u.xml" '<subfield code="2">lc</subfield>' "LCSH ind2 0 becomes \$2 lc"
assert_grep "$OUT/m2u.xml" 'tag="607"' "651 becomes 607"
assert_grep "$OUT/m2u.xml" '<subfield code="a">Audubon</subfield>' "600a surname split to entry element"
assert_grep "$OUT/m2u.xml" '<subfield code="b">Jean</subfield>' "600a forename split to \$b"
assert_grep "$OUT/m2u.xml" 'tag="601" ind1="0"' "610 becomes 601 corporate"
assert_grep "$OUT/m2u.xml" '<subfield code="a">598.2</subfield>' "080 UDC becomes 675"
assert_grep "$OUT/m2u.xml" '<subfield code="v">23</subfield>' "082 \$2 edition becomes 676v"
assert_grep "$OUT/m2u.xml" '<subfield code="a">QL696.A52</subfield>' "050 becomes 680"
assert_grep "$OUT/m2u.xml" 'tag="700" ind1=" " ind2="1"' "100 surname entry becomes 700 ind2 1"
assert_grep "$OUT/m2u.xml" '<subfield code="a">Côté</subfield>' "100a entry element split"
assert_grep "$OUT/m2u.xml" '<subfield code="4">070</subfield>' "relator aut becomes numeric 070"
assert_grep "$OUT/m2u.xml" 'tag="702"' "added-entry 700 becomes 702"
assert_grep "$OUT/m2u.xml" '<subfield code="4">730</subfield>' "relator trl becomes numeric 730"
assert_grep "$OUT/m2u.xml" 'tag="712"' "710 becomes 712"
assert_grep "$OUT/m2u.xml" 'tag="801" ind1=" " ind2="0"' "040a becomes 801 ind2 0"
assert_grep "$OUT/m2u.xml" '<subfield code="b">CaQMU</subfield>' "040d modifying agency becomes 801 ind2 2"
assert_grep "$OUT/m2u.xml" 'tag="430"' "780 continues becomes 430"
assert_grep "$OUT/m2u.xml" '<subfield code="x">1234-5679</subfield>' "780x ISSN carried into 430"
assert_grep "$OUT/m2u.xml" '<subfield code="u">https://example.org/canards</subfield>' "856 copied verbatim"

echo "== round trip: MARC 21 -> UNIMARC -> MARC 21 =="
transform unimarc-to-marc21.xsl "$OUT/m2u.xml" rt.xml "UNIMARC output converts back"
assert_grep "$OUT/rt.xml" '<subfield code="a">Les canards du Saint-Laurent</subfield>' "245a preserved"
assert_grep "$OUT/rt.xml" '<subfield code="a">Côté, Amélie</subfield>' "100a split and rejoined intact"
assert_grep "$OUT/rt.xml" '<subfield code="a">0-306-40615-2</subfield>' "020a preserved"
assert_grep "$OUT/rt.xml" '<subfield code="a">Ducks</subfield>' "650a preserved"
assert_grep "$OUT/rt.xml" '240101s2021    fr |||||||||||||||||fre d' "008 language and dates preserved"
assert_grep "$OUT/rt.xml" 'tag="650" ind1=" " ind2="0"' "LCSH source round-trips to ind2 0"
assert_grep "$OUT/rt.xml" '<leader>00000njm a2200000 i 4500</leader>' "sound-recording leader type j survives"

echo "== RUSMARC -> MARC 21 (delta over the UNIMARC sheet) =="
transform rusmarc-to-marc21.xsl "$DATA/rusmarc.xml" r2m.xml "rusmarc.xml transforms"
assert_grep "$OUT/r2m.xml" '<subfield code="a">Птицы Волги</subfield>' "Cyrillic 200a title becomes 245a"
assert_grep "$OUT/r2m.xml" '<subfield code="a">Петров, Иван</subfield>' "700 a+b rejoined as inverted 100a"
assert_grep "$OUT/r2m.xml" 'tag="084" ind1=" " ind2=" "' "686 becomes 084"
assert_grep "$OUT/r2m.xml" '<subfield code="a">28.693.35</subfield>' "686a BBK index survives"
assert_grep "$OUT/r2m.xml" '<subfield code="2">rubbk</subfield>' "BBK system code carried in 084 \$2"
assert_grep "$OUT/r2m.xml" '<subfield code="2">07</subfield>' "802 ISSN centre code becomes 022 \$2"
assert_grep "$OUT/r2m.xml" '<subfield code="a">RuMoRGB</subfield>' "801 \$b agency becomes 040a"
assert_grep "$OUT/r2m.xml" '<subfield code="e">psbo</subfield>' "801 \$g cataloguing rules become 040e"
assert_grep "$OUT/r2m.xml" '240301s2021    ru ||||e|||||o||||||rus d' "008 audience (100/17) and government publication (100/20) coded"
assert_grep "$OUT/r2m.xml" 'tag="906"' "9XX national field passes through"
assert_grep "$OUT/r2m.xml" '<subfield code="a">ОРФ</subfield>' "9XX Cyrillic content preserved"
assert_grep "$OUT/r2m.xml" '<subfield code="a">598.2(470.4)</subfield>' "inherited 675 UDC mapping still applies"
assert_grep "$OUT/r2m.xml" '<subfield code="a">Библиогр.: с. 240-245</subfield>' "inherited 320 note mapping still applies"

echo "== round trip: RUSMARC -> MARC 21 -> RUSMARC =="
transform marc21-to-rusmarc.xsl "$OUT/r2m.xml" m2r.xml "MARC 21 output converts back"
assert_grep "$OUT/m2r.xml" '<subfield code="a">Птицы Волги</subfield>' "200a restored"
assert_grep "$OUT/m2r.xml" 'tag="686"' "084 becomes 686 again"
assert_grep "$OUT/m2r.xml" '<subfield code="2">rubbk</subfield>' "BBK system code round-trips"
assert_grep "$OUT/m2r.xml" 'tag="802"' "022 \$2 becomes 802 again"
assert_grep "$OUT/m2r.xml" 'tag="906"' "9XX national field round-trips"
assert_grep "$OUT/m2r.xml" '<subfield code="a">RU</subfield>' "801 \$a country written by the RUSMARC convention"
assert_grep "$OUT/m2r.xml" '<subfield code="c">20240301</subfield>' "801 \$c date taken from 005"
assert_grep "$OUT/m2r.xml" '<subfield code="g">psbo</subfield>' "801 \$g cataloguing rules round-trip"
assert_grep "$OUT/m2r.xml" '<subfield code="a">Петров</subfield>' "100a split back to entry element"

echo "== KORMARC -> MARC 21 =="
transform kormarc-to-marc21.xsl "$DATA/kormarc.xml" k2m.xml "kormarc.xml transforms"
assert_grep "$OUT/k2m.xml" '<subfield code="a">한국의 새 :</subfield>' "Hangul 245a copied through"
assert_grep "$OUT/k2m.xml" 'tag="245" ind1="1" ind2="0"' "non-Latin title proper forces nonfiling 0"
assert_grep "$OUT/k2m.xml" 'tag="084"' "056 KDC becomes 084"
assert_grep "$OUT/k2m.xml" '<subfield code="2">kdc</subfield>' "KDC scheme code written in 084 \$2"
assert_absent "$OUT/k2m.xml" 'tag="056"' "056 does not survive as itself"
assert_absent "$OUT/k2m.xml" 'tag="052"' "KORMARC 052 call number never stays in MARC 21 052"
assert_grep "$OUT/k2m.xml" 'tag="852" ind1="8"' "049 holdings become an 852"
assert_grep "$OUT/k2m.xml" '<subfield code="p">EM0000123456</subfield>' "049l registration number becomes 852p"
assert_grep "$OUT/k2m.xml" '<subfield code="c">별치</subfield>' "049f separate location becomes 852c"
assert_grep "$OUT/k2m.xml" '<subfield code="t">c.2</subfield>' "049c copy becomes 852t"
assert_grep "$OUT/k2m.xml" '<subfield code="i">김66ㅎ2</subfield>' "090 local call number wins over 052 in 852h/i"
assert_grep "$OUT/k2m.xml" 'tag="246" ind1="3"' "940 local title heading becomes 246"
assert_grep "$OUT/k2m.xml" '<subfield code="a">Hanguk ui sae</subfield>' "940a romanized title survives"
assert_grep "$OUT/k2m.xml" 'tag="037"' "950 price becomes 037"
assert_grep "$OUT/k2m.xml" '240401s2022    ko |||||||||||||||||kor||' "008 country and language filled with the Korean codes"
assert_grep "$OUT/k2m.xml" 'tag="990"' "other 9XX local fields pass through"

echo "== round trip: KORMARC -> MARC 21 -> KORMARC =="
transform marc21-to-kormarc.xsl "$OUT/k2m.xml" m2k.xml "MARC 21 output converts back"
assert_grep "$OUT/m2k.xml" 'tag="056"' "084 \$2 kdc becomes 056 again"
assert_grep "$OUT/m2k.xml" 'tag="049" ind1="0"' "852 holdings become 049 again"
assert_grep "$OUT/m2k.xml" '<subfield code="l">EM0000123456</subfield>' "registration number round-trips"
assert_grep "$OUT/m2k.xml" 'tag="090"' "852 call number becomes 090 again"
assert_grep "$OUT/m2k.xml" '<subfield code="b">김66ㅎ2</subfield>' "local book number round-trips"
assert_grep "$OUT/m2k.xml" 'tag="950"' "037 price becomes 950 again"
assert_grep "$OUT/m2k.xml" '<subfield code="a">한국의 새 :</subfield>' "Hangul title survives the round trip"
assert_absent "$OUT/m2k.xml" 'tag="084"' "the KDC-sourced 084 is consumed, not duplicated"

echo "== INTERMARC (BnF) -> MARC 21 =="
transform intermarc-to-marc21.xsl "$DATA/intermarc.xml" i2m.xml "intermarc.xml transforms"
assert_grep "$OUT/i2m.xml" '<leader>00000nam a2200000 i 4500</leader>' "record label read into a MARC 21 leader"
assert_grep "$OUT/i2m.xml" '<subfield code="a">978-2-07-046987-1</subfield>' "020 ISBN carried"
assert_grep "$OUT/i2m.xml" 'tag="100" ind2=" " ind1="1"' "100 main personal heading, surname entry"
assert_grep "$OUT/i2m.xml" '<subfield code="4">aut</subfield>' "BnF function code 0070 becomes relator aut"
assert_grep "$OUT/i2m.xml" '<subfield code="4">edt</subfield>' "function code 0340 becomes relator edt"
assert_grep "$OUT/i2m.xml" 'tag="710" ind2=" " ind1="2"' "710 corporate heading in direct order"
assert_grep "$OUT/i2m.xml" 'tag="240"' "145 conventional title becomes 240"
assert_grep "$OUT/i2m.xml" '<subfield code="b">suivi des Illuminations</subfield>' "245e complément becomes 245b"
assert_grep "$OUT/i2m.xml" '<subfield code="c">Arthur Rimbaud ; édition présentée par Hélène Dubois</subfield>' "245f responsibility becomes 245c"
assert_grep "$OUT/i2m.xml" 'tag="264" ind1=" " ind2="1"' "260 bibliographic address becomes 264 publication"
assert_grep "$OUT/i2m.xml" '<subfield code="b">Gallimard</subfield>' "260c publisher becomes 264b"
assert_grep "$OUT/i2m.xml" '<subfield code="c">2023</subfield>' "260d date becomes 264c"
assert_grep "$OUT/i2m.xml" '<subfield code="a">1 vol. (172 p.)</subfield>' "280 physical description becomes 300"
assert_grep "$OUT/i2m.xml" 'tag="500"' "300 general note becomes 500"
assert_grep "$OUT/i2m.xml" 'tag="546"' "302 language note becomes 546"
assert_grep "$OUT/i2m.xml" 'tag="506"' "310 access-conditions note becomes 506"
assert_grep "$OUT/i2m.xml" 'tag="650" ind1=" " ind2="7"' "606 RAMEAU heading becomes 650 ind2 7"
assert_grep "$OUT/i2m.xml" '<subfield code="2">rameau</subfield>' "RAMEAU named as the subject source"
assert_grep "$OUT/i2m.xml" '<subfield code="a">Ardennes (France)</subfield>' "607 becomes 651"

echo "== round trip: INTERMARC -> MARC 21 -> INTERMARC =="
transform marc21-to-intermarc.xsl "$OUT/i2m.xml" m2i.xml "MARC 21 output converts back"
assert_grep "$OUT/m2i.xml" 'tag="280"' "300 becomes 280 again"
assert_grep "$OUT/m2i.xml" 'tag="145"' "240 becomes 145 again"
assert_grep "$OUT/m2i.xml" '<subfield code="4">0070</subfield>' "relator aut becomes function code 0070"
assert_grep "$OUT/m2i.xml" '<subfield code="e">suivi des Illuminations</subfield>' "245b becomes 245e again"
assert_grep "$OUT/m2i.xml" '<subfield code="d">2023</subfield>' "publication date returns to 260d"
assert_grep "$OUT/m2i.xml" 'tag="606"' "650 returns to 606"
assert_grep "$OUT/m2i.xml" '<subfield code="a">Rimbaud, Arthur</subfield>' "heading text survives the round trip"
assert_absent "$OUT/m2i.xml" '<subfield code="2">rameau</subfield>' "the RAMEAU source subfield is consumed on the way back"

echo "== JAPAN/MARC reading and parallel-script normalization =="
transform japanmarc-normalize.xsl "$DATA/japanmarc.xml" jm.xml "japanmarc.xml transforms"
assert_grep "$OUT/jm.xml" '<subfield code="6">880-01</subfield>' "100 gains the reciprocal linkage"
assert_grep "$OUT/jm.xml" '<subfield code="6">880-02</subfield>' "245 gains the reciprocal linkage"
assert_grep "$OUT/jm.xml" '<subfield code="6">100-01/\$1</subfield>' "kana reading of the name is numbered and given the CJK script code"
assert_grep "$OUT/jm.xml" '<subfield code="6">245-02/\$1</subfield>' "kana reading of the title numbered from the linked field"
assert_grep "$OUT/jm.xml" '<subfield code="6">245-02/(B</subfield>' "romaji reading shares the occurrence number, differs by script code"
assert_grep "$OUT/jm.xml" '<subfield code="6">500-00/\$1</subfield>' "the unpaired 880 keeps occurrence 00"
assert_grep "$OUT/jm.xml" '<subfield code="a">ワガハイ ワ ネコ デ アル /</subfield>' "reading content untouched"
assert_grep "$OUT/jm.xml" '<subfield code="a">吾輩は猫である /</subfield>' "kanji title untouched"
assert_grep "$OUT/jm.xml" '240601s2023    ja |||||||||||||||jpn d' "008 copied through unchanged"
assert_grep "$OUT/jm.xml" '<datafield tag="880" ind1="1" ind2=" ">' "880 repeats the linked field's indicators"
n_link=$(grep -c 'code="6"' "$OUT/jm.xml")
if [ "$n_link" = "6" ]; then ok "linkage subfield count (2 regular + 4 alternate-script)"; else bad "linkage subfield count ($n_link, expected 6)"; fi
assert_absent "$OUT/jm.xml" '<subfield code="6">880-03</subfield>' "no occurrence number is minted for an unpaired field"

echo "== IBERMARC -> MARC 21 (legacy migration) =="
transform ibermarc-to-marc21.xsl "$DATA/ibermarc.xml" ib.xml "ibermarc.xml transforms"
assert_grep "$OUT/ib.xml" '<leader>00000nam a2200000   4500</leader>' "leader lengths zeroed and UTF-8 declared in position 9"
assert_grep "$OUT/ib.xml" 'tag="016"' "017 becomes the MARC 21 016 agency control number"
assert_absent "$OUT/ib.xml" 'tag="017"' "017 does not survive as itself"
assert_grep "$OUT/ib.xml" '<subfield code="a">M 12345-1997</subfield>' "017a value carried into 016"
assert_grep "$OUT/ib.xml" 'tag="592"' "the 59X local block is kept, not dropped"
assert_grep "$OUT/ib.xml" '980612s1997    sp |||||||||||||||spa d' "008 copied through unchanged"
assert_grep "$OUT/ib.xml" '<subfield code="a">Muñoz Peña, José</subfield>' "Spanish diacritics preserved"
assert_grep "$OUT/ib.xml" 'tag="245" ind1="1" ind2="3"' "shared fields copied with their indicators"

echo "== MAB2 -> MARC 21 (legacy migration) =="
transform mab2-to-marc21.xsl "$DATA/mab2.xml" mab.xml "mab2.xml transforms"
assert_grep "$OUT/mab.xml" '<controlfield tag="001">DE-101-980765432</controlfield>' "MAB2 001 becomes the control number"
assert_grep "$OUT/mab.xml" '980312s1998    ||||||||||||||||||||||| d' "008 from 002 date entered and 425 publication year, nothing invented"
assert_grep "$OUT/mab.xml" '<subfield code="a">3-12-345678-9</subfield>' "540 ISBN becomes 020"
assert_grep "$OUT/mab.xml" '<subfield code="a">(DE-599)ZDB980765432</subfield>' "025 becomes 035"
assert_grep "$OUT/mab.xml" '<subfield code="a">Die Vögel der Ostsee</subfield>' "331 Hauptsachtitel becomes 245a (subfield-less field read from its text)"
assert_grep "$OUT/mab.xml" '<subfield code="b">ein Bestimmungsbuch</subfield>' "335 Zusatz becomes 245b"
assert_grep "$OUT/mab.xml" '<subfield code="c">Käthe Möller ; Ulrich Schröder</subfield>' "359 Verfasserangabe becomes 245c"
assert_grep "$OUT/mab.xml" '<subfield code="a">2., überarbeitete Auflage</subfield>' "403 becomes 250"
assert_grep "$OUT/mab.xml" 'tag="264" ind1=" " ind2="1"' "410/412/425 become a 264 publication statement"
assert_grep "$OUT/mab.xml" '<subfield code="b">Nordverlag</subfield>' "412 Verlag becomes 264b"
assert_grep "$OUT/mab.xml" '<subfield code="a">286 S.</subfield>' "433 Umfang becomes 300a"
assert_grep "$OUT/mab.xml" '<subfield code="v">Band 7</subfield>' "455 Bandangabe becomes 490v"
assert_grep "$OUT/mab.xml" '<subfield code="a">Literaturverzeichnis Seite 271-280</subfield>' "501 Fußnote becomes 500"
assert_grep "$OUT/mab.xml" 'tag="100" ind2=" " ind1="1"' "first Verfasser becomes the 100 main entry"
assert_grep "$OUT/mab.xml" '<subfield code="a">Schröder, Ulrich</subfield>' "second Verfasser becomes a 700 added entry"
assert_grep "$OUT/mab.xml" 'tag="710" ind1="2"' "Körperschaft becomes a 710 added entry"
assert_grep "$OUT/mab.xml" '<subfield code="2">swd</subfield>' "Schlagwörter labelled with their subject authority"
n_650=$(grep -c 'tag="650"' "$OUT/mab.xml")
if [ "$n_650" = "2" ]; then ok "each Schlagwort of the chain becomes its own 650"; else bad "650 count ($n_650, expected 2)"; fi
assert_grep "$OUT/mab.xml" '<subfield code="a">598.2943</subfield>' "700 Notation becomes 084"

echo "== MARCXML -> ONIX 3.x =="
transform marcxml-to-onix3.xsl "$DATA/bib.xml" onix.xml "bib.xml transforms"
assert_grep "$OUT/onix.xml" '<ONIXMessage xmlns="http://ns.editeur.org/onix/3.0/reference" release="3.0">' "ONIX 3.0 reference message root"
assert_grep "$OUT/onix.xml" '<ProductIDType>15</ProductIDType>' "ProductIDType 15 (ISBN-13)"
assert_grep "$OUT/onix.xml" '<IDValue>9780306406157</IDValue>' "ISBN-10 upconverted with correct check digit"
assert_grep "$OUT/onix.xml" '<ProductForm>BA</ProductForm>' "book maps to ProductForm BA"
assert_grep "$OUT/onix.xml" '<ProductForm>AC</ProductForm>' "CD audio (leader j + 007 sd) maps to AC"
assert_grep "$OUT/onix.xml" '<ProductForm>VA</ProductForm>' "video (leader g) maps to VA"
assert_grep "$OUT/onix.xml" '<TitleText>Les canards du Saint-Laurent</TitleText>' "TitleText from 245a"
assert_grep "$OUT/onix.xml" "<Subtitle>guide d'observation</Subtitle>" "Subtitle from 245b"
assert_grep "$OUT/onix.xml" '<ContributorRole>A01</ContributorRole>' "aut maps to A01"
assert_grep "$OUT/onix.xml" '<ContributorRole>B06</ContributorRole>' "trl maps to B06"
assert_grep "$OUT/onix.xml" '<ContributorRole>A06</ContributorRole>' "cmp maps to A06"
assert_grep "$OUT/onix.xml" '<PersonNameInverted>Côté, Amélie</PersonNameInverted>' "inverted personal name"
assert_grep "$OUT/onix.xml" '<LanguageCode>fre</LanguageCode>' "language from 041"
assert_grep "$OUT/onix.xml" '<ExtentValue>214</ExtentValue>' "page count from 300a"
assert_grep "$OUT/onix.xml" '<ExtentUnit>03</ExtentUnit>' "extent unit pages"
assert_grep "$OUT/onix.xml" '<SubjectSchemeIdentifier>04</SubjectSchemeIdentifier>' "LCSH scheme 04"
assert_grep "$OUT/onix.xml" '<SubjectHeadingText>Ducks--Québec (Province)--21st century</SubjectHeadingText>' "LCSH heading with subdivisions"
assert_grep "$OUT/onix.xml" '<SubjectSchemeIdentifier>01</SubjectSchemeIdentifier>' "Dewey scheme 01"
assert_grep "$OUT/onix.xml" '<SubjectCode>598.41</SubjectCode>' "Dewey code from 082"
assert_grep "$OUT/onix.xml" '<SubjectSchemeIdentifier>03</SubjectSchemeIdentifier>' "LC classification scheme 03"
assert_grep "$OUT/onix.xml" '<PublisherName>Éditions du Lac</PublisherName>' "publisher from 264b"
assert_grep "$OUT/onix.xml" '<Date dateformat="05">2021</Date>' "publishing year from 008/07-10"
assert_grep "$OUT/onix.xml" '<IDTypeName>control number</IDTypeName>' "ISBN-less record falls back to proprietary id"

echo "== MARCXML -> EDM =="
transform marcxml-to-edm.xsl "$DATA/bib.xml" edm.xml "bib.xml transforms" \
    --stringparam data-provider "Duck Library" \
    --stringparam provider "Duck Aggregator" \
    --stringparam rights "http://creativecommons.org/publicdomain/zero/1.0/"
assert_grep "$OUT/edm.xml" 'edm:ProvidedCHO rdf:about="urn:marc:intl-bib-0001"' "ProvidedCHO minted from 001"
assert_grep "$OUT/edm.xml" '<edm:type>TEXT</edm:type>' "leader a maps to edm:type TEXT"
assert_grep "$OUT/edm.xml" '<edm:type>SOUND</edm:type>' "leader j maps to edm:type SOUND"
assert_grep "$OUT/edm.xml" '<edm:type>VIDEO</edm:type>' "leader g maps to edm:type VIDEO"
assert_grep "$OUT/edm.xml" '<dc:title>Les canards du Saint-Laurent : guide d' "dc:title with subtitle"
assert_grep "$OUT/edm.xml" '<dc:creator>Côté, Amélie</dc:creator>' "dc:creator from 100"
assert_grep "$OUT/edm.xml" '<dc:language>fre</dc:language>' "dc:language from 008"
assert_grep "$OUT/edm.xml" '<dcterms:issued>2021</dcterms:issued>' "dcterms:issued from 264c"
assert_grep "$OUT/edm.xml" '<dc:subject>Ducks--Québec (Province)--21st century</dc:subject>' "dc:subject with subdivisions"
assert_grep "$OUT/edm.xml" '<dcterms:isPartOf>Faune du Québec</dcterms:isPartOf>' "series as isPartOf"
assert_grep "$OUT/edm.xml" 'ore:Aggregation rdf:about="urn:marc:intl-bib-0001#aggregation"' "Aggregation per record"
assert_grep "$OUT/edm.xml" '<edm:dataProvider>Duck Library</edm:dataProvider>' "edm:dataProvider parameter"
assert_grep "$OUT/edm.xml" '<edm:provider>Duck Aggregator</edm:provider>' "edm:provider parameter"
assert_grep "$OUT/edm.xml" 'edm:isShownAt rdf:resource="https://example.org/canards"' "edm:isShownAt from 856u"
assert_grep "$OUT/edm.xml" 'edm:rights rdf:resource="http://creativecommons.org/publicdomain/zero/1.0/"' "edm:rights parameter"

echo "== MARCXML (authority) -> MADS =="
transform marcxml-to-mads.xsl "$DATA/auth.xml" mads.xml "auth.xml transforms"
assert_grep "$OUT/mads.xml" '<mads:madsCollection' "collection wrapper"
assert_grep "$OUT/mads.xml" '<mads:namePart>Côté, Amélie</mads:namePart>' "100 authority name"
assert_grep "$OUT/mads.xml" '<mads:namePart type="date">1975-</mads:namePart>' "100d date namePart"
assert_grep "$OUT/mads.xml" '<mads:namePart>Cote, Amelie</mads:namePart>' "400 see-from becomes variant"
assert_grep "$OUT/mads.xml" '<mads:namePart>Côté-Bélanger, Amélie</mads:namePart>' "second 400 variant"
n_variants=$(grep -c '<mads:variant' "$OUT/mads.xml")
if [ "$n_variants" = "3" ]; then ok "variant count across both records"; else bad "variant count ($n_variants, expected 3)"; fi
assert_grep "$OUT/mads.xml" '<mads:related type="other">' "500 see-also becomes related"
assert_grep "$OUT/mads.xml" '<mads:note>Do not confuse with Côté, Amélie, 1948-</mads:note>' "667 becomes note"
assert_grep "$OUT/mads.xml" '<mads:note type="source">Les canards du Saint-Laurent, 2021: title page (Amélie Côté)</mads:note>' "670 becomes source note"
assert_grep "$OUT/mads.xml" '<mads:identifier type="lccn">n 2024000001</mads:identifier>' "010 becomes lccn identifier"
assert_grep "$OUT/mads.xml" '<mads:identifier type="local">intl-auth-0001</mads:identifier>' "001 becomes local identifier"
assert_grep "$OUT/mads.xml" '<mads:topic>Ducks</mads:topic>' "150 becomes topic authority"
assert_grep "$OUT/mads.xml" '<mads:topic>Wild ducks</mads:topic>' "450 becomes topic variant"
assert_grep "$OUT/mads.xml" '<mads:related type="broader">' "550 \$w g becomes broader related"
assert_grep "$OUT/mads.xml" '<mads:geographic>Saint Lawrence River</mads:geographic>' "551 becomes geographic related"

echo
echo "$checks checks, $fails failures"
[ "$fails" -eq 0 ] || exit 1
exit 0
