<?xml version="1.0" encoding="UTF-8"?>
<!--
  mab2-to-marc21.xsl - MAB2 (the former German/Austrian exchange format) to
  MARC 21 Bibliographic: a legacy migration sheet.

  Original crosswalk for the duckdb-marc21 project, written from the
  DNB-published MAB2 to MARC 21 concordance - "Konkordanz MAB2 - MARC 21,
  Teil 1: Konkordanz MAB-Titel - MARC-Bibliographic", commissioned by the
  Deutsche Nationalbibliothek, together with the MAB2 field directory
  (MAB2, Maschinelles Austauschformat für Bibliotheken, 2. Ausgabe with its
  supplements, DNB, <https://www.dnb.de/>) - and from the MARC 21 Format
  for Bibliographic Data on the target side. Nothing is copied from those
  documents.

  SOURCE REACHABILITY: the DNB and library-network hosts are refused by
  this environment's network egress policy, so the concordance itself could
  not be read line by line. The MAB2 side of every mapping below is the
  format's published field directory - the field numbers and their names -
  and the MARC 21 side is the published MARC 21 format. Fields whose MAB2
  identity could not be confirmed from that directory are NOT mapped; they
  are listed under LOSSES rather than guessed at.

  INPUT, and why it needs saying. MAB2 records arrive in two shapes:
    * MABxml (the DNB's XML serialization, <datensatz>/<feld nr=... ind=...>
      with <uf code=...> subfields); or
    * ISO 2709 with MAB2's own record label and its single-character
      indicator.
  This sheet expects NEITHER directly. It expects MARC 21 slim XML - the
  shape produced by reading the ISO 2709 file with
    read_marc('mab2.mrc', encoding := 'utf8')
  and writing it with COPY (FORMAT marcxml) - in which each MAB2 field is a
  <datafield> whose @tag is the MAB2 field number. MAB2 fields are largely
  subfield-less, so the sheet takes a field's content from subfield $a when
  the reader found one and from the field's text otherwise; both shapes
  work. A MABxml file must be turned into that shape first.

  WHAT THIS SHEET IS FOR. MAB2 is retired: the German-speaking networks and
  the DNB deliver MARC 21. Where the records can be re-obtained, that is by
  far the better path. This sheet is for legacy files nobody can re-supply.

  COVERAGE (MAB2 -> MARC 21), from the MAB2 field directory:
    001 Identifikationsnummer      -> 001
    002 Datum der Ersterfassung    -> 008/00-05 (YYYYMMDD read as YYMMDD)
    025 überregionale Identnummer  -> 035 $a
    100/104/108 Verfasser          -> 100 (the first) and 700 (the rest),
                                      $a; ind1 1 when the name is inverted
    200/204/208 Körperschaft       -> 110 (the first) and 710 (the rest),
                                      $a, ind1 2 (name in direct order)
    331 Hauptsachtitel             -> 245 $a
    335 Zusatz zum Sachtitel       -> 245 $b
    359 Verfasser-/Urheberangabe   -> 245 $c
    403 Ausgabebezeichnung         -> 250 $a
    410 Ort                        -> 264 _1 $a
    412 Verlag                     -> 264 _1 $b
    425 Erscheinungsjahr           -> 264 _1 $c and 008/07-10
    433 Umfangsangabe              -> 300 $a
    434 Illustrationsangabe        -> 300 $b
    435 Format                     -> 300 $c
    451 Gesamttitel                -> 490 0 $a
    455 Bandangabe                 -> 490 0 $v
    501 Fußnote (allgemein)        -> 500 $a
    540 ISBN                       -> 020 $a
    542 ISSN                       -> 022 $a
    700 Notation                   -> 084 $a
    902/907/912/917/922/927/932/937 Schlagwörter -> 650 _7 $a with
                                      $2 swd (the Schlagwortnormdatei, the
                                      subject authority these headings were
                                      taken from before it became part of
                                      the GND)

  THE LEADER AND 008, stated plainly:
    * The MAB2 record label is NOT interpreted. Its status and type codes
      do not sit where MARC 21 keeps them, and this sheet expects input
      that has already passed through a MARC-shaped reader. Every record
      therefore comes out as leader type 'a' (language material),
      bibliographic level 'm' (monograph). A file of serials needs
      leader/07 and 008 re-coded afterwards - the sheet says so rather than
      guessing per record.
    * 008 carries only what the record actually stated: the date entered
      from 002, the single publication date from 425 with type 's', and
      the country and language from the 'country' and 'language'
      parameters, which are EMPTY by default and produce '|||' - no
      country and no language is invented for a record that did not
      contain one.

  LOSSES AND EXCLUSIONS (deliberate):
    * Every MAB2 field not listed above is dropped, including the coded
      fields (030, 050, 051, 052 and their neighbours), the 4XX
      Gesamttitel-linking apparatus beyond 451/455, the 6XX
      Ausgabe-/Fußnoten blocks beyond 501, the local segment (MAB-Lokal,
      normally a separate record type) and the person/corporate authority
      segments. They are dropped rather than mapped because their identity
      could not be confirmed from the published field directory here.
    * MAB2 indicators are not read: they distinguish forms of a heading
      (Ansetzungsform and friends) that MARC 21 records elsewhere.
    * Subject chains lose their chain structure: each Schlagwort becomes
      its own 650 rather than subdivisions of one heading, because MAB2's
      chain links are not in the field content.
  XSLT 1.0 (xsltproc-friendly).
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    xmlns="http://www.loc.gov/MARC21/slim"
    exclude-result-prefixes="marc">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <!-- filled into 008/15-17 and 008/35-37 when given; '|||' when not -->
  <xsl:param name="country"/>
  <xsl:param name="language"/>

  <xsl:template match="/marc:collection">
    <collection>
      <xsl:apply-templates select="marc:record"/>
    </collection>
  </xsl:template>

  <!-- a MAB2 field's content: $a when the reader found subfields, the
       field's own text when it did not (MAB2 fields are largely
       subfield-less) -->
  <xsl:template name="mb-content">
    <xsl:choose>
      <xsl:when test="marc:subfield[@code='a']">
        <xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/>
      </xsl:when>
      <xsl:when test="marc:subfield">
        <xsl:value-of select="normalize-space(marc:subfield[1])"/>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="normalize-space(.)"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- one simple field: MARC tag, indicators, single subfield -->
  <xsl:template name="mb-simple">
    <xsl:param name="tag"/>
    <xsl:param name="ind1" select="' '"/>
    <xsl:param name="ind2" select="' '"/>
    <xsl:param name="code" select="'a'"/>
    <xsl:variable name="v">
      <xsl:call-template name="mb-content"/>
    </xsl:variable>
    <xsl:if test="$v != ''">
      <datafield tag="{$tag}" ind1="{$ind1}" ind2="{$ind2}">
        <subfield code="{$code}"><xsl:value-of select="$v"/></subfield>
      </datafield>
    </xsl:if>
  </xsl:template>

  <!-- a personal name: inverted names take ind1 1, direct order ind1 0 -->
  <xsl:template name="mb-person">
    <xsl:param name="tag"/>
    <xsl:variable name="v">
      <xsl:call-template name="mb-content"/>
    </xsl:variable>
    <xsl:if test="$v != ''">
      <datafield tag="{$tag}" ind2=" ">
        <xsl:attribute name="ind1">
          <xsl:choose>
            <xsl:when test="contains($v, ',')">1</xsl:when>
            <xsl:otherwise>0</xsl:otherwise>
          </xsl:choose>
        </xsl:attribute>
        <subfield code="a"><xsl:value-of select="$v"/></subfield>
      </datafield>
    </xsl:if>
  </xsl:template>

  <xsl:template match="/marc:record | marc:record">
    <xsl:variable name="entered">
      <xsl:for-each select="marc:datafield[@tag='002'][1]">
        <xsl:call-template name="mb-content"/>
      </xsl:for-each>
    </xsl:variable>
    <xsl:variable name="year">
      <xsl:for-each select="marc:datafield[@tag='425'][1]">
        <xsl:call-template name="mb-content"/>
      </xsl:for-each>
    </xsl:variable>
    <record>

      <!-- the MAB2 label is not interpreted; see the header -->
      <leader>00000nam a2200000 i 4500</leader>

      <xsl:for-each select="marc:datafield[@tag='001'][1]">
        <controlfield tag="001">
          <xsl:call-template name="mb-content"/>
        </controlfield>
      </xsl:for-each>

      <controlfield tag="008">
        <xsl:choose>
          <xsl:when test="string-length($entered) &gt;= 8">
            <xsl:value-of select="substring($entered, 3, 6)"/>
          </xsl:when>
          <xsl:otherwise><xsl:text>      </xsl:text></xsl:otherwise>
        </xsl:choose>
        <xsl:choose>
          <xsl:when test="string-length($year) &gt;= 4">
            <xsl:text>s</xsl:text>
            <xsl:value-of select="substring($year, 1, 4)"/>
            <xsl:text>    </xsl:text>
          </xsl:when>
          <xsl:otherwise><xsl:text>n        </xsl:text></xsl:otherwise>
        </xsl:choose>
        <xsl:choose>
          <xsl:when test="$country != ''">
            <xsl:value-of select="substring(concat($country, '   '), 1, 3)"/>
          </xsl:when>
          <xsl:otherwise><xsl:text>|||</xsl:text></xsl:otherwise>
        </xsl:choose>
        <xsl:text>|||||||||||||||||</xsl:text>
        <xsl:choose>
          <xsl:when test="$language != ''">
            <xsl:value-of select="substring(concat($language, '   '), 1, 3)"/>
          </xsl:when>
          <xsl:otherwise><xsl:text>|||</xsl:text></xsl:otherwise>
        </xsl:choose>
        <xsl:text> d</xsl:text>
      </controlfield>

      <!-- 020 ISBN, 022 ISSN -->
      <xsl:for-each select="marc:datafield[@tag='540']">
        <xsl:call-template name="mb-simple">
          <xsl:with-param name="tag" select="'020'"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='542']">
        <xsl:call-template name="mb-simple">
          <xsl:with-param name="tag" select="'022'"/>
        </xsl:call-template>
      </xsl:for-each>

      <!-- 035 from the supra-regional identification number -->
      <xsl:for-each select="marc:datafield[@tag='025']">
        <xsl:call-template name="mb-simple">
          <xsl:with-param name="tag" select="'035'"/>
        </xsl:call-template>
      </xsl:for-each>

      <!-- 084 classification -->
      <xsl:for-each select="marc:datafield[@tag='700']">
        <xsl:call-template name="mb-simple">
          <xsl:with-param name="tag" select="'084'"/>
        </xsl:call-template>
      </xsl:for-each>

      <!-- main entry: first Verfasser, else first Körperschaft -->
      <xsl:for-each select="marc:datafield[@tag='100'][1]">
        <xsl:call-template name="mb-person">
          <xsl:with-param name="tag" select="'100'"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:if test="not(marc:datafield[@tag='100'])">
        <xsl:for-each select="marc:datafield[@tag='200'][1]">
          <xsl:call-template name="mb-simple">
            <xsl:with-param name="tag" select="'110'"/>
            <xsl:with-param name="ind1" select="'2'"/>
          </xsl:call-template>
        </xsl:for-each>
      </xsl:if>

      <!-- 245 from Hauptsachtitel + Zusatz + Verfasserangabe -->
      <xsl:if test="marc:datafield[@tag='331']">
        <datafield tag="245" ind1="0" ind2="0">
          <xsl:for-each select="marc:datafield[@tag='331'][1]">
            <subfield code="a"><xsl:call-template name="mb-content"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:datafield[@tag='335'][1]">
            <subfield code="b"><xsl:call-template name="mb-content"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:datafield[@tag='359'][1]">
            <subfield code="c"><xsl:call-template name="mb-content"/></subfield>
          </xsl:for-each>
        </datafield>
      </xsl:if>

      <!-- 250 edition -->
      <xsl:for-each select="marc:datafield[@tag='403']">
        <xsl:call-template name="mb-simple">
          <xsl:with-param name="tag" select="'250'"/>
        </xsl:call-template>
      </xsl:for-each>

      <!-- 264 publication -->
      <xsl:if test="marc:datafield[@tag='410' or @tag='412' or @tag='425']">
        <datafield tag="264" ind1=" " ind2="1">
          <xsl:for-each select="marc:datafield[@tag='410'][1]">
            <subfield code="a"><xsl:call-template name="mb-content"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:datafield[@tag='412'][1]">
            <subfield code="b"><xsl:call-template name="mb-content"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:datafield[@tag='425'][1]">
            <subfield code="c"><xsl:call-template name="mb-content"/></subfield>
          </xsl:for-each>
        </datafield>
      </xsl:if>

      <!-- 300 physical description -->
      <xsl:if test="marc:datafield[@tag='433' or @tag='434' or @tag='435']">
        <datafield tag="300" ind1=" " ind2=" ">
          <xsl:for-each select="marc:datafield[@tag='433'][1]">
            <subfield code="a"><xsl:call-template name="mb-content"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:datafield[@tag='434'][1]">
            <subfield code="b"><xsl:call-template name="mb-content"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:datafield[@tag='435'][1]">
            <subfield code="c"><xsl:call-template name="mb-content"/></subfield>
          </xsl:for-each>
        </datafield>
      </xsl:if>

      <!-- 490 series -->
      <xsl:if test="marc:datafield[@tag='451']">
        <datafield tag="490" ind1="0" ind2=" ">
          <xsl:for-each select="marc:datafield[@tag='451'][1]">
            <subfield code="a"><xsl:call-template name="mb-content"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:datafield[@tag='455'][1]">
            <subfield code="v"><xsl:call-template name="mb-content"/></subfield>
          </xsl:for-each>
        </datafield>
      </xsl:if>

      <!-- 500 general notes -->
      <xsl:for-each select="marc:datafield[@tag='501']">
        <xsl:call-template name="mb-simple">
          <xsl:with-param name="tag" select="'500'"/>
        </xsl:call-template>
      </xsl:for-each>

      <!-- 650 subject headings, one per Schlagwort of the chain -->
      <xsl:for-each select="marc:datafield[@tag='902' or @tag='907' or @tag='912'
                            or @tag='917' or @tag='922' or @tag='927'
                            or @tag='932' or @tag='937']">
        <xsl:variable name="v">
          <xsl:call-template name="mb-content"/>
        </xsl:variable>
        <xsl:if test="$v != ''">
          <datafield tag="650" ind1=" " ind2="7">
            <subfield code="a"><xsl:value-of select="$v"/></subfield>
            <subfield code="2">swd</subfield>
          </datafield>
        </xsl:if>
      </xsl:for-each>

      <!-- added entries: the remaining Verfasser and Körperschaften -->
      <xsl:for-each select="marc:datafield[@tag='104' or @tag='108']">
        <xsl:call-template name="mb-person">
          <xsl:with-param name="tag" select="'700'"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='204' or @tag='208']
                            | marc:datafield[@tag='200'][1][../marc:datafield[@tag='100']]">
        <xsl:call-template name="mb-simple">
          <xsl:with-param name="tag" select="'710'"/>
          <xsl:with-param name="ind1" select="'2'"/>
        </xsl:call-template>
      </xsl:for-each>

    </record>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
