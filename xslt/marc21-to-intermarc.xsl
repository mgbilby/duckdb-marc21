<?xml version="1.0" encoding="UTF-8"?>
<!--
  marc21-to-intermarc.xsl - MARC 21 Bibliographic to INTERMARC
  (Bibliothèque nationale de France), and the reverse of
  intermarc-to-marc21.xsl.

  Original crosswalk for the duckdb-marc21 project, written from the same
  BnF sources as intermarc-to-marc21.xsl - "Format INTERMARC de diffusion"
  and "INTERMARC bibliographique de diffusion",
  <https://www.bnf.fr/fr/intermarc-bibliographique-de-diffusion>, the BnF
  cataloguing manual (Kitcat, <https://kitcat.bnf.fr/>), and the BnF's own
  INTERMARC/UNIMARC correspondence - with the MARC 21 Format for
  Bibliographic Data on the source side. Nothing is copied from those
  documents.

  SOURCE REACHABILITY: as in intermarc-to-marc21.xsl, the BnF hosts are
  refused by this environment's network egress policy, so the INTERMARC
  side is bounded by what the published zone documentation states: 1XX is
  the block of main headings (100 first personal-author heading, 145
  conventional title), 7XX the other author headings, each author's
  function carried in $4 by a controlled numeric code beginning with 0,
  020 the ISBN, 245 the title, 260 the bibliographic address, 280 the
  physical description, 300/302/310 the general, language and access
  notes, and 6XX the RAMEAU headings.

  WHO SHOULD USE IT. Sending data *to* the BnF is not what this sheet is
  for - the BnF catalogues in INTERMARC itself. It is for round-tripping a
  record converted with intermarc-to-marc21.xsl, and for rendering MARC 21
  holdings in the INTERMARC zone shape for comparison with BnF data.

  CONTAINER: MARC 21 slim XML in and out.

  COVERAGE (MARC 21 -> INTERMARC), the mirror of the subset the forward
  sheet covers:
    leader   -> record label  status, type of record and bibliographic
                              level kept in positions 5-7, lengths zeroed,
                              entry map '450 '
    001, 005 copied
    020      -> 020           $a, $z
    100/700  -> 100/700       personal headings: $a heading, $b, $c,
                              $d dates -> $f, and the MARC 21 relator in $4
                              -> the four-character BnF function code
                              (aut 0070, ctb 0205, com 0220, cmp 0230,
                              edt 0340, ill 0440, pht 0600, trl 0730)
    110/710  -> 110/710       corporate headings, same pattern
    240      -> 145           uniform title -> conventional-title heading
    245      -> 245           $a, $b -> $e, $c -> $f, $n -> $h, $p -> $i
    264/260  -> 260           $a, $b -> $c, $c -> $d (264 preferred when
                              the record carries both)
    300      -> 280           physical description
    500 -> 300, 546 -> 302, 506 -> 310
    600/610/630/650/651 -> 600/601/605/606/607
                              RAMEAU headings; $d -> $f, $x/$y/$z kept,
                              and the $2 source subfield consumed (the 6XX
                              block is RAMEAU by definition here)

  LOSSES AND EXCLUSIONS (deliberate):
    * 008 and every other coded field are dropped: INTERMARC's coded data
      is outside this subset, and inventing it would be a lie.
    * 490/8XX series, 76X-78X linking, 856 and 9XX are dropped.
    * Non-RAMEAU subject headings (6XX with a $2 naming another thesaurus,
      or ind2 0/2 for LCSH/MeSH) are dropped rather than relabelled as
      RAMEAU.
    * MARC 21 relators outside the eight listed above are dropped.
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

  <!-- MARC 21 relator code -> BnF function code (empty when unmapped) -->
  <xsl:template name="mi-function">
    <xsl:param name="code"/>
    <xsl:choose>
      <xsl:when test="$code = 'aut'">0070</xsl:when>
      <xsl:when test="$code = 'ctb'">0205</xsl:when>
      <xsl:when test="$code = 'com'">0220</xsl:when>
      <xsl:when test="$code = 'cmp'">0230</xsl:when>
      <xsl:when test="$code = 'edt'">0340</xsl:when>
      <xsl:when test="$code = 'ill'">0440</xsl:when>
      <xsl:when test="$code = 'pht'">0600</xsl:when>
      <xsl:when test="$code = 'trl'">0730</xsl:when>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="mi-heading">
    <xsl:param name="tag"/>
    <datafield tag="{$tag}" ind1=" " ind2=" ">
      <subfield code="a">
        <xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/>
      </subfield>
      <xsl:for-each select="marc:subfield[@code='b']">
        <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='c']">
        <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='d']">
        <subfield code="f"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='4']">
        <xsl:variable name="fn">
          <xsl:call-template name="mi-function">
            <xsl:with-param name="code" select="normalize-space(.)"/>
          </xsl:call-template>
        </xsl:variable>
        <xsl:if test="$fn != ''">
          <subfield code="4"><xsl:value-of select="$fn"/></subfield>
        </xsl:if>
      </xsl:for-each>
    </datafield>
  </xsl:template>

  <!-- a RAMEAU heading; skipped when the MARC field names another source -->
  <xsl:template name="mi-subject">
    <xsl:param name="tag"/>
    <xsl:variable name="src" select="normalize-space(marc:subfield[@code='2'][1])"/>
    <xsl:if test="$src = 'rameau' or ($src = '' and (@ind2 = '7' or @ind2 = '4'))">
      <datafield tag="{$tag}" ind1=" " ind2=" ">
        <subfield code="a">
          <xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/>
        </subfield>
        <xsl:for-each select="marc:subfield[@code='b']">
          <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
        </xsl:for-each>
        <xsl:for-each select="marc:subfield[@code='d']">
          <subfield code="f"><xsl:value-of select="normalize-space(.)"/></subfield>
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
      </datafield>
    </xsl:if>
  </xsl:template>

  <xsl:template match="/marc:record | marc:record">
    <xsl:variable name="ldr" select="marc:leader"/>
    <xsl:variable name="pub"
        select="marc:datafield[@tag='264'][@ind2='1'][1]
                | marc:datafield[@tag='260'][1][not(../marc:datafield[@tag='264'][@ind2='1'])]"/>
    <record>

      <leader>
        <xsl:text>00000</xsl:text>
        <xsl:value-of select="substring($ldr, 6, 3)"/>
        <xsl:text>0 22000000  450 </xsl:text>
      </leader>

      <xsl:for-each select="marc:controlfield[@tag='001' or @tag='005']">
        <controlfield tag="{@tag}"><xsl:value-of select="."/></controlfield>
      </xsl:for-each>

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

      <xsl:for-each select="marc:datafield[@tag='100']">
        <xsl:call-template name="mi-heading">
          <xsl:with-param name="tag" select="'100'"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='110' or @tag='111']">
        <xsl:call-template name="mi-heading">
          <xsl:with-param name="tag" select="'110'"/>
        </xsl:call-template>
      </xsl:for-each>

      <xsl:for-each select="marc:datafield[@tag='240' or @tag='130']">
        <datafield tag="145" ind1=" " ind2=" ">
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

      <xsl:for-each select="marc:datafield[@tag='245'][1]">
        <datafield tag="245" ind1="{@ind1}" ind2="{@ind2}">
          <subfield code="a">
            <xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/>
          </subfield>
          <xsl:for-each select="marc:subfield[@code='b']">
            <subfield code="e"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='c']">
            <subfield code="f"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='n']">
            <subfield code="h"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='p']">
            <subfield code="i"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
        </datafield>
      </xsl:for-each>

      <xsl:for-each select="$pub">
        <datafield tag="260" ind1=" " ind2=" ">
          <xsl:for-each select="marc:subfield[@code='a']">
            <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='b']">
            <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='c']">
            <subfield code="d"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
        </datafield>
      </xsl:for-each>

      <xsl:for-each select="marc:datafield[@tag='300']">
        <datafield tag="280" ind1=" " ind2=" ">
          <xsl:for-each select="marc:subfield[@code='a' or @code='b'
                                or @code='c' or @code='e']">
            <subfield code="{@code}"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
        </datafield>
      </xsl:for-each>

      <xsl:for-each select="marc:datafield[@tag='500'][marc:subfield[@code='a']]">
        <datafield tag="300" ind1=" " ind2=" ">
          <subfield code="a">
            <xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/>
          </subfield>
        </datafield>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='546'][marc:subfield[@code='a']]">
        <datafield tag="302" ind1=" " ind2=" ">
          <subfield code="a">
            <xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/>
          </subfield>
        </datafield>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='506'][marc:subfield[@code='a']]">
        <datafield tag="310" ind1=" " ind2=" ">
          <subfield code="a">
            <xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/>
          </subfield>
        </datafield>
      </xsl:for-each>

      <xsl:for-each select="marc:datafield[@tag='600']">
        <xsl:call-template name="mi-subject">
          <xsl:with-param name="tag" select="'600'"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='610' or @tag='611']">
        <xsl:call-template name="mi-subject">
          <xsl:with-param name="tag" select="'601'"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='630']">
        <xsl:call-template name="mi-subject">
          <xsl:with-param name="tag" select="'605'"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='650']">
        <xsl:call-template name="mi-subject">
          <xsl:with-param name="tag" select="'606'"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='651']">
        <xsl:call-template name="mi-subject">
          <xsl:with-param name="tag" select="'607'"/>
        </xsl:call-template>
      </xsl:for-each>

      <xsl:for-each select="marc:datafield[@tag='700']">
        <xsl:call-template name="mi-heading">
          <xsl:with-param name="tag" select="'700'"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='710' or @tag='711']">
        <xsl:call-template name="mi-heading">
          <xsl:with-param name="tag" select="'710'"/>
        </xsl:call-template>
      </xsl:for-each>

    </record>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
