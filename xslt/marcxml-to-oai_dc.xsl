<?xml version="1.0" encoding="UTF-8"?>
<!--
  marcxml-to-oai_dc.xsl - MARCXML (slim) to simple Dublin Core in the
  OAI-PMH oai_dc container.

  Original crosswalk for the duckdb-marc21 project, implemented from the
  Library of Congress "MARC to Dublin Core" mapping specification.

  Single records produce one oai_dc:dc document element. Collections
  produce a neutral <dcRecords> wrapper (no schema exists for a bag of
  oai_dc records; the wrapper is in no namespace on purpose). XSLT 1.0.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    xmlns:oai_dc="http://www.openarchives.org/OAI/2.0/oai_dc/"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    exclude-result-prefixes="marc">

  <xsl:include href="marc-utils.xsl"/>

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:template match="/marc:collection">
    <dcRecords>
      <xsl:apply-templates select="marc:record"/>
    </dcRecords>
  </xsl:template>

  <xsl:template match="/marc:record | marc:record">
    <oai_dc:dc
        xsi:schemaLocation="http://www.openarchives.org/OAI/2.0/oai_dc/ http://www.openarchives.org/OAI/2.0/oai_dc.xsd">

      <!-- dc:title : 245 / 246 -->
      <xsl:for-each select="marc:datafield[@tag='245' or @tag='246']">
        <dc:title>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s">
              <xsl:call-template name="mu-field-text">
                <xsl:with-param name="want" select="'abfgknps'"/>
              </xsl:call-template>
            </xsl:with-param>
          </xsl:call-template>
        </dc:title>
      </xsl:for-each>

      <!-- dc:creator : 1XX; dc:contributor : 7XX -->
      <xsl:for-each select="marc:datafield[@tag='100' or @tag='110' or @tag='111'
                            or @tag='700' or @tag='710' or @tag='711' or @tag='720']">
        <xsl:variable name="who">
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s">
              <xsl:call-template name="mu-field-text">
                <xsl:with-param name="want" select="'abcdq'"/>
              </xsl:call-template>
            </xsl:with-param>
          </xsl:call-template>
        </xsl:variable>
        <xsl:choose>
          <xsl:when test="starts-with(@tag, '1')">
            <dc:creator><xsl:value-of select="$who"/></dc:creator>
          </xsl:when>
          <xsl:otherwise>
            <dc:contributor><xsl:value-of select="$who"/></dc:contributor>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:for-each>

      <!-- dc:subject : 6XX headings, subdivisions joined with double dash -->
      <xsl:for-each select="marc:datafield[@tag='600' or @tag='610' or @tag='611'
                            or @tag='630' or @tag='650' or @tag='653']">
        <dc:subject>
          <xsl:for-each select="marc:subfield[contains('abcdqtxyzv', @code)]">
            <xsl:if test="position() &gt; 1">
              <xsl:choose>
                <xsl:when test="contains('xyzv', @code)">--</xsl:when>
                <xsl:otherwise><xsl:text> </xsl:text></xsl:otherwise>
              </xsl:choose>
            </xsl:if>
            <xsl:variable name="piece">
              <xsl:call-template name="mu-chomp">
                <xsl:with-param name="s" select="."/>
              </xsl:call-template>
            </xsl:variable>
            <xsl:value-of select="$piece"/>
          </xsl:for-each>
        </dc:subject>
      </xsl:for-each>

      <!-- dc:description : summaries, contents, general notes -->
      <xsl:for-each select="marc:datafield[@tag='500' or @tag='505' or @tag='520']">
        <dc:description>
          <xsl:call-template name="mu-field-text">
            <xsl:with-param name="want" select="'abgrt'"/>
          </xsl:call-template>
        </dc:description>
      </xsl:for-each>

      <!-- dc:publisher : 260$b / 264(ind2 1)$b -->
      <xsl:for-each select="marc:datafield[@tag='260'
                            or (@tag='264' and (@ind2='1' or @ind2=' ' or @ind2=''))]
                            /marc:subfield[@code='b']">
        <dc:publisher>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dc:publisher>
      </xsl:for-each>

      <!-- dc:date : imprint date, else 008/07-10 -->
      <xsl:choose>
        <xsl:when test="marc:datafield[@tag='260' or @tag='264']/marc:subfield[@code='c']">
          <xsl:for-each select="marc:datafield[@tag='260' or @tag='264']
                                /marc:subfield[@code='c']">
            <dc:date>
              <xsl:call-template name="mu-unbracket">
                <xsl:with-param name="s">
                  <xsl:call-template name="mu-chomp">
                    <xsl:with-param name="s" select="."/>
                  </xsl:call-template>
                </xsl:with-param>
              </xsl:call-template>
            </dc:date>
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
            <dc:date><xsl:value-of select="normalize-space($d8)"/></dc:date>
          </xsl:if>
        </xsl:otherwise>
      </xsl:choose>

      <!-- dc:type : leader/06-07 plus 655 genre terms -->
      <xsl:call-template name="dc-type"/>
      <xsl:for-each select="marc:datafield[@tag='655']/marc:subfield[@code='a']">
        <dc:type>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dc:type>
      </xsl:for-each>

      <!-- dc:format : 300$a and 856$q -->
      <xsl:for-each select="marc:datafield[@tag='300']/marc:subfield[@code='a']">
        <dc:format>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dc:format>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='856']/marc:subfield[@code='q']">
        <dc:format><xsl:value-of select="normalize-space(.)"/></dc:format>
      </xsl:for-each>

      <!-- dc:identifier : standard numbers and URLs -->
      <xsl:for-each select="marc:controlfield[@tag='001']">
        <dc:identifier><xsl:value-of select="normalize-space(.)"/></dc:identifier>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='010' or @tag='020' or @tag='022' or @tag='024']
                            /marc:subfield[@code='a']">
        <dc:identifier><xsl:value-of select="normalize-space(.)"/></dc:identifier>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='856']/marc:subfield[@code='u']">
        <dc:identifier><xsl:value-of select="normalize-space(.)"/></dc:identifier>
      </xsl:for-each>

      <!-- dc:language : 008/35-37 and 041$a -->
      <xsl:variable name="lg8">
        <xsl:call-template name="mu-cf-slice">
          <xsl:with-param name="pos" select="35"/>
          <xsl:with-param name="len" select="3"/>
        </xsl:call-template>
      </xsl:variable>
      <xsl:if test="translate($lg8, ' |', '') != ''">
        <dc:language><xsl:value-of select="$lg8"/></dc:language>
      </xsl:if>
      <xsl:for-each select="marc:datafield[@tag='041']/marc:subfield[@code='a']">
        <xsl:if test="normalize-space(.) != $lg8">
          <dc:language><xsl:value-of select="normalize-space(.)"/></dc:language>
        </xsl:if>
      </xsl:for-each>

      <!-- dc:relation : series and linking entries -->
      <xsl:for-each select="marc:datafield[@tag='440' or @tag='490' or @tag='830']">
        <dc:relation>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s">
              <xsl:call-template name="mu-field-text">
                <xsl:with-param name="want" select="'anpv'"/>
              </xsl:call-template>
            </xsl:with-param>
          </xsl:call-template>
        </dc:relation>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag &gt;= '760' and @tag &lt;= '787']
                            /marc:subfield[@code='t']">
        <dc:relation>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dc:relation>
      </xsl:for-each>

      <!-- dc:coverage : geographic access points -->
      <xsl:for-each select="marc:datafield[@tag='651']/marc:subfield[@code='a']
                            | marc:datafield[@tag='650']/marc:subfield[@code='z']
                            | marc:datafield[@tag='752']">
        <dc:coverage>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </dc:coverage>
      </xsl:for-each>

      <!-- dc:rights : access and use notes -->
      <xsl:for-each select="marc:datafield[@tag='506' or @tag='540']">
        <dc:rights>
          <xsl:call-template name="mu-field-text">
            <xsl:with-param name="want" select="'abcd'"/>
          </xsl:call-template>
        </dc:rights>
      </xsl:for-each>
    </oai_dc:dc>
  </xsl:template>

  <!-- leader-driven DCMI type -->
  <xsl:template name="dc-type">
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
      <dc:type>Collection</dc:type>
    </xsl:if>
    <xsl:choose>
      <xsl:when test="$l6='a' or $l6='t'"><dc:type>Text</dc:type></xsl:when>
      <xsl:when test="$l6='e' or $l6='f'"><dc:type>Image</dc:type></xsl:when>
      <xsl:when test="$l6='c' or $l6='d'"><dc:type>Text</dc:type></xsl:when>
      <xsl:when test="$l6='i' or $l6='j'"><dc:type>Sound</dc:type></xsl:when>
      <xsl:when test="$l6='k'"><dc:type>StillImage</dc:type></xsl:when>
      <xsl:when test="$l6='g'"><dc:type>MovingImage</dc:type></xsl:when>
      <xsl:when test="$l6='m'"><dc:type>Software</dc:type></xsl:when>
      <xsl:when test="$l6='r'"><dc:type>PhysicalObject</dc:type></xsl:when>
    </xsl:choose>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
