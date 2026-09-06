<?xml version="1.0" encoding="UTF-8"?>
<!--
  unimarc-to-marc21.xsl - UNIMARC Bibliographic to MARC 21 Bibliographic,
  field level.

  Original crosswalk for the duckdb-marc21 project, written from the IFLA
  "UNIMARC Manual: Bibliographic Format" (3rd edition updated, IFLA,
  https://www.ifla.org/publications/unimarc-formats-and-related-documentation/)
  and the IFLA/Library of Congress alignment documentation ("UNIMARC to
  MARC 21 Conversion Specifications", LC Network Development and MARC
  Standards Office). IFLA publications are licensed CC BY 4.0; this
  stylesheet references their specifications and copies nothing from them.
  Attribution: "UNIMARC Manual: Bibliographic Format, IFLA, CC BY 4.0".

  CONTAINER. Both input and output use the MARC 21 slim XML container
  (namespace http://www.loc.gov/MARC21/slim): the UNIMARC community reuses
  the slim schema for UNIMARC/XML, and this is exactly the shape produced
  by  read_marc('unimarc.mrc', encoding := 'utf8')  followed by
  COPY (FORMAT marcxml). Accepts a bare record or a collection.

  DELTA LAYERS. The record body is emitted by named block templates -
  iu-leader, iu-controlfields, iu-008, iu-identifiers, iu-source,
  iu-classification, iu-main-entry, iu-title-block, iu-notes, iu-subjects,
  iu-added-entries, iu-linking-block, iu-electronic - plus an empty
  iu-national hook called last. A stylesheet for a UNIMARC-derived national
  format imports this one (xsl:import, not xsl:include: XSLT 1.0 gives the
  importing sheet the higher precedence that overriding requires, while two
  same-named templates at equal precedence would be an error) and redefines
  only the blocks it must change.

  COVERAGE (UNIMARC -> MARC 21):
    record label -> leader   (positions 5-9, 17-19 remapped; lengths zeroed)
    001, 005                 copied
    010 ISBN     -> 020      ($a->$a, $b->$q, $d->$c, $z->$z)
    011 ISSN     -> 022      ($a->$a, $z erroneous->$y, $y cancelled->$z)
    100 $a       -> 008      (date entered /0-7 -> /00-05; type of date /8
                              remapped; dates /9-16 -> /07-14; language of
                              cataloguing /22-24 -> 040 $b)
    101 language -> 008/35-37 + 041 ($a->$a, $c orig->$h, $d summary->$b,
                              $h libretto->$e, $j subtitles->$j; ind1 1
                              [translation] -> 041 ind1 1)
    102 country  -> 008/15-17 (ISO 3166 alpha-2 to MARC country code via a
                              common-country table, else 'xx '; the ISO code
                              is always kept verbatim in 044 $c)
    200          -> 245      ($a->$a, $b GMD->$h, $d parallel->$b prefixed
                              '= ', $e->$b, $f->$c, $g appended to $c after
                              ' ; ', $h->$n, $i->$p; ind1 significance ->
                              ind1 title added entry; ind2 = 0, see LOSSES)
    205          -> 250      ($a->$a, $f->$b)
    210          -> 260      ($a->$a, $c->$b, $d->$c, $e->$e, $g->$f, $h->$g)
    214          -> 264      (ind2 0 publication->_1, 1 production->_0,
                              2 distribution->_2, 3 manufacture->_3,
                              4 copyright->_4; $a->$a, $c->$b, $d->$c)
    215          -> 300      ($a->$a, $c->$b, $d->$c, $e->$e)
    225          -> 490      ($a->$a, $v->$v, $x->$x; ind1 always 0 - series
                              tracing practice does not translate)
    300 -> 500, 320 -> 504, 327 -> 505, 328 -> 502, 330 -> 520;
    other 3XX with $a -> 500 (catch-all general note)
    4XX linking  -> 76X-78X  (standard-subfield technique only: $t,$x,$a,$v;
                              410->490+$x, 421->770, 422->772, 430..437->780,
                              440..447->785, 451->775, 452->776, 453->767,
                              454->765, 461..464->773, 488->787)
    600          -> 600, 601 -> 610/611 (by ind1), 606 -> 650, 607 -> 651
                             (UNIMARC $y geographic -> MARC $z and $z
                              chronological -> $y - the codes swap; source:
                              $2 'lc'->ind2 0, 'mesh'->ind2 2, other ->
                              ind2 7 + $2, none -> ind2 4)
    675 UDC -> 080, 676 DDC -> 082 ($v edition->$2), 680 LCC -> 050
    700/701/702  -> 100/700  (personal names; $a entry element + $b other
                              part rejoined 'Entry, Other' when ind2=1
                              [surname]; $c->$c, $d numeration->$b,
                              $f dates->$d; numeric UNIMARC relator $4
                              mapped to MARC relator codes: 070 aut, 205 ctb,
                              220 com, 230 cmp, 340 edt, 440 ill, 600 pht,
                              730 trl; ind2 entry form -> 100/700 ind1)
    710/711/712  -> 110/710 or 111/711 (ind1 1 = meeting routes to the
                              X11 tags; ind2 entry form -> X10/X11 ind1)
    801          -> 040      (ind2 0 $b->$a, ind2 1 $b->$c, ind2 2 $b->$d,
                              $g->$e; $b of 100 from language of cataloguing)
    856          -> 856      (indicators and subfields copied verbatim)

  LOSSES AND EXCLUSIONS (deliberate, so the output never lies):
    * The embedded-field ($1) linking technique in 4XX is NOT parsed; only
      standard subfields ($a/$t/$x/$v) convert. 4XX with only $1 drop.
    * UNIMARC non-sorting markers (NSB/NSE control characters) are not
      interpreted; 245 ind2 is always 0.
    * 100 $a target audience, transliteration and script positions are not
      converted; 008/18-34 is filled with '|' (no attempt to code).
    * Blocks not listed above (105-140 coded data, 205 $b/$d/$g detail,
      302-317/321-328 special notes beyond those mapped, 5XX related
      titles, 604/605/608/610/615-617 subject forms, 71X $c/$d additions,
      686, 830, 852, 886) are dropped.
  XSLT 1.0 (xsltproc-friendly).
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    xmlns="http://www.loc.gov/MARC21/slim"
    exclude-result-prefixes="marc">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <!-- MARC country code lookup, '|ISO:marc|' pairs (common countries; the
       full MARC code list is much larger - unmatched codes yield 'xx '). -->
  <xsl:variable name="iso2marc"
    >|FR:fr |DE:gw |IT:it |ES:sp |PT:po |NL:ne |BE:be |CH:sz |AT:au |JP:ja |CN:cc |RU:ru |US:xxu|GB:xxk|CA:xxc|AU:at |DK:dk |SE:sw |NO:no |FI:fi |PL:pl |GR:gr |TR:tu |KR:ko |BR:bl |MX:mx |IE:ie |CZ:xr |HU:hu |</xsl:variable>

  <xsl:template match="/marc:collection">
    <collection>
      <xsl:apply-templates select="marc:record"/>
    </collection>
  </xsl:template>

  <!-- trim trailing ISBD punctuation + whitespace -->
  <xsl:template name="iu-chomp">
    <xsl:param name="s"/>
    <xsl:variable name="t" select="normalize-space($s)"/>
    <xsl:variable name="n" select="string-length($t)"/>
    <xsl:choose>
      <xsl:when test="$n = 0"/>
      <xsl:when test="contains(',;:/=', substring($t, $n, 1))">
        <xsl:call-template name="iu-chomp">
          <xsl:with-param name="s" select="substring($t, 1, $n - 1)"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$t"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- 'Entry, Other' personal-name join: UNIMARC keeps the entry element in
       $a and the rest of the name (forenames) in $b; MARC 21 carries the
       whole inverted form in $a. -->
  <xsl:template name="iu-name">
    <xsl:variable name="a">
      <xsl:call-template name="iu-chomp">
        <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="b">
      <xsl:call-template name="iu-chomp">
        <xsl:with-param name="s" select="marc:subfield[@code='b'][1]"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:choose>
      <xsl:when test="$b != '' and @ind2 = '0'">
        <!-- entered under forename: direct order -->
        <xsl:value-of select="concat($a, ' ', $b)"/>
      </xsl:when>
      <xsl:when test="$b != ''">
        <xsl:value-of select="concat($a, ', ', $b)"/>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$a"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- UNIMARC numeric relator code -> MARC relator code (empty = unmapped) -->
  <xsl:template name="iu-relator">
    <xsl:param name="code"/>
    <xsl:choose>
      <xsl:when test="$code = '070'">aut</xsl:when>
      <xsl:when test="$code = '205'">ctb</xsl:when>
      <xsl:when test="$code = '220'">com</xsl:when>
      <xsl:when test="$code = '230'">cmp</xsl:when>
      <xsl:when test="$code = '340'">edt</xsl:when>
      <xsl:when test="$code = '440'">ill</xsl:when>
      <xsl:when test="$code = '600'">pht</xsl:when>
      <xsl:when test="$code = '730'">trl</xsl:when>
    </xsl:choose>
  </xsl:template>

  <!-- shared tail of a personal-name field: additions, numeration, dates,
       relator -->
  <xsl:template name="iu-person-tail">
    <xsl:for-each select="marc:subfield[@code='c']">
      <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
    </xsl:for-each>
    <xsl:for-each select="marc:subfield[@code='d']">
      <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
    </xsl:for-each>
    <xsl:for-each select="marc:subfield[@code='f']">
      <subfield code="d"><xsl:value-of select="normalize-space(.)"/></subfield>
    </xsl:for-each>
    <xsl:for-each select="marc:subfield[@code='4']">
      <xsl:variable name="rel">
        <xsl:call-template name="iu-relator">
          <xsl:with-param name="code" select="normalize-space(.)"/>
        </xsl:call-template>
      </xsl:variable>
      <xsl:if test="$rel != ''">
        <subfield code="4"><xsl:value-of select="$rel"/></subfield>
      </xsl:if>
    </xsl:for-each>
  </xsl:template>

  <!-- subject source: UNIMARC $2 system code -> MARC 6XX ind2 (+ $2) -->
  <xsl:template name="iu-subject-ind2">
    <xsl:param name="sf2"/>
    <xsl:choose>
      <xsl:when test="normalize-space($sf2) = 'lc'">0</xsl:when>
      <xsl:when test="normalize-space($sf2) = 'mesh'">2</xsl:when>
      <xsl:when test="normalize-space($sf2) != ''">7</xsl:when>
      <xsl:otherwise>4</xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- topical/geographic subdivisions; NOTE the swap: UNIMARC $y is
       geographic and $z chronological, MARC 21 the other way around -->
  <xsl:template name="iu-subject-tail">
    <xsl:for-each select="marc:subfield[@code='x']">
      <subfield code="x"><xsl:value-of select="normalize-space(.)"/></subfield>
    </xsl:for-each>
    <xsl:for-each select="marc:subfield[@code='y']">
      <subfield code="z"><xsl:value-of select="normalize-space(.)"/></subfield>
    </xsl:for-each>
    <xsl:for-each select="marc:subfield[@code='z']">
      <subfield code="y"><xsl:value-of select="normalize-space(.)"/></subfield>
    </xsl:for-each>
    <xsl:if test="normalize-space(marc:subfield[@code='2']) != ''
                  and normalize-space(marc:subfield[@code='2']) != 'lc'
                  and normalize-space(marc:subfield[@code='2']) != 'mesh'">
      <subfield code="2"><xsl:value-of select="normalize-space(marc:subfield[@code='2'])"/></subfield>
    </xsl:if>
  </xsl:template>

  <!-- one linking-entry field in the 76X-78X family, standard subfields -->
  <xsl:template name="iu-linking">
    <xsl:param name="tag"/>
    <xsl:param name="ind2" select="' '"/>
    <datafield tag="{$tag}" ind1="0" ind2="{$ind2}">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='t']">
        <subfield code="t"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='x']">
        <subfield code="x"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='v']">
        <subfield code="g"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:template>

  <!-- Entry point.  The record body is split into named block templates so
       that a national delta layer (a UNIMARC-derived format such as RUSMARC)
       can xsl:import this stylesheet and override or extend one block without
       restating the rest.  Every block template runs with the source record
       element as its context node. -->
  <xsl:template match="/marc:record | marc:record">
    <xsl:call-template name="iu-record"/>
  </xsl:template>

  <xsl:template name="iu-record">
    <record>
      <xsl:call-template name="iu-leader"/>
      <xsl:call-template name="iu-controlfields"/>
      <xsl:call-template name="iu-008"/>
      <xsl:call-template name="iu-identifiers"/>
      <xsl:call-template name="iu-source"/>
      <xsl:call-template name="iu-classification"/>
      <xsl:call-template name="iu-main-entry"/>
      <xsl:call-template name="iu-title-block"/>
      <xsl:call-template name="iu-notes"/>
      <xsl:call-template name="iu-subjects"/>
      <xsl:call-template name="iu-added-entries"/>
      <xsl:call-template name="iu-linking-block"/>
      <xsl:call-template name="iu-electronic"/>
      <xsl:call-template name="iu-national"/>
    </record>
  </xsl:template>

  <!-- Extension hook: empty here.  A national delta layer overrides it to
       emit the fields this stylesheet has no mapping for. -->
  <xsl:template name="iu-national"/>

  <!-- Extension hook: 008/18-34 (17 positions), left uncoded here.  A delta
       layer for a format that documents those coded values overrides it and
       must emit exactly 17 characters. -->
  <xsl:template name="iu-008-18-34">
    <xsl:text>|||||||||||||||||</xsl:text>
  </xsl:template>

  <!-- Extension hook: extra subfields at the end of the generated 022,
       empty here (context node is the source 011 field). -->
  <xsl:template name="iu-022-tail"/>

  <xsl:template name="iu-leader">
    <xsl:variable name="label" select="marc:leader"/>
  <!-- ============ leader: UNIMARC record label -> MARC 21 ========= -->
  <leader>
    <xsl:text>00000</xsl:text>
    <!-- /5 status: c,d,n,p as-is; o (previously issued higher level) -> c -->
    <xsl:variable name="st" select="substring($label, 6, 1)"/>
    <xsl:choose>
      <xsl:when test="contains('cdnp', $st) and $st != ''"><xsl:value-of select="$st"/></xsl:when>
      <xsl:when test="$st = 'o'">c</xsl:when>
      <xsl:otherwise>n</xsl:otherwise>
    </xsl:choose>
    <!-- /6 type of record: b->t (manuscript language), l->m (electronic),
         m (multimedia/kit)->o; the rest coincide -->
    <xsl:variable name="ty" select="substring($label, 7, 1)"/>
    <xsl:choose>
      <xsl:when test="$ty = 'b'">t</xsl:when>
      <xsl:when test="$ty = 'l'">m</xsl:when>
      <xsl:when test="$ty = 'm'">o</xsl:when>
      <xsl:when test="contains('acdefgijkr', $ty) and $ty != ''"><xsl:value-of select="$ty"/></xsl:when>
      <xsl:otherwise>a</xsl:otherwise>
    </xsl:choose>
    <!-- /7 bibliographic level: a,c,i,m,s coincide -->
    <xsl:variable name="bl" select="substring($label, 8, 1)"/>
    <xsl:choose>
      <xsl:when test="contains('acims', $bl) and $bl != ''"><xsl:value-of select="$bl"/></xsl:when>
      <xsl:otherwise>m</xsl:otherwise>
    </xsl:choose>
    <!-- /8 type of control (undefined in UNIMARC), /9 = a (this pipeline
         is UTF-8), /10-11 counts -->
    <xsl:text> a22</xsl:text>
    <xsl:text>00000</xsl:text>
    <!-- /17 encoding level: UNIMARC 1 (CIP-ish) -> 8, 2 -> 5, 3 -> 3 -->
    <xsl:variable name="el" select="substring($label, 18, 1)"/>
    <xsl:choose>
      <xsl:when test="$el = '1'">8</xsl:when>
      <xsl:when test="$el = '2'">5</xsl:when>
      <xsl:when test="$el = '3'">3</xsl:when>
      <xsl:otherwise><xsl:text> </xsl:text></xsl:otherwise>
    </xsl:choose>
    <!-- /18 descriptive cataloguing form: UNIMARC blank = full ISBD -> i,
         i (partial ISBD) -> i, n (non-ISBD) -> blank -->
    <xsl:variable name="cf" select="substring($label, 19, 1)"/>
    <xsl:choose>
      <xsl:when test="$cf = 'n'"><xsl:text> </xsl:text></xsl:when>
      <xsl:otherwise>i</xsl:otherwise>
    </xsl:choose>
    <xsl:text> 4500</xsl:text>
  </leader>

  </xsl:template>

  <xsl:template name="iu-controlfields">
  <!-- ============ control fields ============ -->
  <xsl:for-each select="marc:controlfield[@tag='001']">
    <controlfield tag="001"><xsl:value-of select="."/></controlfield>
  </xsl:for-each>
  <xsl:for-each select="marc:controlfield[@tag='005']">
    <controlfield tag="005"><xsl:value-of select="."/></controlfield>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="iu-008">
    <xsl:variable name="f100" select="marc:datafield[@tag='100'][1]/marc:subfield[@code='a'][1]"/>
  <!-- 008 from 100 $a + 101 + 102 -->
  <controlfield tag="008">
    <xsl:choose>
      <xsl:when test="string-length($f100) &gt;= 17">
        <!-- date entered YYYYMMDD -> YYMMDD -->
        <xsl:value-of select="substring($f100, 3, 6)"/>
        <!-- type of publication date -->
        <xsl:variable name="td" select="substring($f100, 9, 1)"/>
        <xsl:choose>
          <xsl:when test="$td = 'a'">c</xsl:when>
          <xsl:when test="$td = 'b'">d</xsl:when>
          <xsl:when test="$td = 'c'">u</xsl:when>
          <xsl:when test="$td = 'd'">s</xsl:when>
          <xsl:when test="$td = 'e'">r</xsl:when>
          <xsl:when test="$td = 'f'">q</xsl:when>
          <xsl:when test="$td = 'g'">m</xsl:when>
          <xsl:when test="$td = 'h'">t</xsl:when>
          <xsl:when test="$td = 'i'">m</xsl:when>
          <xsl:when test="$td = 'j'">e</xsl:when>
          <xsl:when test="$td = 'u'">n</xsl:when>
          <xsl:otherwise>s</xsl:otherwise>
        </xsl:choose>
        <!-- dates 1 and 2 -->
        <xsl:value-of select="substring($f100, 10, 4)"/>
        <xsl:value-of select="substring($f100, 14, 4)"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:text>      n        </xsl:text>
      </xsl:otherwise>
    </xsl:choose>
    <!-- /15-17 country from 102 (ISO alpha-2 -> MARC code) -->
    <xsl:variable name="iso"
        select="normalize-space(marc:datafield[@tag='102'][1]/marc:subfield[@code='a'][1])"/>
    <xsl:variable name="cc"
        select="substring(substring-after($iso2marc, concat('|', $iso, ':')), 1, 3)"/>
    <xsl:choose>
      <xsl:when test="string-length($iso) = 2 and $cc != ''">
        <xsl:value-of select="$cc"/>
      </xsl:when>
      <xsl:otherwise>xx </xsl:otherwise>
    </xsl:choose>
    <!-- /18-34: no attempt to code; a delta layer whose format documents
         those coded positions overrides iu-008-18-34 -->
    <xsl:call-template name="iu-008-18-34"/>
    <!-- /35-37 language of text from first 101 $a -->
    <xsl:variable name="lg"
        select="normalize-space(marc:datafield[@tag='101'][1]/marc:subfield[@code='a'][1])"/>
    <xsl:choose>
      <xsl:when test="string-length($lg) = 3"><xsl:value-of select="$lg"/></xsl:when>
      <xsl:otherwise><xsl:text>   </xsl:text></xsl:otherwise>
    </xsl:choose>
    <xsl:text> d</xsl:text>
  </controlfield>

  </xsl:template>

  <xsl:template name="iu-identifiers">
  <!-- 020 from 010 -->
  <xsl:for-each select="marc:datafield[@tag='010']">
    <datafield tag="020" ind1=" " ind2=" ">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="q"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='d']">
        <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='z']">
        <subfield code="z"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  <!-- 022 from 011: UNIMARC $z erroneous -> $y incorrect,
       $y cancelled -> $z canceled -->
  <xsl:for-each select="marc:datafield[@tag='011']">
    <datafield tag="022" ind1=" " ind2=" ">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='z']">
        <subfield code="y"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='y']">
        <subfield code="z"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:call-template name="iu-022-tail"/>
    </datafield>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="iu-source">
    <xsl:variable name="f100" select="marc:datafield[@tag='100'][1]/marc:subfield[@code='a'][1]"/>
  <!-- 040 from 801 (by ind2 role) + language of cataloguing (100/22-24) -->
  <xsl:if test="marc:datafield[@tag='801'] or string-length($f100) &gt;= 25">
    <datafield tag="040" ind1=" " ind2=" ">
      <xsl:for-each select="marc:datafield[@tag='801'][@ind2='0'][1]/marc:subfield[@code='b']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:if test="normalize-space(substring($f100, 23, 3)) != ''">
        <subfield code="b"><xsl:value-of select="substring($f100, 23, 3)"/></subfield>
      </xsl:if>
      <xsl:for-each select="marc:datafield[@tag='801'][@ind2='1'][1]/marc:subfield[@code='b']">
        <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='801'][@ind2='2']/marc:subfield[@code='b']">
        <subfield code="d"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='801'][1]/marc:subfield[@code='g'][1]">
        <subfield code="e"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:if>

  <!-- 041 from 101 when it says more than 008/35-37 can -->
  <xsl:for-each select="marc:datafield[@tag='101'][1]">
    <xsl:if test="@ind1 = '1' or count(marc:subfield[@code='a']) &gt; 1
                  or marc:subfield[@code='b' or @code='c' or @code='d'
                                   or @code='h' or @code='j']">
      <datafield tag="041">
        <xsl:attribute name="ind1">
          <xsl:choose>
            <xsl:when test="@ind1 = '1'">1</xsl:when>
            <xsl:otherwise>0</xsl:otherwise>
          </xsl:choose>
        </xsl:attribute>
        <xsl:attribute name="ind2"><xsl:text> </xsl:text></xsl:attribute>
        <xsl:for-each select="marc:subfield[@code='a']">
          <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
        </xsl:for-each>
        <xsl:for-each select="marc:subfield[@code='d']">
          <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
        </xsl:for-each>
        <xsl:for-each select="marc:subfield[@code='h']">
          <subfield code="e"><xsl:value-of select="normalize-space(.)"/></subfield>
        </xsl:for-each>
        <xsl:for-each select="marc:subfield[@code='c']">
          <subfield code="h"><xsl:value-of select="normalize-space(.)"/></subfield>
        </xsl:for-each>
        <xsl:for-each select="marc:subfield[@code='j']">
          <subfield code="j"><xsl:value-of select="normalize-space(.)"/></subfield>
        </xsl:for-each>
      </datafield>
    </xsl:if>
  </xsl:for-each>

  <!-- 044 $c keeps the ISO country code verbatim -->
  <xsl:for-each select="marc:datafield[@tag='102'][1]/marc:subfield[@code='a'][1]">
    <datafield tag="044" ind1=" " ind2=" ">
      <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
    </datafield>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="iu-classification">
  <!-- classifications: 680 -> 050, 675 -> 080, 676 -> 082 -->
  <xsl:for-each select="marc:datafield[@tag='680']">
    <datafield tag="050" ind1=" " ind2="4">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='675']">
    <datafield tag="080" ind1=" " ind2=" ">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='676']">
    <datafield tag="082" ind1="0" ind2="4">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='v']">
        <subfield code="2"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="iu-main-entry">
  <!-- 100 from 700 (primary personal responsibility) -->
  <xsl:for-each select="marc:datafield[@tag='700']">
    <datafield tag="100" ind2=" ">
      <xsl:attribute name="ind1">
        <xsl:choose>
          <xsl:when test="@ind2 = '0'">0</xsl:when>
          <xsl:otherwise>1</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <subfield code="a"><xsl:call-template name="iu-name"/></subfield>
      <xsl:call-template name="iu-person-tail"/>
    </datafield>
  </xsl:for-each>

  <!-- 110/111 from 710 (primary corporate/meeting) -->
  <xsl:for-each select="marc:datafield[@tag='710']">
    <xsl:variable name="tag">
      <xsl:choose>
        <xsl:when test="@ind1 = '1'">111</xsl:when>
        <xsl:otherwise>110</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <datafield tag="{$tag}" ind2=" ">
      <xsl:attribute name="ind1">
        <xsl:choose>
          <xsl:when test="@ind2 = '1'">1</xsl:when>
          <xsl:when test="@ind2 = '0'">0</xsl:when>
          <xsl:otherwise>2</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <subfield code="a">
        <xsl:call-template name="iu-chomp">
          <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
        </xsl:call-template>
      </subfield>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="iu-title-block">
  <!-- 245 from 200 -->
  <xsl:for-each select="marc:datafield[@tag='200'][1]">
    <datafield tag="245" ind2="0">
      <xsl:attribute name="ind1">
        <xsl:choose>
          <xsl:when test="@ind1 = '0'">0</xsl:when>
          <xsl:otherwise>1</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <subfield code="a">
        <xsl:call-template name="iu-chomp">
          <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
        </xsl:call-template>
      </subfield>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="h"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='e']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='d']">
        <subfield code="b">= <xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:if test="marc:subfield[@code='f' or @code='g']">
        <subfield code="c">
          <xsl:for-each select="marc:subfield[@code='f' or @code='g']">
            <xsl:if test="position() &gt; 1"><xsl:text> ; </xsl:text></xsl:if>
            <xsl:value-of select="normalize-space(.)"/>
          </xsl:for-each>
        </subfield>
      </xsl:if>
      <xsl:for-each select="marc:subfield[@code='h']">
        <subfield code="n"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='i']">
        <subfield code="p"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  <!-- 250 from 205 -->
  <xsl:for-each select="marc:datafield[@tag='205']">
    <datafield tag="250" ind1=" " ind2=" ">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='f']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  <!-- 260 from 210 -->
  <xsl:for-each select="marc:datafield[@tag='210']">
    <datafield tag="260" ind1=" " ind2=" ">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='c']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='d']">
        <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='e']">
        <subfield code="e"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='g']">
        <subfield code="f"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='h']">
        <subfield code="g"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  <!-- 264 from 214; the function indicators differ:
       UNIMARC 0=publication -> 264 _1, 1=production -> _0 -->
  <xsl:for-each select="marc:datafield[@tag='214']">
    <datafield tag="264" ind1=" ">
      <xsl:attribute name="ind2">
        <xsl:choose>
          <xsl:when test="@ind2 = '1'">0</xsl:when>
          <xsl:when test="@ind2 = '2'">2</xsl:when>
          <xsl:when test="@ind2 = '3'">3</xsl:when>
          <xsl:when test="@ind2 = '4'">4</xsl:when>
          <xsl:otherwise>1</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='c']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='d']">
        <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  <!-- 300 from 215 -->
  <xsl:for-each select="marc:datafield[@tag='215']">
    <datafield tag="300" ind1=" " ind2=" ">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='c']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='d']">
        <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='e']">
        <subfield code="e"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  <!-- 490 from 225 (and 410 with standard subfields, below with 76X) -->
  <xsl:for-each select="marc:datafield[@tag='225']">
    <datafield tag="490" ind1="0" ind2=" ">
      <xsl:for-each select="marc:subfield[@code='a']">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='x']">
        <subfield code="x"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='v']">
        <subfield code="v"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='410'][marc:subfield[@code='t' or @code='a']]">
    <datafield tag="490" ind1="0" ind2=" ">
      <subfield code="a">
        <xsl:value-of select="normalize-space(marc:subfield[@code='t' or @code='a'][1])"/>
      </subfield>
      <xsl:for-each select="marc:subfield[@code='x']">
        <subfield code="x"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='v']">
        <subfield code="v"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="iu-notes">
  <!-- notes: 300 -> 500, 320 -> 504, 327 -> 505, 328 -> 502, 330 -> 520,
       any other 3XX with $a -> 500 -->
  <xsl:for-each select="marc:datafield[@tag='300']">
    <datafield tag="500" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/></subfield>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='328']">
    <datafield tag="502" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/></subfield>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='320']">
    <datafield tag="504" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/></subfield>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='327']">
    <datafield tag="505" ind1="0" ind2=" ">
      <subfield code="a">
        <xsl:for-each select="marc:subfield[@code='a']">
          <xsl:if test="position() &gt; 1"><xsl:text> ; </xsl:text></xsl:if>
          <xsl:value-of select="normalize-space(.)"/>
        </xsl:for-each>
      </subfield>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='330']">
    <datafield tag="520" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/></subfield>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[starts-with(@tag, '3')
                        and not(@tag='300' or @tag='320' or @tag='327'
                                or @tag='328' or @tag='330')]
                        [marc:subfield[@code='a']]">
    <datafield tag="500" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/></subfield>
    </datafield>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="iu-subjects">
  <!-- subjects -->
  <xsl:for-each select="marc:datafield[@tag='600']">
    <datafield tag="600">
      <xsl:attribute name="ind1">
        <xsl:choose>
          <xsl:when test="@ind2 = '0'">0</xsl:when>
          <xsl:otherwise>1</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <xsl:attribute name="ind2">
        <xsl:call-template name="iu-subject-ind2">
          <xsl:with-param name="sf2" select="marc:subfield[@code='2'][1]"/>
        </xsl:call-template>
      </xsl:attribute>
      <subfield code="a"><xsl:call-template name="iu-name"/></subfield>
      <xsl:for-each select="marc:subfield[@code='c']">
        <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='d']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='f']">
        <subfield code="d"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:call-template name="iu-subject-tail"/>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='601']">
    <xsl:variable name="tag">
      <xsl:choose>
        <xsl:when test="@ind1 = '1'">611</xsl:when>
        <xsl:otherwise>610</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <datafield tag="{$tag}">
      <xsl:attribute name="ind1">
        <xsl:choose>
          <xsl:when test="@ind2 = '1'">1</xsl:when>
          <xsl:when test="@ind2 = '0'">0</xsl:when>
          <xsl:otherwise>2</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <xsl:attribute name="ind2">
        <xsl:call-template name="iu-subject-ind2">
          <xsl:with-param name="sf2" select="marc:subfield[@code='2'][1]"/>
        </xsl:call-template>
      </xsl:attribute>
      <subfield code="a">
        <xsl:call-template name="iu-chomp">
          <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
        </xsl:call-template>
      </subfield>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:call-template name="iu-subject-tail"/>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='606']">
    <datafield tag="650" ind1=" ">
      <xsl:attribute name="ind2">
        <xsl:call-template name="iu-subject-ind2">
          <xsl:with-param name="sf2" select="marc:subfield[@code='2'][1]"/>
        </xsl:call-template>
      </xsl:attribute>
      <subfield code="a"><xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/></subfield>
      <xsl:call-template name="iu-subject-tail"/>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='607']">
    <datafield tag="651" ind1=" ">
      <xsl:attribute name="ind2">
        <xsl:call-template name="iu-subject-ind2">
          <xsl:with-param name="sf2" select="marc:subfield[@code='2'][1]"/>
        </xsl:call-template>
      </xsl:attribute>
      <subfield code="a"><xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/></subfield>
      <xsl:call-template name="iu-subject-tail"/>
    </datafield>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="iu-added-entries">
  <!-- added entries: 701/702 -> 700, 711/712 -> 710/711 -->
  <xsl:for-each select="marc:datafield[@tag='701' or @tag='702']">
    <datafield tag="700" ind2=" ">
      <xsl:attribute name="ind1">
        <xsl:choose>
          <xsl:when test="@ind2 = '0'">0</xsl:when>
          <xsl:otherwise>1</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <subfield code="a"><xsl:call-template name="iu-name"/></subfield>
      <xsl:call-template name="iu-person-tail"/>
    </datafield>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='711' or @tag='712']">
    <xsl:variable name="tag">
      <xsl:choose>
        <xsl:when test="@ind1 = '1'">711</xsl:when>
        <xsl:otherwise>710</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <datafield tag="{$tag}" ind2=" ">
      <xsl:attribute name="ind1">
        <xsl:choose>
          <xsl:when test="@ind2 = '1'">1</xsl:when>
          <xsl:when test="@ind2 = '0'">0</xsl:when>
          <xsl:otherwise>2</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <subfield code="a">
        <xsl:call-template name="iu-chomp">
          <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
        </xsl:call-template>
      </subfield>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="iu-linking-block">
  <!-- 4XX linking block (standard-subfield technique) -> 76X-78X -->
  <xsl:for-each select="marc:datafield[@tag='421'][marc:subfield[@code='t' or @code='a' or @code='x']]">
    <xsl:call-template name="iu-linking"><xsl:with-param name="tag" select="'770'"/></xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='422'][marc:subfield[@code='t' or @code='a' or @code='x']]">
    <xsl:call-template name="iu-linking"><xsl:with-param name="tag" select="'772'"/></xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag &gt;= '430' and @tag &lt;= '437']
                        [marc:subfield[@code='t' or @code='a' or @code='x']]">
    <xsl:call-template name="iu-linking">
      <xsl:with-param name="tag" select="'780'"/>
      <xsl:with-param name="ind2" select="'0'"/>
    </xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag &gt;= '440' and @tag &lt;= '447']
                        [marc:subfield[@code='t' or @code='a' or @code='x']]">
    <xsl:call-template name="iu-linking">
      <xsl:with-param name="tag" select="'785'"/>
      <xsl:with-param name="ind2" select="'0'"/>
    </xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='451'][marc:subfield[@code='t' or @code='a' or @code='x']]">
    <xsl:call-template name="iu-linking"><xsl:with-param name="tag" select="'775'"/></xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='452'][marc:subfield[@code='t' or @code='a' or @code='x']]">
    <xsl:call-template name="iu-linking"><xsl:with-param name="tag" select="'776'"/></xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='453'][marc:subfield[@code='t' or @code='a' or @code='x']]">
    <xsl:call-template name="iu-linking"><xsl:with-param name="tag" select="'767'"/></xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='454'][marc:subfield[@code='t' or @code='a' or @code='x']]">
    <xsl:call-template name="iu-linking"><xsl:with-param name="tag" select="'765'"/></xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag &gt;= '461' and @tag &lt;= '464']
                        [marc:subfield[@code='t' or @code='a' or @code='x']]">
    <xsl:call-template name="iu-linking"><xsl:with-param name="tag" select="'773'"/></xsl:call-template>
  </xsl:for-each>
  <xsl:for-each select="marc:datafield[@tag='488'][marc:subfield[@code='t' or @code='a' or @code='x']]">
    <xsl:call-template name="iu-linking"><xsl:with-param name="tag" select="'787'"/></xsl:call-template>
  </xsl:for-each>

  </xsl:template>

  <xsl:template name="iu-electronic">
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
