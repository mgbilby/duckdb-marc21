<?xml version="1.0" encoding="UTF-8"?>
<!--
  marcxml-to-edm.xsl - MARCXML (slim) bibliographic records to Europeana
  Data Model (EDM) RDF/XML.

  Original crosswalk for the duckdb-marc21 project, written against
  Europeana's openly published "Definition of the Europeana Data Model"
  and "EDM Mapping Guidelines" (https://pro.europeana.eu/page/edm-
  documentation) - referenced, not copied. The descriptive property
  choices deliberately track this project's Dublin Core crosswalk
  (xslt/marcxml-to-oai_dc.xsl) so both exports say the same thing.

  Each record yields:
    edm:ProvidedCHO  rdf:about = {base-uri}{001}
      dc:title (245), dc:creator (1XX), dc:contributor (7XX),
      dc:publisher (260/264 $b), dcterms:issued (26X $c else 008/07-10),
      dc:language (008/35-37 + 041 $a), dc:subject (6XX, double-dash
      subdivisions), dc:description (500/505/520), dcterms:extent (300 $a),
      dc:identifier (001, 020/022/024 $a), dcterms:isPartOf (490 $a),
      edm:type from leader/06: TEXT (a t c d m p), IMAGE (e f k),
      SOUND (i j), VIDEO (g), 3D (r)
    ore:Aggregation  rdf:about = {base-uri}{001}#aggregation
      edm:aggregatedCHO, edm:dataProvider (parameter), edm:provider
      (parameter), edm:isShownAt from the first 856 $u, edm:rights
      (parameter, omitted when empty - real Europeana submissions
      REQUIRE it, so set it)

  Honest subset: no edm:WebResource detail, no contextual classes
  (edm:Agent/edm:Place/edm:TimeSpan/skos:Concept), no edm:isShownBy vs
  isShownAt distinction (every 856 is treated as a view). Parameters:
  data-provider, provider, rights, base-uri. XSLT 1.0 (xsltproc-friendly).
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:dcterms="http://purl.org/dc/terms/"
    xmlns:edm="http://www.europeana.eu/schemas/edm/"
    xmlns:ore="http://www.openarchives.org/ore/terms/"
    exclude-result-prefixes="marc">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:param name="data-provider" select="'Unnamed data provider'"/>
  <xsl:param name="provider" select="'Unnamed provider'"/>
  <xsl:param name="rights" select="''"/>
  <xsl:param name="base-uri" select="'urn:marc:'"/>

  <xsl:template match="/">
    <rdf:RDF>
      <xsl:apply-templates select="//marc:record"/>
    </rdf:RDF>
  </xsl:template>

  <xsl:template name="ed-chomp">
    <xsl:param name="s"/>
    <xsl:variable name="t" select="normalize-space($s)"/>
    <xsl:variable name="n" select="string-length($t)"/>
    <xsl:choose>
      <xsl:when test="$n = 0"/>
      <xsl:when test="contains(',;:/=', substring($t, $n, 1))
                      or (substring($t, $n, 1) = '.'
                          and not(substring($t, $n - 1, 1) = '.'))">
        <xsl:call-template name="ed-chomp">
          <xsl:with-param name="s" select="substring($t, 1, $n - 1)"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$t"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template match="marc:record">
    <xsl:variable name="id">
      <xsl:choose>
        <xsl:when test="marc:controlfield[@tag='001']">
          <xsl:value-of select="normalize-space(marc:controlfield[@tag='001'][1])"/>
        </xsl:when>
        <xsl:otherwise>rec-<xsl:value-of select="position()"/></xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="cho" select="concat($base-uri, $id)"/>
    <xsl:variable name="l6" select="substring(marc:leader, 7, 1)"/>
    <xsl:variable name="f008" select="marc:controlfield[@tag='008'][1]"/>

    <edm:ProvidedCHO rdf:about="{$cho}">
      <xsl:for-each select="marc:datafield[@tag='245'][1]">
        <dc:title>
          <xsl:variable name="t">
            <xsl:call-template name="ed-chomp">
              <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
            </xsl:call-template>
          </xsl:variable>
          <xsl:variable name="b">
            <xsl:call-template name="ed-chomp">
              <xsl:with-param name="s" select="marc:subfield[@code='b'][1]"/>
            </xsl:call-template>
          </xsl:variable>
          <xsl:value-of select="$t"/>
          <xsl:if test="$b != ''"> : <xsl:value-of select="$b"/></xsl:if>
        </dc:title>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='100' or @tag='110' or @tag='111']">
        <dc:creator>
          <xsl:call-template name="ed-chomp">
            <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
          </xsl:call-template>
        </dc:creator>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='700' or @tag='710' or @tag='711']">
        <dc:contributor>
          <xsl:call-template name="ed-chomp">
            <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
          </xsl:call-template>
        </dc:contributor>
      </xsl:for-each>
      <xsl:for-each select="(marc:datafield[@tag='264'][@ind2='1']
                             | marc:datafield[@tag='260'])[1]/marc:subfield[@code='b'][1]">
        <dc:publisher>
          <xsl:call-template name="ed-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dc:publisher>
      </xsl:for-each>
      <xsl:choose>
        <xsl:when test="marc:datafield[@tag='260' or @tag='264']/marc:subfield[@code='c']">
          <dcterms:issued>
            <xsl:call-template name="ed-chomp">
              <xsl:with-param name="s"
                  select="translate(marc:datafield[@tag='260' or @tag='264']
                          /marc:subfield[@code='c'][1], '[]', '')"/>
            </xsl:call-template>
          </dcterms:issued>
        </xsl:when>
        <xsl:when test="string-length(normalize-space(translate(
                            substring($f008, 8, 4), 'u|', ''))) = 4">
          <dcterms:issued><xsl:value-of select="substring($f008, 8, 4)"/></dcterms:issued>
        </xsl:when>
      </xsl:choose>
      <xsl:if test="string-length(normalize-space(substring($f008, 36, 3))) = 3
                    and substring($f008, 36, 3) != '|||'">
        <dc:language><xsl:value-of select="substring($f008, 36, 3)"/></dc:language>
      </xsl:if>
      <xsl:for-each select="marc:datafield[@tag='041']/marc:subfield[@code='a']">
        <xsl:if test="normalize-space(.) != substring($f008, 36, 3)">
          <dc:language><xsl:value-of select="normalize-space(.)"/></dc:language>
        </xsl:if>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='600' or @tag='610' or @tag='611'
                            or @tag='630' or @tag='650' or @tag='651' or @tag='653']">
        <dc:subject>
          <xsl:for-each select="marc:subfield[contains('abcdqtxyzv', @code)]">
            <xsl:if test="position() &gt; 1">
              <xsl:choose>
                <xsl:when test="contains('xyzv', @code)">--</xsl:when>
                <xsl:otherwise><xsl:text> </xsl:text></xsl:otherwise>
              </xsl:choose>
            </xsl:if>
            <xsl:call-template name="ed-chomp">
              <xsl:with-param name="s" select="."/>
            </xsl:call-template>
          </xsl:for-each>
        </dc:subject>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='500' or @tag='505' or @tag='520']">
        <dc:description>
          <xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/>
        </dc:description>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='300'][1]/marc:subfield[@code='a'][1]">
        <dcterms:extent>
          <xsl:call-template name="ed-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dcterms:extent>
      </xsl:for-each>
      <dc:identifier><xsl:value-of select="$id"/></dc:identifier>
      <xsl:for-each select="marc:datafield[@tag='020' or @tag='022' or @tag='024']
                            /marc:subfield[@code='a']">
        <dc:identifier><xsl:value-of select="normalize-space(.)"/></dc:identifier>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='490' or @tag='830'][1]/marc:subfield[@code='a'][1]">
        <dcterms:isPartOf>
          <xsl:call-template name="ed-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dcterms:isPartOf>
      </xsl:for-each>
      <edm:type>
        <xsl:choose>
          <xsl:when test="$l6 = 'i' or $l6 = 'j'">SOUND</xsl:when>
          <xsl:when test="$l6 = 'g'">VIDEO</xsl:when>
          <xsl:when test="$l6 = 'e' or $l6 = 'f' or $l6 = 'k'">IMAGE</xsl:when>
          <xsl:when test="$l6 = 'r'">3D</xsl:when>
          <xsl:otherwise>TEXT</xsl:otherwise>
        </xsl:choose>
      </edm:type>
    </edm:ProvidedCHO>

    <ore:Aggregation rdf:about="{$cho}#aggregation">
      <edm:aggregatedCHO rdf:resource="{$cho}"/>
      <edm:dataProvider><xsl:value-of select="$data-provider"/></edm:dataProvider>
      <edm:provider><xsl:value-of select="$provider"/></edm:provider>
      <xsl:for-each select="marc:datafield[@tag='856']/marc:subfield[@code='u'][1]">
        <edm:isShownAt rdf:resource="{normalize-space(.)}"/>
      </xsl:for-each>
      <xsl:if test="$rights != ''">
        <edm:rights rdf:resource="{$rights}"/>
      </xsl:if>
    </ore:Aggregation>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
