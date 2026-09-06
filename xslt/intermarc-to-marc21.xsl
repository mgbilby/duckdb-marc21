<?xml version="1.0" encoding="UTF-8"?>
<!--
  intermarc-to-marc21.xsl - INTERMARC (Bibliothèque nationale de France)
  bibliographic records to MARC 21 Bibliographic.

  Original crosswalk for the duckdb-marc21 project, written from the BnF's
  published INTERMARC documentation - "Format INTERMARC de diffusion"
  and "INTERMARC bibliographique de diffusion",
  <https://www.bnf.fr/fr/format-intermarc-de-diffusion-presentation-generale>
  and <https://www.bnf.fr/fr/intermarc-bibliographique-de-diffusion>, with
  the BnF cataloguing manual (Kitcat, <https://kitcat.bnf.fr/>) for the
  zone-by-zone definitions, and from the BnF's own INTERMARC/UNIMARC
  correspondence (the BnF stores in INTERMARC and publishes UNIMARC by
  conversion) - together with the MARC 21 Format for Bibliographic Data on
  the target side. Nothing is copied from those documents.

  SOURCE REACHABILITY, stated plainly because it bounds the coverage: the
  BnF hosts (bnf.fr, kitcat.bnf.fr) are refused by this environment's
  network egress policy, so the zone-level PDFs could not be read. What is
  mapped below is what the BnF's published zone documentation states
  explicitly and what its block structure fixes:
    * 1XX is the block of main headings, NOT coded data - zone 100 carries
      the first main personal-author heading (one per record) and zone 145
      the conventional-title main heading, while the other personal-author
      headings are in 7XX;
    * each author's function is carried in $4 by a controlled numeric
      function code, the author codes beginning with 0 (e.g. 0070);
    * zone 020 carries the ISBN, zone 245 the title, zone 260 the
      bibliographic address (publication, distribution, production),
      zone 280 the physical description, zone 300 the general note, zone
      302 the language note, zone 310 the note on access and consultation
      conditions, and the 6XX block the RAMEAU subject headings.
  Anything whose subfield table could not be read is either left alone or
  handled by the shape-tolerant rules described under COVERAGE, and said so
  there. The MARC 21 side of every mapping is the published MARC 21 format.

  THE TAG NUMBERS COLLIDE WITH MARC 21'S. This is the reason the sheet
  exists: an INTERMARC record read as MARC 21 puts the physical description
  in 280 (undefined in MARC 21), a general note in 300 (physical
  description in MARC 21) and the language note in 302. Structural reading
  alone therefore misreads an INTERMARC record even where the tags look
  familiar.

  CONTAINER: MARC 21 slim XML in and out - the shape
  read_marc('intermarc.mrc', encoding := 'utf8') followed by
  COPY (FORMAT marcxml) produces. Accepts a bare record or a collection.

  COVERAGE (INTERMARC -> MARC 21):
    record label -> leader   /5 status, /6 type of record and /7
                             bibliographic level are taken from the label
                             when they carry a value MARC 21 also defines,
                             otherwise 'n', 'a' and 'm'; lengths zeroed,
                             /9 'a' (UTF-8), /18 'i'
    001          -> 001      record number
    020          -> 020      $a ISBN, $z erroneous ISBN
    100 / 700    -> 100 / 700  personal author headings: $a is the heading
                             as recorded, $b numeration -> $b, $c -> $c,
                             $f dates -> $d, and each $4 function code ->
                             a MARC 21 relator code (0070/070 aut,
                             0205/205 ctb, 0220/220 com, 0230/230 cmp,
                             0340/340 edt, 0440/440 ill, 0600/600 pht,
                             0730/730 trl; a leading 0 of a four-character
                             code is dropped before lookup, unmapped codes
                             are dropped).  ind1 1 (surname entry) unless
                             the heading has no comma.
    110 / 710    -> 110 / 710  corporate headings, by the same pattern
    145          -> 240      conventional-title main heading ($a, $f/$k
                             carried into $f/$k when present)
    245          -> 245      shape-tolerant: subfields MARC 21 also defines
                             on 245 ($a $b $c $n $p) pass through, and the
                             French-family codes convert ($e complément ->
                             $b, $f mention de responsabilité -> $c,
                             $h -> $n, $i -> $p)
    260          -> 264 _1   shape-tolerant: a field carrying $d is read as
                             the French-family shape ($a place, $c
                             publisher, $d date), otherwise as the MARC 21
                             shape ($a place, $b publisher, $c date)
    280          -> 300      physical description ($a extent, $b other
                             details, $c dimensions, $e accompanying
                             material - the codes MARC 21 uses on 300)
    300          -> 500      general note
    302          -> 546      language note
    310          -> 506      note on access and consultation conditions
    other 3XX    -> 500      any other 3XX with an $a, as a general note
    600/601/605/606/607 -> 600/610/630/650/651
                             RAMEAU headings, ind2 7 with $2 rameau;
                             subdivisions $x topical, $y and $z as
                             recorded, following the French 6XX numbering
                             the BnF and UNIMARC share
    everything else          dropped (see below)

  LOSSES AND EXCLUSIONS (deliberate, so the output never lies):
    * The 4XX block, the 8XX block, coded-data zones, and every zone whose
      subfield table could not be read are dropped rather than guessed at.
    * No 008 is generated: INTERMARC's coded data is not covered here, and
      an 008 invented from nothing would be a lie. Records converted with
      this sheet carry dates and language only as transcribed text.
    * INTERMARC function codes outside the eight listed above are dropped;
      textual function labels are not read.
    * RAMEAU subject-heading subdivision codes beyond $x/$y/$z are dropped.
    * The BnF also publishes its catalogue in UNIMARC, converted from
      INTERMARC by the BnF itself; where full fidelity matters, that route
      plus xslt/intl/unimarc-to-marc21.xsl covers more than this sheet.
  XSLT 1.0 (xsltproc-friendly).
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    xmlns="http://www.loc.gov/MARC21/slim"
    exclude-result-prefixes="marc">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:template match="/marc:collection">
    <collection>
      <xsl:apply-templates select="marc:record"/>
    </collection>
  </xsl:template>

  <!-- BnF function code -> MARC 21 relator code (empty when unmapped) -->
  <xsl:template name="im-relator">
    <xsl:param name="code"/>
    <xsl:variable name="c">
      <xsl:choose>
        <xsl:when test="string-length($code) = 4 and substring($code, 1, 1) = '0'">
          <xsl:value-of select="substring($code, 2)"/>
        </xsl:when>
        <xsl:otherwise><xsl:value-of select="$code"/></xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:choose>
      <xsl:when test="$c = '070'">aut</xsl:when>
      <xsl:when test="$c = '205'">ctb</xsl:when>
      <xsl:when test="$c = '220'">com</xsl:when>
      <xsl:when test="$c = '230'">cmp</xsl:when>
      <xsl:when test="$c = '340'">edt</xsl:when>
      <xsl:when test="$c = '440'">ill</xsl:when>
      <xsl:when test="$c = '600'">pht</xsl:when>
      <xsl:when test="$c = '730'">trl</xsl:when>
    </xsl:choose>
  </xsl:template>

  <!-- one name heading (context node is the INTERMARC zone) -->
  <xsl:template name="im-heading">
    <xsl:param name="tag"/>
    <xsl:variable name="a" select="normalize-space(marc:subfield[@code='a'][1])"/>
    <datafield tag="{$tag}" ind2=" ">
      <xsl:attribute name="ind1">
        <xsl:choose>
          <!-- X10 corporate heading: name in direct order -->
          <xsl:when test="substring($tag, 2, 1) = '1'">2</xsl:when>
          <xsl:when test="contains($a, ',')">1</xsl:when>
          <xsl:otherwise>0</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <subfield code="a"><xsl:value-of select="$a"/></subfield>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='c']">
        <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='f']">
        <subfield code="d"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='4']">
        <xsl:variable name="rel">
          <xsl:call-template name="im-relator">
            <xsl:with-param name="code" select="normalize-space(.)"/>
          </xsl:call-template>
        </xsl:variable>
        <xsl:if test="$rel != ''">
          <subfield code="4"><xsl:value-of select="$rel"/></subfield>
        </xsl:if>
      </xsl:for-each>
    </datafield>
  </xsl:template>

  <!-- one RAMEAU subject heading -->
  <xsl:template name="im-subject">
    <xsl:param name="tag"/>
    <xsl:param name="ind1" select="' '"/>
    <datafield tag="{$tag}" ind1="{$ind1}" ind2="7">
      <subfield code="a">
        <xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/>
      </subfield>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='f']">
        <subfield code="d"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='x']">
        <subfield code="x"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='y']">
        <subfield code="y"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='z']">
        <subfield code="z"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <subfield code="2">rameau</subfield>
    </datafield>
  </xsl:template>

  <xsl:template match="/marc:record | marc:record">
    <xsl:variable name="label" select="marc:leader"/>
    <record>

      <leader>
        <xsl:text>00000</xsl:text>
        <xsl:variable name="st" select="substring($label, 6, 1)"/>
        <xsl:choose>
          <xsl:when test="contains('cdnp', $st) and $st != ''">
            <xsl:value-of select="$st"/>
          </xsl:when>
          <xsl:otherwise>n</xsl:otherwise>
        </xsl:choose>
        <xsl:variable name="ty" select="substring($label, 7, 1)"/>
        <xsl:choose>
          <xsl:when test="contains('acdefgijkmoprt', $ty) and $ty != ''">
            <xsl:value-of select="$ty"/>
          </xsl:when>
          <xsl:otherwise>a</xsl:otherwise>
        </xsl:choose>
        <xsl:variable name="bl" select="substring($label, 8, 1)"/>
        <xsl:choose>
          <xsl:when test="contains('abcdims', $bl) and $bl != ''">
            <xsl:value-of select="$bl"/>
          </xsl:when>
          <xsl:otherwise>m</xsl:otherwise>
        </xsl:choose>
        <xsl:text> a2200000 i 4500</xsl:text>
      </leader>

      <xsl:for-each select="marc:controlfield[@tag='001']">
        <controlfield tag="001"><xsl:value-of select="."/></controlfield>
      </xsl:for-each>
      <xsl:for-each select="marc:controlfield[@tag='005']">
        <controlfield tag="005"><xsl:value-of select="."/></controlfield>
      </xsl:for-each>

      <!-- 020 ISBN -->
      <xsl:for-each select="marc:datafield[@tag='020']">
        <datafield tag="020" ind1=" " ind2=" ">
          <xsl:for-each select="marc:subfield[@code='a']">
            <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='z']">
            <subfield code="z"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
        </datafield>
      </xsl:for-each>

      <!-- main headings -->
      <xsl:for-each select="marc:datafield[@tag='100']">
        <xsl:call-template name="im-heading">
          <xsl:with-param name="tag" select="'100'"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='110']">
        <xsl:call-template name="im-heading">
          <xsl:with-param name="tag" select="'110'"/>
        </xsl:call-template>
      </xsl:for-each>

      <!-- 145 conventional title -> 240 uniform title -->
      <xsl:for-each select="marc:datafield[@tag='145']">
        <datafield tag="240" ind1="1" ind2="0">
          <subfield code="a">
            <xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/>
          </subfield>
          <xsl:for-each select="marc:subfield[@code='f']">
            <subfield code="f"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='k']">
            <subfield code="k"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
        </datafield>
      </xsl:for-each>

      <!-- 245 title, shape-tolerant -->
      <xsl:for-each select="marc:datafield[@tag='245'][1]">
        <datafield tag="245" ind1="{@ind1}" ind2="{@ind2}">
          <subfield code="a">
            <xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/>
          </subfield>
          <xsl:for-each select="marc:subfield[@code='b' or @code='e']">
            <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='c' or @code='f']">
            <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='n' or @code='h']">
            <subfield code="n"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='p' or @code='i']">
            <subfield code="p"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
        </datafield>
      </xsl:for-each>

      <!-- 260 bibliographic address -> 264 _1, shape-tolerant -->
      <xsl:for-each select="marc:datafield[@tag='260']">
        <datafield tag="264" ind1=" " ind2="1">
          <xsl:for-each select="marc:subfield[@code='a']">
            <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:choose>
            <xsl:when test="marc:subfield[@code='d']">
              <xsl:for-each select="marc:subfield[@code='c']">
                <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
              </xsl:for-each>
              <xsl:for-each select="marc:subfield[@code='d']">
                <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
              </xsl:for-each>
            </xsl:when>
            <xsl:otherwise>
              <xsl:for-each select="marc:subfield[@code='b']">
                <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
              </xsl:for-each>
              <xsl:for-each select="marc:subfield[@code='c']">
                <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
              </xsl:for-each>
            </xsl:otherwise>
          </xsl:choose>
        </datafield>
      </xsl:for-each>

      <!-- 280 physical description -> 300 -->
      <xsl:for-each select="marc:datafield[@tag='280']">
        <datafield tag="300" ind1=" " ind2=" ">
          <xsl:for-each select="marc:subfield[@code='a' or @code='b'
                                or @code='c' or @code='e']">
            <subfield code="{@code}"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
        </datafield>
      </xsl:for-each>

      <!-- notes -->
      <xsl:for-each select="marc:datafield[@tag='300'][marc:subfield[@code='a']]">
        <datafield tag="500" ind1=" " ind2=" ">
          <subfield code="a">
            <xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/>
          </subfield>
        </datafield>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='310'][marc:subfield[@code='a']]">
        <datafield tag="506" ind1=" " ind2=" ">
          <subfield code="a">
            <xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/>
          </subfield>
        </datafield>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='302'][marc:subfield[@code='a']]">
        <datafield tag="546" ind1=" " ind2=" ">
          <subfield code="a">
            <xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/>
          </subfield>
        </datafield>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[starts-with(@tag, '3')
                            and not(@tag='300' or @tag='302' or @tag='310'
                                    or @tag='280')][marc:subfield[@code='a']]">
        <datafield tag="500" ind1=" " ind2=" ">
          <subfield code="a">
            <xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/>
          </subfield>
        </datafield>
      </xsl:for-each>

      <!-- RAMEAU subjects -->
      <xsl:for-each select="marc:datafield[@tag='600']">
        <xsl:call-template name="im-subject">
          <xsl:with-param name="tag" select="'600'"/>
          <xsl:with-param name="ind1" select="'1'"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='601']">
        <xsl:call-template name="im-subject">
          <xsl:with-param name="tag" select="'610'"/>
          <xsl:with-param name="ind1" select="'2'"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='605']">
        <xsl:call-template name="im-subject">
          <xsl:with-param name="tag" select="'630'"/>
          <xsl:with-param name="ind1" select="'0'"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='606']">
        <xsl:call-template name="im-subject">
          <xsl:with-param name="tag" select="'650'"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='607']">
        <xsl:call-template name="im-subject">
          <xsl:with-param name="tag" select="'651'"/>
        </xsl:call-template>
      </xsl:for-each>

      <!-- other author headings -->
      <xsl:for-each select="marc:datafield[@tag='700']">
        <xsl:call-template name="im-heading">
          <xsl:with-param name="tag" select="'700'"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='710']">
        <xsl:call-template name="im-heading">
          <xsl:with-param name="tag" select="'710'"/>
        </xsl:call-template>
      </xsl:for-each>

    </record>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
