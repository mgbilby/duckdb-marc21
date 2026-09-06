<?xml version="1.0" encoding="UTF-8"?>
<!--
  marcxml-to-rdfdc.xsl - MARCXML (slim) to RDF/XML built on DCMI Metadata
  Terms (dcterms).

  Original crosswalk for the duckdb-marc21 project. Follows the Library
  of Congress MARC-to-Dublin-Core mapping semantics but emits the
  refined dcterms vocabulary rather than the 15 simple elements, so
  dates, extents and part-of relations keep their meaning.

  Each MARC record becomes one rdf:Description. When the record carries
  an 856$u the first URL becomes rdf:about; otherwise the description
  stays a blank node carrying dcterms:identifier values. rdf:RDF holds
  any number of descriptions, so collections and single records need no
  special casing. XSLT 1.0.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    xmlns:dcterms="http://purl.org/dc/terms/"
    exclude-result-prefixes="marc">

  <xsl:include href="marc-utils.xsl"/>

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:template match="/">
    <rdf:RDF>
      <xsl:apply-templates select="//marc:record"/>
    </rdf:RDF>
  </xsl:template>

  <xsl:template match="marc:record">
    <rdf:Description>
      <xsl:if test="marc:datafield[@tag='856']/marc:subfield[@code='u']">
        <xsl:attribute name="rdf:about">
          <xsl:value-of
              select="normalize-space(marc:datafield[@tag='856']/marc:subfield[@code='u'][1])"/>
        </xsl:attribute>
      </xsl:if>

      <!-- titles -->
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
      <xsl:for-each select="marc:datafield[@tag='246']
                            | marc:datafield[@tag='880']
                              [starts-with(normalize-space(marc:subfield[@code='6']), '245')]">
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
          <xsl:call-template name="rdf-agent-label"/>
        </dcterms:creator>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='700' or @tag='710' or @tag='711' or @tag='720']">
        <dcterms:contributor>
          <xsl:call-template name="rdf-agent-label"/>
        </dcterms:contributor>
      </xsl:for-each>

      <!-- topical access -->
      <xsl:for-each select="marc:datafield[@tag='600' or @tag='610' or @tag='611'
                            or @tag='630' or @tag='650' or @tag='653']">
        <dcterms:subject>
          <xsl:for-each select="marc:subfield[contains('abcdqtxy', @code)]">
            <xsl:if test="position() &gt; 1">--</xsl:if>
            <xsl:call-template name="mu-chomp">
              <xsl:with-param name="s" select="."/>
            </xsl:call-template>
          </xsl:for-each>
        </dcterms:subject>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='651']/marc:subfield[@code='a']
                            | marc:datafield[@tag='650']/marc:subfield[@code='z']">
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

      <!-- descriptions -->
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
      <xsl:variable name="year8">
        <xsl:call-template name="mu-cf-slice">
          <xsl:with-param name="pos" select="7"/>
          <xsl:with-param name="len" select="4"/>
        </xsl:call-template>
      </xsl:variable>
      <xsl:choose>
        <xsl:when test="translate($year8, ' |u', '') != ''">
          <dcterms:issued><xsl:value-of select="normalize-space($year8)"/></dcterms:issued>
        </xsl:when>
        <xsl:otherwise>
          <xsl:for-each select="marc:datafield[@tag='260' or @tag='264']
                                /marc:subfield[@code='c'][1]">
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
        </xsl:otherwise>
      </xsl:choose>

      <!-- carrier -->
      <xsl:for-each select="marc:datafield[@tag='300']/marc:subfield[@code='a']">
        <dcterms:extent>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dcterms:extent>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='856']/marc:subfield[@code='q']">
        <dcterms:format><xsl:value-of select="normalize-space(.)"/></dcterms:format>
      </xsl:for-each>

      <!-- type -->
      <xsl:call-template name="rdf-dcmi-type"/>
      <xsl:for-each select="marc:datafield[@tag='655']/marc:subfield[@code='a']">
        <dcterms:type>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dcterms:type>
      </xsl:for-each>

      <!-- identifiers -->
      <xsl:for-each select="marc:controlfield[@tag='001']">
        <dcterms:identifier><xsl:value-of select="normalize-space(.)"/></dcterms:identifier>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='020']/marc:subfield[@code='a']">
        <dcterms:identifier>
          <xsl:value-of select="concat('urn:isbn:', normalize-space(.))"/>
        </dcterms:identifier>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='022']/marc:subfield[@code='a']">
        <dcterms:identifier>
          <xsl:value-of select="concat('urn:issn:', normalize-space(.))"/>
        </dcterms:identifier>
      </xsl:for-each>

      <!-- language -->
      <xsl:variable name="lang8">
        <xsl:call-template name="mu-cf-slice">
          <xsl:with-param name="pos" select="35"/>
          <xsl:with-param name="len" select="3"/>
        </xsl:call-template>
      </xsl:variable>
      <xsl:if test="translate($lang8, ' |', '') != ''">
        <dcterms:language><xsl:value-of select="$lang8"/></dcterms:language>
      </xsl:if>

      <!-- relations -->
      <xsl:for-each select="marc:datafield[@tag='440' or @tag='490' or @tag='830'
                            or @tag='773']">
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
      <xsl:for-each select="marc:datafield[@tag='776' or @tag='775' or @tag='787']
                            /marc:subfield[@code='t']">
        <dcterms:relation>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dcterms:relation>
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
    </rdf:Description>
  </xsl:template>

  <!-- label for a 1XX/7XX access point -->
  <xsl:template name="rdf-agent-label">
    <xsl:call-template name="mu-chomp">
      <xsl:with-param name="s">
        <xsl:call-template name="mu-field-text">
          <xsl:with-param name="want" select="'abcdq'"/>
        </xsl:call-template>
      </xsl:with-param>
    </xsl:call-template>
  </xsl:template>

  <!-- DCMI type vocabulary term as an rdf:resource reference -->
  <xsl:template name="rdf-dcmi-type">
    <xsl:variable name="l6">
      <xsl:call-template name="mu-leader-at">
        <xsl:with-param name="pos" select="6"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="term">
      <xsl:choose>
        <xsl:when test="$l6='a' or $l6='t' or $l6='c' or $l6='d'">Text</xsl:when>
        <xsl:when test="$l6='e' or $l6='f' or $l6='k'">StillImage</xsl:when>
        <xsl:when test="$l6='g'">MovingImage</xsl:when>
        <xsl:when test="$l6='i' or $l6='j'">Sound</xsl:when>
        <xsl:when test="$l6='m'">Software</xsl:when>
        <xsl:when test="$l6='r'">PhysicalObject</xsl:when>
        <xsl:when test="$l6='p'">Collection</xsl:when>
      </xsl:choose>
    </xsl:variable>
    <xsl:if test="string-length($term) &gt; 0">
      <dcterms:type
          rdf:resource="http://purl.org/dc/dcmitype/{$term}"/>
    </xsl:if>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
