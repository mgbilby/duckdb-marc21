<?xml version="1.0" encoding="UTF-8"?>
<!--
  marcxml-to-mads.xsl - MARC 21 Authority records (MARCXML slim) to MADS
  2.x (Metadata Authority Description Schema).

  Original crosswalk for the duckdb-marc21 project, written against the
  Library of Congress MADS 2.x schema and its published MARC Authority
  mapping (https://www.loc.gov/standards/mads/ - LC standards documents,
  public domain). Input should be authority records (leader/06 = z), e.g.
  read with read_marc and exported via COPY (FORMAT marcxml).

  Mapping (honest subset):
    1XX -> mads:authority   100 name[@type=personal] ($a/$b nameParts,
                            $d namePart[@type=date], $q kept in $a's part),
                            110 corporate, 111 conference, 130 titleInfo,
                            150 topic, 151 geographic, 155 genre
    4XX -> mads:variant     same element choice by tag; @type=other
    5XX -> mads:related     @type from $w/0: g broader, h narrower,
                            a earlier, b later, else other
    667 -> mads:note        (untyped); 670 -> mads:note[@type=source]
                            ($a and $b concatenated)
    010 $a -> mads:identifier[@type=lccn]; 001 -> identifier[@type=local]
  Not mapped: 008 coded values, 260/360 complex references, 663/664/665,
  7XX linking entries, subdivisions ($v/$x/$y/$z) beyond the heading
  elements themselves. XSLT 1.0 (xsltproc-friendly).
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    xmlns:mads="http://www.loc.gov/mads/v2"
    exclude-result-prefixes="marc">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:template match="/marc:collection">
    <mads:madsCollection>
      <xsl:apply-templates select="marc:record"/>
    </mads:madsCollection>
  </xsl:template>

  <xsl:template name="ma-chomp">
    <xsl:param name="s"/>
    <xsl:variable name="t" select="normalize-space($s)"/>
    <xsl:variable name="n" select="string-length($t)"/>
    <xsl:choose>
      <xsl:when test="$n = 0"/>
      <xsl:when test="contains(',;:/=', substring($t, $n, 1))
                      or (substring($t, $n, 1) = '.'
                          and not(substring($t, $n - 1, 1) = '.')
                          and not(substring($t, $n - 2, 1) = ' '))">
        <xsl:call-template name="ma-chomp">
          <xsl:with-param name="s" select="substring($t, 1, $n - 1)"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$t"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- the heading content of one X00/X10/X11/X30/X50/X51/X55 field;
       call with the datafield as current node -->
  <xsl:template name="ma-heading">
    <xsl:variable name="t2" select="substring(@tag, 2, 2)"/>
    <xsl:choose>
      <xsl:when test="$t2 = '00'">
        <mads:name type="personal">
          <mads:namePart>
            <xsl:call-template name="ma-chomp">
              <xsl:with-param name="s">
                <xsl:for-each select="marc:subfield[@code='a' or @code='b' or @code='q']">
                  <xsl:if test="position() &gt; 1"><xsl:text> </xsl:text></xsl:if>
                  <xsl:value-of select="normalize-space(.)"/>
                </xsl:for-each>
              </xsl:with-param>
            </xsl:call-template>
          </mads:namePart>
          <xsl:for-each select="marc:subfield[@code='d']">
            <mads:namePart type="date">
              <xsl:call-template name="ma-chomp">
                <xsl:with-param name="s" select="."/>
              </xsl:call-template>
            </mads:namePart>
          </xsl:for-each>
        </mads:name>
      </xsl:when>
      <xsl:when test="$t2 = '10' or $t2 = '11'">
        <mads:name>
          <xsl:attribute name="type">
            <xsl:choose>
              <xsl:when test="$t2 = '10'">corporate</xsl:when>
              <xsl:otherwise>conference</xsl:otherwise>
            </xsl:choose>
          </xsl:attribute>
          <xsl:for-each select="marc:subfield[@code='a' or @code='b']">
            <mads:namePart>
              <xsl:call-template name="ma-chomp">
                <xsl:with-param name="s" select="."/>
              </xsl:call-template>
            </mads:namePart>
          </xsl:for-each>
        </mads:name>
      </xsl:when>
      <xsl:when test="$t2 = '30'">
        <mads:titleInfo>
          <mads:title>
            <xsl:call-template name="ma-chomp">
              <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
            </xsl:call-template>
          </mads:title>
        </mads:titleInfo>
      </xsl:when>
      <xsl:when test="$t2 = '51'">
        <mads:geographic>
          <xsl:call-template name="ma-chomp">
            <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
          </xsl:call-template>
        </mads:geographic>
      </xsl:when>
      <xsl:when test="$t2 = '55'">
        <mads:genre>
          <xsl:call-template name="ma-chomp">
            <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
          </xsl:call-template>
        </mads:genre>
      </xsl:when>
      <xsl:otherwise>
        <mads:topic>
          <xsl:call-template name="ma-chomp">
            <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
          </xsl:call-template>
        </mads:topic>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template match="/marc:record | marc:record">
    <mads:mads>
      <mads:authority>
        <xsl:for-each select="marc:datafield[@tag='100' or @tag='110' or @tag='111'
                              or @tag='130' or @tag='150' or @tag='151' or @tag='155'][1]">
          <xsl:call-template name="ma-heading"/>
        </xsl:for-each>
      </mads:authority>
      <xsl:for-each select="marc:datafield[@tag='400' or @tag='410' or @tag='411'
                            or @tag='430' or @tag='450' or @tag='451' or @tag='455']">
        <mads:variant type="other">
          <xsl:call-template name="ma-heading"/>
        </mads:variant>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='500' or @tag='510' or @tag='511'
                            or @tag='530' or @tag='550' or @tag='551' or @tag='555']">
        <mads:related>
          <xsl:attribute name="type">
            <xsl:choose>
              <xsl:when test="normalize-space(marc:subfield[@code='w'][1]) = 'g'">broader</xsl:when>
              <xsl:when test="normalize-space(marc:subfield[@code='w'][1]) = 'h'">narrower</xsl:when>
              <xsl:when test="normalize-space(marc:subfield[@code='w'][1]) = 'a'">earlier</xsl:when>
              <xsl:when test="normalize-space(marc:subfield[@code='w'][1]) = 'b'">later</xsl:when>
              <xsl:otherwise>other</xsl:otherwise>
            </xsl:choose>
          </xsl:attribute>
          <xsl:call-template name="ma-heading"/>
        </mads:related>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='667']">
        <mads:note><xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/></mads:note>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='670']">
        <mads:note type="source">
          <xsl:for-each select="marc:subfield[@code='a' or @code='b']">
            <xsl:if test="position() &gt; 1"><xsl:text> </xsl:text></xsl:if>
            <xsl:value-of select="normalize-space(.)"/>
          </xsl:for-each>
        </mads:note>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='010']/marc:subfield[@code='a']">
        <mads:identifier type="lccn"><xsl:value-of select="normalize-space(.)"/></mads:identifier>
      </xsl:for-each>
      <xsl:for-each select="marc:controlfield[@tag='001']">
        <mads:identifier type="local"><xsl:value-of select="normalize-space(.)"/></mads:identifier>
      </xsl:for-each>
    </mads:mads>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
