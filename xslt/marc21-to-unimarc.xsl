<?xml version="1.0" encoding="UTF-8"?>
<!--
  marc21-to-unimarc.xsl - MARC 21 Bibliographic to UNIMARC Bibliographic,
  field level.

  Original crosswalk for the duckdb-marc21 project, written from the IFLA
  "UNIMARC Manual: Bibliographic Format" (3rd edition updated, IFLA,
  https://www.ifla.org/publications/unimarc-formats-and-related-documentation/)
  and the IFLA/Library of Congress alignment documentation ("MARC 21 to
  UNIMARC Conversion Specifications", LC Network Development and MARC
  Standards Office). IFLA publications are licensed CC BY 4.0; this
  stylesheet references their specifications and copies nothing from them.
  Attribution: "UNIMARC Manual: Bibliographic Format, IFLA, CC BY 4.0".

  CONTAINER. Input and output both use the MARC 21 slim XML container
  (namespace http://www.loc.gov/MARC21/slim), the shape the UNIMARC
  community reuses for UNIMARC/XML and the shape this extension's
  read_marcxml / COPY (FORMAT marcxml) speak. Accepts a bare record or a
  collection.

  DELTA LAYERS. The record body is emitted by named block templates -
  mu2-label, mu2-identifiers, mu2-coded, mu2-description, mu2-notes,
  mu2-linking-block, mu2-subjects, mu2-classification, mu2-responsibility,
  mu2-source, mu2-electronic - plus an empty mu2-national hook called last.
  A stylesheet for a UNIMARC-derived national format imports this one
  (xsl:import, not xsl:include: XSLT 1.0 gives the importing sheet the higher
  precedence that overriding requires, while two same-named templates at
  equal precedence would be an error) and redefines only the blocks it must
  change.

  COVERAGE (MARC 21 -> UNIMARC):
    leader       -> record label (positions 5-9, 17-19 remapped; leader/8
                    hierarchical level set to 0, entry map 450 )
    001, 005     copied
    020          -> 010 ($a->$a, $q->$b, $c->$d, $z->$z)
    022          -> 011 ($a->$a, $y incorrect->$z erroneous,
                    $z canceled->$y cancelled)
    008          -> 100 $a (36 positions: date entered /00-05 -> /0-7 with
                    the century inferred, 50->19xx pivot; type of date /06
                    remapped; dates /07-14 -> /9-16; target audience /22
                    remapped to /17; government publication /28 -> /20;
                    modified record /38 -> /21; language of cataloguing
                    /22-24 from 040 $b, 'und' when absent; transliteration
                    /25 = y; character sets /26-29 = '50  ' [UCS - this
                    pipeline is UTF-8]; /30-35 blank)
    008/15-17    -> 102 $a (MARC country code to ISO 3166 alpha-2 via a
                    common-country table; unmatched codes drop the 102)
    041 + 008/35-37 -> 101 ($a->$a [008 language when no 041], $h orig->$c,
                    $b summary->$d, $e libretto->$h, $j->$j; 041 ind1 1 ->
                    101 ind1 1 [translation])
    245          -> 200 ($a->$a, $b->$e, $c->$f, $h GMD->$b, $n->$h,
                    $p->$i; ind1 -> ind1 title significance; nonfiling
                    ind2 is LOST - UNIMARC uses NSB/NSE characters, which
                    are not generated)
    250          -> 205 ($a->$a, $b->$f)
    260          -> 210 ($a->$a, $b->$c, $c->$d, $e->$e, $f->$g, $g->$h)
    264          -> 214 (ind2 1 publication->_0, 0 production->_1,
                    2->_2, 3->_3, 4->_4; $a->$a, $b->$c, $c->$d)
    300          -> 215 ($a->$a, $b->$c, $c->$d, $e->$e)
    490          -> 225 ($a->$a, $v->$v, $x->$x; ind1 = 1, series-tracing
                    practice does not translate)
    500 -> 300, 502 -> 328, 504 -> 320, 505 -> 327, 520 -> 330
    76X-78X      -> 4XX (standard-subfield technique, $a/$t/$x only:
                    765->454, 767->453, 770->421, 772->422, 773->461,
                    775->451, 776->452, 780->430, 785->440, 787->488;
                    the embedded-field $1 technique is NOT generated)
    600 -> 600, 610 -> 601 (ind1 0), 611 -> 601 (ind1 1), 650 -> 606,
    651 -> 607   (MARC $z geographic -> UNIMARC $y and $y chronological ->
                    $z - the codes swap; ind2 0/1 -> $2 lc, 2 -> $2 mesh,
                    7 -> $2 copied)
    080 -> 675, 082 -> 676 ($2 edition->$v), 050 -> 680
    100 -> 700, 700 -> 702 (secondary responsibility - MARC 21 added
                    entries carry no primary/alternative distinction);
                    personal names: when ind1 = 1 (surname), $a splits at
                    the first ', ' into entry element $a + other part $b;
                    $b numeration->$d, $c->$c, $d dates->$f; MARC relator
                    $4 -> numeric UNIMARC code (aut 070, ctb 205, com 220,
                    cmp 230, edt 340, ill 440, pht 600, trl 730)
    110 -> 710 (ind1 0), 111 -> 710 (ind1 1), 710 -> 712 (ind1 0),
    711 -> 712 (ind1 1) (X10 ind1 entry form -> ind2)
    040          -> 801 (one 801 per role: $a -> ind2 0, $c -> ind2 1,
                    $d -> ind2 2; agency in $b, $e conventions -> $g)
    856          -> 856 (indicators and subfields copied verbatim)

  LOSSES AND EXCLUSIONS (deliberate):
    * 245 nonfiling indicator (NSB/NSE not generated), 130/240 uniform
      titles, 76X-78X beyond $a/$t/$x, 6XX $v form subdivisions (UNIMARC
      uses $j; not mapped), 33X RDA fields, 5XX notes beyond those listed,
      8XX series added entries, 88X are dropped.
    * 008 positions 18-21, 23-27, 29-37 (illustrations, form, contents,
      festschrift, index, literary form, biography) are not converted.
    * $e textual relator terms are dropped (only $4 codes map).
  XSLT 1.0 (xsltproc-friendly).
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    xmlns="http://www.loc.gov/MARC21/slim"
    exclude-result-prefixes="marc">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <!-- MARC country code -> ISO 3166 alpha-2, '|marc:ISO|' pairs -->
  <xsl:variable name="marc2iso"
    >|fr :FR|gw :DE|it :IT|sp :ES|po :PT|ne :NL|be :BE|sz :CH|au :AT|ja :JP|cc :CN|ru :RU|xxu:US|xxk:GB|xxc:CA|at :AU|dk :DK|sw :SE|no :NO|fi :FI|pl :PL|gr :GR|tu :TR|ko :KR|bl :BR|mx :MX|ie :IE|xr :CZ|hu :HU|</xsl:variable>

  <xsl:template match="/marc:collection">
    <collection>
      <xsl:apply-templates select="marc:record"/>
    </collection>
  </xsl:template>

  <xsl:template name="mu2-chomp">
    <xsl:param name="s"/>
    <xsl:variable name="t" select="normalize-space($s)"/>
    <xsl:variable name="n" select="string-length($t)"/>
    <xsl:choose>
      <xsl:when test="$n = 0"/>
      <xsl:when test="contains(',;:/=', substring($t, $n, 1))
                      or (substring($t, $n, 1) = '.'
                          and not(substring($t, $n - 1, 1) = '.'))">
        <xsl:call-template name="mu2-chomp">
          <xsl:with-param name="s" select="substring($t, 1, $n - 1)"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$t"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- MARC relator code -> numeric UNIMARC code (empty = unmapped) -->
  <xsl:template name="mu2-relator">
    <xsl:param name="code"/>
    <xsl:choose>
      <xsl:when test="$code = 'aut'">070</xsl:when>
      <xsl:when test="$code = 'ctb'">205</xsl:when>
      <xsl:when test="$code = 'com'">220</xsl:when>
      <xsl:when test="$code = 'cmp'">230</xsl:when>
      <xsl:when test="$code = 'edt'">340</xsl:when>
      <xsl:when test="$code = 'ill'">440</xsl:when>
      <xsl:when test="$code = 'pht'">600</xsl:when>
      <xsl:when test="$code = 'trl'">730</xsl:when>
    </xsl:choose>
  </xsl:template>

  <!-- personal name body: split 'Entry, Other' when entered under surname -->
  <xsl:template name="mu2-person">
    <xsl:variable name="a">
      <xsl:call-template name="mu2-chomp">
        <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:choose>
      <xsl:when test="@ind1 = '1' and contains($a, ', ')">
        <subfield code="a"><xsl:value-of select="substring-before($a, ', ')"/></subfield>
        <subfield code="b"><xsl:value-of select="substring-after($a, ', ')"/></subfield>
      </xsl:when>
      <xsl:otherwise>
        <subfield code="a"><xsl:value-of select="$a"/></subfield>
      </xsl:otherwise>
    </xsl:choose>
    <xsl:for-each select="marc:subfield[@code='b']">
      <subfield code="d"><xsl:value-of select="normalize-space(.)"/></subfield>
    </xsl:for-each>
    <xsl:for-each select="marc:subfield[@code='c']">
      <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
    </xsl:for-each>
    <xsl:for-each select="marc:subfield[@code='d']">
      <subfield code="f">
        <xsl:call-template name="mu2-chomp">
          <xsl:with-param name="s" select="."/>
        </xsl:call-template>
      </subfield>
    </xsl:for-each>
    <xsl:for-each select="marc:subfield[@code='4']">
      <xsl:variable name="rel">
        <xsl:call-template name="mu2-relator">
          <xsl:with-param name="code" select="normalize-space(.)"/>
        </xsl:call-template>
      </xsl:variable>
      <xsl:if test="$rel != ''">
        <subfield code="4"><xsl:value-of select="$rel"/></subfield>
      </xsl:if>
    </xsl:for-each>
  </xsl:template>

  <!-- MARC 6XX subdivisions -> UNIMARC (the $y/$z swap) + $2 source -->
  <xsl:template name="mu2-subject-tail">
    <xsl:for-each select="marc:subfield[@code='x']">
      <subfield code="x"><xsl:value-of select="normalize-space(.)"/></subfield>
    </xsl:for-each>
    <xsl:for-each select="marc:subfield[@code='z']">
      <subfield code="y"><xsl:value-of select="normalize-space(.)"/></subfield>
    </xsl:for-each>
    <xsl:for-each select="marc:subfield[@code='y']">
      <subfield code="z">
        <xsl:call-template name="mu2-chomp">
          <xsl:with-param name="s" select="."/>
        </xsl:call-template>
      </subfield>
    </xsl:for-each>
    <xsl:choose>
      <xsl:when test="@ind2 = '0' or @ind2 = '1'">
        <subfield code="2">lc</subfield>
      </xsl:when>
      <xsl:when test="@ind2 = '2'">
        <subfield code="2">mesh</subfield>
      </xsl:when>
      <xsl:when test="@ind2 = '7' and marc:subfield[@code='2']">
        <subfield code="2"><xsl:value-of select="normalize-space(marc:subfield[@code='2'][1])"/></subfield>
      </xsl:when>
    </xsl:choose>
  </xsl:template>

  <!-- one 4XX linking field, standard-subfield technique -->
  <xsl:template name="mu2-linking">
    <xsl:param name="tag"/>
    <datafield tag="{$tag}" ind1=" " ind2="0">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='t']">
        <subfield code="t"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='x']">
        <subfield code="x"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:template>

  <!-- Entry point.  The record body is split into named block templates so
       that a national delta layer (a UNIMARC-derived format such as RUSMARC)
       can xsl:import this stylesheet and override or extend one block without
       restating the rest.  Every block template runs with the source record
       element as its context node. -->
  <xsl:template match="/marc:record | marc:record">
    <xsl:call-template name="mu2-record"/>
  </xsl:template>

  <xsl:template name="mu2-record">
    <record>
      <xsl:call-template name="mu2-label"/>
      <xsl:call-template name="mu2-identifiers"/>
      <xsl:call-template name="mu2-coded"/>
      <xsl:call-template name="mu2-description"/>
      <xsl:call-template name="mu2-notes"/>
      <xsl:call-template name="mu2-linking-block"/>
      <xsl:call-template name="mu2-subjects"/>
      <xsl:call-template name="mu2-classification"/>
      <xsl:call-template name="mu2-responsibility"/>
      <xsl:call-template name="mu2-source"/>
      <xsl:call-template name="mu2-electronic"/>
      <xsl:call-template name="mu2-national"/>
    </record>
  </xsl:template>

  <!-- Extension hook: empty here.  A national delta layer overrides it to
       emit the fields this stylesheet has no mapping for. -->
  <xsl:template name="mu2-national"/>

  <xsl:template name="mu2-label">
    <xsl:variable name="ldr" select="marc:leader"/>
  <!-- ============ MARC 21 leader -> UNIMARC record label ========= -->
  <leader>
    <xsl:text>00000</xsl:text>
    <!-- /5 status: a (increase in encoding level) -> c -->
    <xsl:variable name="st" select="substring($ldr, 6, 1)"/>
    <xsl:choose>
      <xsl:when test="contains('cdnp', $st) and $st != ''"><xsl:value-of select="$st"/></xsl:when>
      <xsl:when test="$st = 'a'">c</xsl:when>
      <xsl:otherwise>n</xsl:otherwise>
    </xsl:choose>
    <!-- /6 type of record: t->b, m->l, o->m (kit), p (mixed) -> a -->
    <xsl:variable name="ty" select="substring($ldr, 7, 1)"/>
    <xsl:choose>
      <xsl:when test="$ty = 't'">b</xsl:when>
      <xsl:when test="$ty = 'm'">l</xsl:when>
      <xsl:when test="$ty = 'o'">m</xsl:when>
      <xsl:when test="$ty = 'p'">a</xsl:when>
      <xsl:when test="contains('acdefgijkr', $ty) and $ty != ''"><xsl:value-of select="$ty"/></xsl:when>
      <xsl:otherwise>a</xsl:otherwise>
    </xsl:choose>
    <!-- /7 bibliographic level: b (serial component) -> a, d (subunit) -> m -->
    <xsl:variable name="bl" select="substring($ldr, 8, 1)"/>
    <xsl:choose>
      <xsl:when test="$bl = 'b'">a</xsl:when>
      <xsl:when test="$bl = 'd'">m</xsl:when>
      <xsl:when test="contains('acims', $bl) and $bl != ''"><xsl:value-of select="$bl"/></xsl:when>
      <xsl:otherwise>m</xsl:otherwise>
    </xsl:choose>
    <!-- /8 hierarchical level = 0 (no hierarchy expressed), /9 undefined -->
    <xsl:text>0 22</xsl:text>
    <xsl:text>00000</xsl:text>
    <!-- /17 encoding level: 8 (CIP) -> 1, 3/5 -> 3, full-ish -> blank -->
    <xsl:variable name="el" select="substring($ldr, 18, 1)"/>
    <xsl:choose>
      <xsl:when test="$el = '8'">1</xsl:when>
      <xsl:when test="$el = '3' or $el = '5'">3</xsl:when>
      <xsl:when test="$el = ' ' or $el = '1' or $el = '4' or $el = ''"><xsl:text> </xsl:text></xsl:when>
      <xsl:otherwise>2</xsl:otherwise>
    </xsl:choose>
    <!-- /18 descriptive cataloguing form: a/i (ISBD or AACR2) -> blank
         = full ISBD, c (ISBD punctuation omitted) -> i, non-ISBD -> n -->
    <xsl:variable name="cf" select="substring($ldr, 19, 1)"/>
    <xsl:choose>
      <xsl:when test="$cf = 'a' or $cf = 'i' or $cf = 'u'"><xsl:text> </xsl:text></xsl:when>
      <xsl:when test="$cf = 'c'">i</xsl:when>
      <xsl:otherwise>n</xsl:otherwise>
    </xsl:choose>
    <!-- /19 undefined, /20-23 entry map -->
    <xsl:text> 450 </xsl:text>
  </leader>

  <xsl:for-each select="marc:controlfield[@tag='001']">
    <controlfield tag="001"><xsl:value-of select="."/></controlfield>
  </xsl:for-each>
  <xsl:for-each select="marc:controlfield[@tag='005']">
    <controlfield tag="005"><xsl:value-of select="."/></controlfield>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="mu2-identifiers">
  <!-- 010 from 020 -->
  <xsl:for-each select="marc:datafield[@tag='020']">
    <datafield tag="010" ind1=" " ind2=" ">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='q']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='c']">
        <subfield code="d"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='z']">
        <subfield code="z"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  <!-- 011 from 022 -->
  <xsl:for-each select="marc:datafield[@tag='022']">
    <datafield tag="011" ind1=" " ind2=" ">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='y']">
        <subfield code="z"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='z']">
        <subfield code="y"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="mu2-coded">
    <xsl:variable name="f008" select="marc:controlfield[@tag='008'][1]"/>
  <!-- 100 general processing data from 008 + 040 $b -->
  <datafield tag="100" ind1=" " ind2=" ">
    <subfield code="a">
      <!-- /0-7 date entered YYYYMMDD (century pivot: 50 -> 19xx) -->
      <xsl:variable name="yy" select="substring($f008, 1, 2)"/>
      <xsl:choose>
        <xsl:when test="string-length(translate($yy, '0123456789', '')) = 0
                        and string-length($yy) = 2">
          <xsl:choose>
            <xsl:when test="number($yy) &gt;= 50">19</xsl:when>
            <xsl:otherwise>20</xsl:otherwise>
          </xsl:choose>
          <xsl:value-of select="substring($f008, 1, 6)"/>
        </xsl:when>
        <xsl:otherwise><xsl:text>        </xsl:text></xsl:otherwise>
      </xsl:choose>
      <!-- /8 type of publication date -->
      <xsl:variable name="td" select="substring($f008, 7, 1)"/>
      <xsl:choose>
        <xsl:when test="$td = 'c'">a</xsl:when>
        <xsl:when test="$td = 'd'">b</xsl:when>
        <xsl:when test="$td = 'u'">c</xsl:when>
        <xsl:when test="$td = 's'">d</xsl:when>
        <xsl:when test="$td = 'r'">e</xsl:when>
        <xsl:when test="$td = 'p'">e</xsl:when>
        <xsl:when test="$td = 'q'">f</xsl:when>
        <xsl:when test="$td = 'm'">g</xsl:when>
        <xsl:when test="$td = 'i'">g</xsl:when>
        <xsl:when test="$td = 'k'">g</xsl:when>
        <xsl:when test="$td = 't'">h</xsl:when>
        <xsl:when test="$td = 'e'">j</xsl:when>
        <xsl:when test="$td = 'n'">u</xsl:when>
        <xsl:when test="$td = 'b'">u</xsl:when>
        <xsl:otherwise>u</xsl:otherwise>
      </xsl:choose>
      <!-- /9-16 dates (fill characters become blanks) -->
      <xsl:value-of select="translate(substring($f008, 8, 8), '|', ' ')"/>
      <!-- /17-19 target audience from 008/22 -->
      <xsl:variable name="ta" select="substring($f008, 23, 1)"/>
      <xsl:choose>
        <xsl:when test="$ta = 'a'">b</xsl:when>
        <xsl:when test="$ta = 'b'">c</xsl:when>
        <xsl:when test="$ta = 'c'">d</xsl:when>
        <xsl:when test="$ta = 'd'">e</xsl:when>
        <xsl:when test="$ta = 'e'">m</xsl:when>
        <xsl:when test="$ta = 'f'">k</xsl:when>
        <xsl:when test="$ta = 'g'">m</xsl:when>
        <xsl:when test="$ta = 'j'">a</xsl:when>
        <xsl:otherwise>u</xsl:otherwise>
      </xsl:choose>
      <xsl:text>  </xsl:text>
      <!-- /20 government publication from 008/28 -->
      <xsl:variable name="gp" select="substring($f008, 29, 1)"/>
      <xsl:choose>
        <xsl:when test="$gp = 'f'">a</xsl:when>
        <xsl:when test="$gp = 's'">b</xsl:when>
        <xsl:when test="$gp = 'l'">d</xsl:when>
        <xsl:when test="$gp = 'i'">h</xsl:when>
        <xsl:when test="$gp = ' ' or $gp = ''">y</xsl:when>
        <xsl:when test="$gp = 'u' or $gp = 'o' or $gp = '|'">u</xsl:when>
        <xsl:otherwise>z</xsl:otherwise>
      </xsl:choose>
      <!-- /21 modified record from 008/38 -->
      <xsl:choose>
        <xsl:when test="substring($f008, 39, 1) = ' '
                        or substring($f008, 39, 1) = ''
                        or substring($f008, 39, 1) = '|'">0</xsl:when>
        <xsl:otherwise>1</xsl:otherwise>
      </xsl:choose>
      <!-- /22-24 language of cataloguing from 040 $b -->
      <xsl:variable name="lc"
          select="normalize-space(marc:datafield[@tag='040'][1]/marc:subfield[@code='b'][1])"/>
      <xsl:choose>
        <xsl:when test="string-length($lc) = 3"><xsl:value-of select="$lc"/></xsl:when>
        <xsl:otherwise>und</xsl:otherwise>
      </xsl:choose>
      <!-- /25 transliteration, /26-29 character sets (UCS), /30-35 -->
      <xsl:text>y50        </xsl:text>
    </subfield>
  </datafield>

  <!-- 101 language(s): 041 when present, else 008/35-37 -->
  <xsl:choose>
    <xsl:when test="marc:datafield[@tag='041']">
      <xsl:for-each select="marc:datafield[@tag='041'][1]">
        <datafield tag="101" ind2=" ">
          <xsl:attribute name="ind1">
            <xsl:choose>
              <xsl:when test="@ind1 = '1'">1</xsl:when>
              <xsl:otherwise>0</xsl:otherwise>
            </xsl:choose>
          </xsl:attribute>
          <xsl:for-each select="marc:subfield[@code='a']">
            <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='h']">
            <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='b']">
            <subfield code="d"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='e']">
            <subfield code="h"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='j']">
            <subfield code="j"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
        </datafield>
      </xsl:for-each>
    </xsl:when>
    <xsl:when test="string-length(normalize-space(substring($f008, 36, 3))) = 3
                    and substring($f008, 36, 3) != '|||'">
      <datafield tag="101" ind1="0" ind2=" ">
        <subfield code="a"><xsl:value-of select="substring($f008, 36, 3)"/></subfield>
      </datafield>
    </xsl:when>
  </xsl:choose>

  <!-- 102 country from 008/15-17 -->
  <xsl:variable name="cc" select="substring($f008, 16, 3)"/>
  <xsl:variable name="iso"
      select="substring(substring-after($marc2iso, concat('|', $cc, ':')), 1, 2)"/>
  <xsl:if test="$iso != ''">
    <datafield tag="102" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="$iso"/></subfield>
    </datafield>
  </xsl:if>

  </xsl:template>

  <xsl:template name="mu2-description">
  <!-- 200 from 245 -->
  <xsl:for-each select="marc:datafield[@tag='245'][1]">
    <datafield tag="200" ind2=" ">
      <xsl:attribute name="ind1">
        <xsl:choose>
          <xsl:when test="@ind1 = '0'">0</xsl:when>
          <xsl:otherwise>1</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <subfield code="a">
        <xsl:call-template name="mu2-chomp">
          <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
        </xsl:call-template>
      </subfield>
      <xsl:for-each select="marc:subfield[@code='h']">
        <subfield code="b">
          <xsl:call-template name="mu2-chomp">
            <xsl:with-param name="s" select="translate(., '[]', '')"/>
          </xsl:call-template>
        </subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="e">
          <xsl:call-template name="mu2-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='n']">
        <subfield code="h"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='p']">
        <subfield code="i"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='c']">
        <subfield code="f">
          <xsl:call-template name="mu2-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  <!-- 205 from 250 -->
  <xsl:for-each select="marc:datafield[@tag='250']">
    <datafield tag="205" ind1=" " ind2=" ">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a">
          <xsl:call-template name="mu2-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="f"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  <!-- 210 from 260 -->
  <xsl:for-each select="marc:datafield[@tag='260']">
    <datafield tag="210" ind1=" " ind2=" ">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a">
          <xsl:call-template name="mu2-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="c">
          <xsl:call-template name="mu2-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='c']">
        <subfield code="d">
          <xsl:call-template name="mu2-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='e']">
        <subfield code="e"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='f']">
        <subfield code="g"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='g']">
        <subfield code="h"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  <!-- 214 from 264 (function indicator remapped) -->
  <xsl:for-each select="marc:datafield[@tag='264']">
    <datafield tag="214" ind1=" ">
      <xsl:attribute name="ind2">
        <xsl:choose>
          <xsl:when test="@ind2 = '0'">1</xsl:when>
          <xsl:when test="@ind2 = '2'">2</xsl:when>
          <xsl:when test="@ind2 = '3'">3</xsl:when>
          <xsl:when test="@ind2 = '4'">4</xsl:when>
          <xsl:otherwise>0</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a">
          <xsl:call-template name="mu2-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="c">
          <xsl:call-template name="mu2-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='c']">
        <subfield code="d">
          <xsl:call-template name="mu2-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  <!-- 215 from 300 -->
  <xsl:for-each select="marc:datafield[@tag='300']">
    <datafield tag="215" ind1=" " ind2=" ">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a">
          <xsl:call-template name="mu2-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="c">
          <xsl:call-template name="mu2-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='c']">
        <subfield code="d">
          <xsl:call-template name="mu2-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='e']">
        <subfield code="e"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  <!-- 225 from 490 -->
  <xsl:for-each select="marc:datafield[@tag='490']">
    <datafield tag="225" ind1="1" ind2=" ">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a">
          <xsl:call-template name="mu2-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='x']">
        <subfield code="x"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='v']">
        <subfield code="v"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="mu2-notes">
  <!-- notes -->
  <xsl:for-each select="marc:datafield[@tag='500']">
    <datafield tag="300" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/></subfield>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='504']">
    <datafield tag="320" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/></subfield>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='505']">
    <datafield tag="327" ind1="1" ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/></subfield>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='502']">
    <datafield tag="328" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/></subfield>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='520']">
    <datafield tag="330" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/></subfield>
    </datafield>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="mu2-linking-block">
  <!-- 4XX from 76X-78X (standard-subfield technique) -->
  <xsl:for-each select="marc:datafield[@tag='765']">
    <xsl:call-template name="mu2-linking"><xsl:with-param name="tag" select="'454'"/></xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='767']">
    <xsl:call-template name="mu2-linking"><xsl:with-param name="tag" select="'453'"/></xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='770']">
    <xsl:call-template name="mu2-linking"><xsl:with-param name="tag" select="'421'"/></xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='772']">
    <xsl:call-template name="mu2-linking"><xsl:with-param name="tag" select="'422'"/></xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='773']">
    <xsl:call-template name="mu2-linking"><xsl:with-param name="tag" select="'461'"/></xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='775']">
    <xsl:call-template name="mu2-linking"><xsl:with-param name="tag" select="'451'"/></xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='776']">
    <xsl:call-template name="mu2-linking"><xsl:with-param name="tag" select="'452'"/></xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='780']">
    <xsl:call-template name="mu2-linking"><xsl:with-param name="tag" select="'430'"/></xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='785']">
    <xsl:call-template name="mu2-linking"><xsl:with-param name="tag" select="'440'"/></xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='787']">
    <xsl:call-template name="mu2-linking"><xsl:with-param name="tag" select="'488'"/></xsl:call-template>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="mu2-subjects">
  <!-- subjects -->
  <xsl:for-each select="marc:datafield[@tag='600']">
    <datafield tag="600" ind1=" ">
      <xsl:attribute name="ind2">
        <xsl:choose>
          <xsl:when test="@ind1 = '0'">0</xsl:when>
          <xsl:otherwise>1</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <xsl:call-template name="mu2-person"/>
      <xsl:call-template name="mu2-subject-tail"/>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='610' or @tag='611']">
    <datafield tag="601">
      <xsl:attribute name="ind1">
        <xsl:choose>
          <xsl:when test="@tag = '611'">1</xsl:when>
          <xsl:otherwise>0</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <xsl:attribute name="ind2">
        <xsl:choose>
          <xsl:when test="@ind1 = '0'">0</xsl:when>
          <xsl:when test="@ind1 = '1'">1</xsl:when>
          <xsl:otherwise>2</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <subfield code="a">
        <xsl:call-template name="mu2-chomp">
          <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
        </xsl:call-template>
      </subfield>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:call-template name="mu2-subject-tail"/>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='650']">
    <datafield tag="606" ind1=" " ind2=" ">
      <subfield code="a">
        <xsl:call-template name="mu2-chomp">
          <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
        </xsl:call-template>
      </subfield>
      <xsl:call-template name="mu2-subject-tail"/>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='651']">
    <datafield tag="607" ind1=" " ind2=" ">
      <subfield code="a">
        <xsl:call-template name="mu2-chomp">
          <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
        </xsl:call-template>
      </subfield>
      <xsl:call-template name="mu2-subject-tail"/>
    </datafield>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="mu2-classification">
  <!-- classifications: 080 -> 675, 082 -> 676, 050 -> 680 -->
  <xsl:for-each select="marc:datafield[@tag='080']">
    <datafield tag="675" ind1=" " ind2=" ">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='082']">
    <datafield tag="676" ind1=" " ind2=" ">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='2']">
        <subfield code="v"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='050']">
    <datafield tag="680" ind1=" " ind2=" ">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="mu2-responsibility">
  <!-- responsibility: 100 -> 700, 700 -> 702, 110/111 -> 710, 710/711 -> 712 -->
  <xsl:for-each select="marc:datafield[@tag='100']">
    <datafield tag="700" ind1=" ">
      <xsl:attribute name="ind2">
        <xsl:choose>
          <xsl:when test="@ind1 = '0'">0</xsl:when>
          <xsl:otherwise>1</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <xsl:call-template name="mu2-person"/>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='700']">
    <datafield tag="702" ind1=" ">
      <xsl:attribute name="ind2">
        <xsl:choose>
          <xsl:when test="@ind1 = '0'">0</xsl:when>
          <xsl:otherwise>1</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <xsl:call-template name="mu2-person"/>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='110' or @tag='111']">
    <datafield tag="710">
      <xsl:attribute name="ind1">
        <xsl:choose>
          <xsl:when test="@tag = '111'">1</xsl:when>
          <xsl:otherwise>0</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <xsl:attribute name="ind2">
        <xsl:choose>
          <xsl:when test="@ind1 = '0'">0</xsl:when>
          <xsl:when test="@ind1 = '1'">1</xsl:when>
          <xsl:otherwise>2</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <subfield code="a">
        <xsl:call-template name="mu2-chomp">
          <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
        </xsl:call-template>
      </subfield>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='710' or @tag='711']">
    <datafield tag="712">
      <xsl:attribute name="ind1">
        <xsl:choose>
          <xsl:when test="@tag = '711'">1</xsl:when>
          <xsl:otherwise>0</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <xsl:attribute name="ind2">
        <xsl:choose>
          <xsl:when test="@ind1 = '0'">0</xsl:when>
          <xsl:when test="@ind1 = '1'">1</xsl:when>
          <xsl:otherwise>2</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <subfield code="a">
        <xsl:call-template name="mu2-chomp">
          <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
        </xsl:call-template>
      </subfield>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="mu2-source">
  <!-- 801 origin from 040 (one field per agency role) -->
  <xsl:for-each select="marc:datafield[@tag='040'][1]">
    <xsl:for-each select="marc:subfield[@code='a']">
      <datafield tag="801" ind1=" " ind2="0">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
        <xsl:for-each select="../marc:subfield[@code='e'][1]">
          <subfield code="g"><xsl:value-of select="normalize-space(.)"/></subfield>
        </xsl:for-each>
      </datafield>
    </xsl:for-each>
    <xsl:for-each select="marc:subfield[@code='c']">
      <datafield tag="801" ind1=" " ind2="1">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </datafield>
    </xsl:for-each>
    <xsl:for-each select="marc:subfield[@code='d']">
      <datafield tag="801" ind1=" " ind2="2">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </datafield>
    </xsl:for-each>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="mu2-electronic">
  <!-- 856 verbatim -->
  <xsl:for-each select="marc:datafield[@tag='856']">
    <datafield tag="856" ind1="{@ind1}" ind2="{@ind2}">
      <xsl:for-each select="marc:subfield">
        <subfield code="{@code}"><xsl:value-of select="."/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
