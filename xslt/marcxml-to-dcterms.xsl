<?xml version="1.0" encoding="UTF-8"?>
<!--
  marcxml-to-dcterms.xsl - MARCXML (slim) to qualified Dublin Core using
  the DCMI Metadata Terms namespace (http://purl.org/dc/terms/).

  Original crosswalk for the duckdb-marc21 project, written from:
    * the DCMI Metadata Terms specification (dublincore.org/specifications/
      dublin-core/dcmi-terms/) for the target element set and refinement
      semantics (alternative, issued, extent, medium, spatial, temporal,
      abstract, tableOfContents, isPartOf, bibliographicCitation,
      accessRights, provenance, audience),
    * the Library of Congress MARC 21 bibliographic format documentation
      for the source fields.

  This differs from the companion marcxml-to-rdfdc.xsl on purpose: that
  one emits RDF/XML descriptions; this one emits plain qualified-DC
  element records for XML consumers that want dcterms without RDF.
  There is no DCMI-defined container for a bag of dcterms records, so a
  collection input gets a neutral no-namespace <qdcRecords> wrapper of
  <qdcRecord> elements and a bare marc:record input yields one bare
  <qdcRecord> (the same convention marcxml-to-oai_dc.xsl uses).

  XSLT 1.0, xsltproc-friendly.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    xmlns:dcterms="http://purl.org/dc/terms/"
    exclude-result-prefixes="marc">

  <xsl:include href="marc-utils.xsl"/>

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:template match="/marc:collection">
    <qdcRecords>
      <xsl:apply-templates select="marc:record"/>
    </qdcRecords>
  </xsl:template>

  <xsl:template match="/marc:record | marc:record">
    <qdcRecord>

      <!-- dcterms:title : 245; alternatives : 130/240/246 and 880-linked 245 -->
      <xsl:for-each select="marc:datafield[@tag='245']">
        <dcterms:title>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s">
              <xsl:call-template name="mu-field-text">
                <xsl:with-param name="want" select="'abnp'"/>
              </xsl:call-template>
            </xsl:with-param>
          </xsl:call-template>
        </dcterms:title>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='130' or @tag='240' or @tag='246']
                            | marc:datafield[@tag='880'][starts-with(
                                  normalize-space(marc:subfield[@code='6']), '245')]">
        <dcterms:alternative>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s">
              <xsl:call-template name="mu-field-text">
                <xsl:with-param name="want" select="'abnp'"/>
              </xsl:call-template>
            </xsl:with-param>
          </xsl:call-template>
        </dcterms:alternative>
      </xsl:for-each>

      <!-- agents -->
      <xsl:for-each select="marc:datafield[@tag='100' or @tag='110' or @tag='111']">
        <dcterms:creator>
          <xsl:call-template name="qdc-agent"/>
        </dcterms:creator>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='700' or @tag='710' or @tag='711'
                            or @tag='720']">
        <dcterms:contributor>
          <xsl:call-template name="qdc-agent"/>
        </dcterms:contributor>
      </xsl:for-each>

      <!-- subjects, with the spatial/temporal refinements split out -->
      <xsl:for-each select="marc:datafield[@tag='600' or @tag='610' or @tag='611'
                            or @tag='630' or @tag='650' or @tag='653']">
        <dcterms:subject>
          <xsl:for-each select="marc:subfield[contains('abcdqtxyzv', @code)]">
            <xsl:if test="position() &gt; 1">
              <xsl:choose>
                <xsl:when test="contains('xyzv', @code)">--</xsl:when>
                <xsl:otherwise><xsl:text> </xsl:text></xsl:otherwise>
              </xsl:choose>
            </xsl:if>
            <xsl:call-template name="mu-chomp">
              <xsl:with-param name="s" select="."/>
            </xsl:call-template>
          </xsl:for-each>
        </dcterms:subject>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='651']/marc:subfield[@code='a']
                            | marc:datafield[@tag='650']/marc:subfield[@code='z']
                            | marc:datafield[@tag='662']/marc:subfield[@code='a']
                            | marc:datafield[@tag='752']">
        <dcterms:spatial>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dcterms:spatial>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='648']/marc:subfield[@code='a']
                            | marc:datafield[@tag='650']/marc:subfield[@code='y']">
        <dcterms:temporal>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dcterms:temporal>
      </xsl:for-each>

      <!-- descriptions: abstract (520), tableOfContents (505),
           audience (521), provenance (561), plain notes (500) -->
      <xsl:for-each select="marc:datafield[@tag='520']">
        <dcterms:abstract>
          <xsl:call-template name="mu-field-text">
            <xsl:with-param name="want" select="'ab'"/>
          </xsl:call-template>
        </dcterms:abstract>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='505']">
        <dcterms:tableOfContents>
          <xsl:call-template name="mu-field-text">
            <xsl:with-param name="want" select="'agrt'"/>
          </xsl:call-template>
        </dcterms:tableOfContents>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='521']">
        <dcterms:audience>
          <xsl:call-template name="mu-field-text">
            <xsl:with-param name="want" select="'ab'"/>
          </xsl:call-template>
        </dcterms:audience>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='561']">
        <dcterms:provenance>
          <xsl:call-template name="mu-field-text">
            <xsl:with-param name="want" select="'a'"/>
          </xsl:call-template>
        </dcterms:provenance>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='500']">
        <dcterms:description>
          <xsl:call-template name="mu-field-text">
            <xsl:with-param name="want" select="'a'"/>
          </xsl:call-template>
        </dcterms:description>
      </xsl:for-each>

      <!-- publication -->
      <xsl:for-each select="marc:datafield[@tag='260'
                            or (@tag='264' and (@ind2='1' or @ind2=' ' or @ind2=''))]
                            /marc:subfield[@code='b']">
        <dcterms:publisher>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dcterms:publisher>
      </xsl:for-each>
      <xsl:choose>
        <xsl:when test="marc:datafield[@tag='260' or @tag='264']
                        /marc:subfield[@code='c']">
          <xsl:for-each select="(marc:datafield[@tag='260' or @tag='264']
                                 /marc:subfield[@code='c'])[1]">
            <dcterms:issued>
              <xsl:call-template name="mu-unbracket">
                <xsl:with-param name="s">
                  <xsl:call-template name="mu-chomp">
                    <xsl:with-param name="s" select="."/>
                  </xsl:call-template>
                </xsl:with-param>
              </xsl:call-template>
            </dcterms:issued>
          </xsl:for-each>
        </xsl:when>
        <xsl:otherwise>
          <xsl:variable name="d8">
            <xsl:call-template name="mu-cf-slice">
              <xsl:with-param name="pos" select="7"/>
              <xsl:with-param name="len" select="4"/>
            </xsl:call-template>
          </xsl:variable>
          <xsl:if test="translate($d8, ' |u', '') != ''">
            <dcterms:issued><xsl:value-of select="normalize-space($d8)"/></dcterms:issued>
          </xsl:if>
        </xsl:otherwise>
      </xsl:choose>

      <!-- physical description: extent (300$a), medium (300$b), 340 -->
      <xsl:for-each select="marc:datafield[@tag='300']/marc:subfield[@code='a']">
        <dcterms:extent>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dcterms:extent>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='300']/marc:subfield[@code='b']
                            | marc:datafield[@tag='340']/marc:subfield[@code='a']">
        <dcterms:medium>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dcterms:medium>
      </xsl:for-each>

      <!-- type from the leader, format from 856$q -->
      <xsl:call-template name="qdc-type"/>
      <xsl:for-each select="marc:datafield[@tag='856']/marc:subfield[@code='q']">
        <dcterms:format><xsl:value-of select="normalize-space(.)"/></dcterms:format>
      </xsl:for-each>

      <!-- identifiers -->
      <xsl:for-each select="marc:controlfield[@tag='001']">
        <dcterms:identifier><xsl:value-of select="normalize-space(.)"/></dcterms:identifier>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='020']/marc:subfield[@code='a']">
        <xsl:variable name="i13">
          <xsl:call-template name="mu-isbn13">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </xsl:variable>
        <xsl:if test="$i13 != ''">
          <dcterms:identifier>
            <xsl:text>urn:isbn:</xsl:text>
            <xsl:value-of select="$i13"/>
          </dcterms:identifier>
        </xsl:if>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='022']/marc:subfield[@code='a']">
        <dcterms:identifier>
          <xsl:text>urn:issn:</xsl:text>
          <xsl:value-of select="normalize-space(.)"/>
        </dcterms:identifier>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='856']/marc:subfield[@code='u']">
        <dcterms:identifier><xsl:value-of select="normalize-space(.)"/></dcterms:identifier>
      </xsl:for-each>

      <!-- language: 008/35-37 then extra 041$a -->
      <xsl:variable name="lg8">
        <xsl:call-template name="mu-cf-slice">
          <xsl:with-param name="pos" select="35"/>
          <xsl:with-param name="len" select="3"/>
        </xsl:call-template>
      </xsl:variable>
      <xsl:if test="translate($lg8, ' |', '') != ''">
        <dcterms:language><xsl:value-of select="$lg8"/></dcterms:language>
      </xsl:if>
      <xsl:for-each select="marc:datafield[@tag='041']/marc:subfield[@code='a']">
        <xsl:if test="normalize-space(.) != $lg8">
          <dcterms:language><xsl:value-of select="normalize-space(.)"/></dcterms:language>
        </xsl:if>
      </xsl:for-each>

      <!-- aggregation relations -->
      <xsl:for-each select="marc:datafield[@tag='440' or @tag='490'
                            or @tag='773' or @tag='830']">
        <dcterms:isPartOf>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s">
              <xsl:call-template name="mu-field-text">
                <xsl:with-param name="want" select="'atnpv'"/>
              </xsl:call-template>
            </xsl:with-param>
          </xsl:call-template>
        </dcterms:isPartOf>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='773']/marc:subfield[@code='g']">
        <dcterms:bibliographicCitation>
          <xsl:value-of select="normalize-space(.)"/>
        </dcterms:bibliographicCitation>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='780']/marc:subfield[@code='t']">
        <dcterms:replaces>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dcterms:replaces>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='785']/marc:subfield[@code='t']">
        <dcterms:isReplacedBy>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dcterms:isReplacedBy>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='776']/marc:subfield[@code='t']">
        <dcterms:hasFormat>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dcterms:hasFormat>
      </xsl:for-each>

      <!-- rights -->
      <xsl:for-each select="marc:datafield[@tag='506']">
        <dcterms:accessRights>
          <xsl:call-template name="mu-field-text">
            <xsl:with-param name="want" select="'abcd'"/>
          </xsl:call-template>
        </dcterms:accessRights>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='540']">
        <dcterms:rights>
          <xsl:call-template name="mu-field-text">
            <xsl:with-param name="want" select="'abcd'"/>
          </xsl:call-template>
        </dcterms:rights>
      </xsl:for-each>
    </qdcRecord>
  </xsl:template>

  <!-- one agent label from a name field -->
  <xsl:template name="qdc-agent">
    <xsl:call-template name="mu-chomp">
      <xsl:with-param name="s">
        <xsl:call-template name="mu-field-text">
          <xsl:with-param name="want" select="'abcdq'"/>
        </xsl:call-template>
      </xsl:with-param>
    </xsl:call-template>
  </xsl:template>

  <!-- DCMI Type Vocabulary term from leader/06-07 -->
  <xsl:template name="qdc-type">
    <xsl:variable name="l6">
      <xsl:call-template name="mu-leader-at">
        <xsl:with-param name="pos" select="6"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="l7">
      <xsl:call-template name="mu-leader-at">
        <xsl:with-param name="pos" select="7"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:if test="$l7 = 'c'">
      <dcterms:type>Collection</dcterms:type>
    </xsl:if>
    <xsl:choose>
      <xsl:when test="$l6='a' or $l6='t' or $l6='c' or $l6='d'">
        <dcterms:type>Text</dcterms:type>
      </xsl:when>
      <xsl:when test="$l6='e' or $l6='f' or $l6='k'">
        <dcterms:type>StillImage</dcterms:type>
      </xsl:when>
      <xsl:when test="$l6='g'"><dcterms:type>MovingImage</dcterms:type></xsl:when>
      <xsl:when test="$l6='i' or $l6='j'"><dcterms:type>Sound</dcterms:type></xsl:when>
      <xsl:when test="$l6='m'"><dcterms:type>Software</dcterms:type></xsl:when>
      <xsl:when test="$l6='r'"><dcterms:type>PhysicalObject</dcterms:type></xsl:when>
    </xsl:choose>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
