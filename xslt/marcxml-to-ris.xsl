<?xml version="1.0" encoding="UTF-8"?>
<!--
  marcxml-to-ris.xsl - MARCXML (slim) to RIS citation records
  (text output, one tagged reference per MARC record).

  Original crosswalk for the duckdb-marc21 project, written from:
    * the RIS format documentation as published for reference managers
      (the widely mirrored tag list: "XX  - value" lines, TY first,
      ER last, AU repeated per author, PY as a year),
    * the MARC 21 bibliographic format documentation for the sources.

  Reference type from leader/06-07:
      a,t + serial levels b,i,s -> JOUR      e,f -> MAP
      a,t                      -> BOOK       i,j -> SOUND
      g                        -> VIDEO      m   -> COMP
      anything else            -> GEN

  RIS is a line-oriented plain-text format with no escape mechanism,
  so embedded line breaks in field values are collapsed to single
  spaces (normalize-space); all other characters pass through
  unchanged. Records are separated by the mandatory ER line.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim">

  <xsl:include href="marc-utils.xsl"/>

  <xsl:output method="text" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:template match="/marc:collection">
    <xsl:apply-templates select="marc:record"/>
  </xsl:template>

  <xsl:template match="/marc:record | marc:record">
    <!-- TY : reference type -->
    <xsl:call-template name="ris-line">
      <xsl:with-param name="tag" select="'TY'"/>
      <xsl:with-param name="value">
        <xsl:call-template name="ris-type"/>
      </xsl:with-param>
    </xsl:call-template>

    <!-- AU : 100/110/111 then 700/710/711 -->
    <xsl:for-each select="marc:datafield[@tag='100' or @tag='110' or @tag='111'
                          or @tag='700' or @tag='710' or @tag='711']">
      <xsl:variable name="who">
        <xsl:call-template name="mu-chomp">
          <xsl:with-param name="s">
            <xsl:call-template name="mu-field-text">
              <xsl:with-param name="want" select="'abcdq'"/>
            </xsl:call-template>
          </xsl:with-param>
        </xsl:call-template>
      </xsl:variable>
      <xsl:call-template name="ris-line">
        <xsl:with-param name="tag">
          <xsl:choose>
            <xsl:when test="starts-with(@tag, '1')">AU</xsl:when>
            <xsl:otherwise>A2</xsl:otherwise>
          </xsl:choose>
        </xsl:with-param>
        <xsl:with-param name="value" select="$who"/>
      </xsl:call-template>
    </xsl:for-each>

    <!-- TI : 245 $a $b -->
    <xsl:for-each select="marc:datafield[@tag='245'][1]">
      <xsl:variable name="ti">
        <xsl:call-template name="mu-chomp">
          <xsl:with-param name="s">
            <xsl:call-template name="mu-field-text">
              <xsl:with-param name="want" select="'abnp'"/>
            </xsl:call-template>
          </xsl:with-param>
        </xsl:call-template>
      </xsl:variable>
      <xsl:call-template name="ris-line">
        <xsl:with-param name="tag" select="'TI'"/>
        <xsl:with-param name="value" select="$ti"/>
      </xsl:call-template>
    </xsl:for-each>

    <!-- T2 : host item title (773) for articles -->
    <xsl:for-each select="(marc:datafield[@tag='773']/marc:subfield[@code='t'])[1]">
      <xsl:call-template name="ris-line">
        <xsl:with-param name="tag" select="'T2'"/>
        <xsl:with-param name="value">
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </xsl:with-param>
      </xsl:call-template>
    </xsl:for-each>

    <!-- CY / PB : imprint place and publisher -->
    <xsl:for-each select="(marc:datafield[@tag='260' or @tag='264']
                           /marc:subfield[@code='a'])[1]">
      <xsl:call-template name="ris-line">
        <xsl:with-param name="tag" select="'CY'"/>
        <xsl:with-param name="value">
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </xsl:with-param>
      </xsl:call-template>
    </xsl:for-each>
    <xsl:for-each select="(marc:datafield[@tag='260' or @tag='264']
                           /marc:subfield[@code='b'])[1]">
      <xsl:call-template name="ris-line">
        <xsl:with-param name="tag" select="'PB'"/>
        <xsl:with-param name="value">
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </xsl:with-param>
      </xsl:call-template>
    </xsl:for-each>

    <!-- PY : year from the imprint date, else 008/07-10 -->
    <xsl:variable name="py">
      <xsl:choose>
        <xsl:when test="marc:datafield[@tag='260' or @tag='264']
                        /marc:subfield[@code='c']">
          <xsl:call-template name="mu-first-year">
            <xsl:with-param name="s"
                select="(marc:datafield[@tag='260' or @tag='264']
                         /marc:subfield[@code='c'])[1]"/>
          </xsl:call-template>
        </xsl:when>
        <xsl:otherwise>
          <xsl:variable name="d8">
            <xsl:call-template name="mu-cf-slice">
              <xsl:with-param name="pos" select="7"/>
              <xsl:with-param name="len" select="4"/>
            </xsl:call-template>
          </xsl:variable>
          <xsl:call-template name="mu-first-year">
            <xsl:with-param name="s" select="$d8"/>
          </xsl:call-template>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:call-template name="ris-line">
      <xsl:with-param name="tag" select="'PY'"/>
      <xsl:with-param name="value" select="$py"/>
    </xsl:call-template>

    <!-- SN : ISBN (020$a) and ISSN (022$a, 773$x) -->
    <xsl:for-each select="marc:datafield[@tag='020' or @tag='022']
                          /marc:subfield[@code='a']
                          | marc:datafield[@tag='773']/marc:subfield[@code='x']">
      <xsl:call-template name="ris-line">
        <xsl:with-param name="tag" select="'SN'"/>
        <xsl:with-param name="value" select="normalize-space(.)"/>
      </xsl:call-template>
    </xsl:for-each>

    <!-- UR : 856$u -->
    <xsl:for-each select="marc:datafield[@tag='856']/marc:subfield[@code='u']">
      <xsl:call-template name="ris-line">
        <xsl:with-param name="tag" select="'UR'"/>
        <xsl:with-param name="value" select="normalize-space(.)"/>
      </xsl:call-template>
    </xsl:for-each>

    <!-- KW : one line per 6XX heading ($a) -->
    <xsl:for-each select="marc:datafield[starts-with(@tag, '6')]
                          /marc:subfield[@code='a']">
      <xsl:call-template name="ris-line">
        <xsl:with-param name="tag" select="'KW'"/>
        <xsl:with-param name="value">
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </xsl:with-param>
      </xsl:call-template>
    </xsl:for-each>

    <!-- N1 : summary note -->
    <xsl:for-each select="(marc:datafield[@tag='520']/marc:subfield[@code='a'])[1]">
      <xsl:call-template name="ris-line">
        <xsl:with-param name="tag" select="'N1'"/>
        <xsl:with-param name="value" select="normalize-space(.)"/>
      </xsl:call-template>
    </xsl:for-each>

    <!-- ER : end of reference (always emitted, even when empty) -->
    <xsl:text>ER  - &#10;</xsl:text>
  </xsl:template>

  <!-- one "TAG  - value" line; skipped entirely for an empty value,
       except that the caller emits ER itself -->
  <xsl:template name="ris-line">
    <xsl:param name="tag"/>
    <xsl:param name="value"/>
    <xsl:variable name="v" select="normalize-space($value)"/>
    <xsl:if test="$v != ''">
      <xsl:value-of select="$tag"/>
      <xsl:text>  - </xsl:text>
      <xsl:value-of select="$v"/>
      <xsl:text>&#10;</xsl:text>
    </xsl:if>
  </xsl:template>

  <!-- TY value from leader/06-07 -->
  <xsl:template name="ris-type">
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
    <xsl:choose>
      <xsl:when test="($l6='a' or $l6='t')
                      and ($l7='b' or $l7='i' or $l7='s')">JOUR</xsl:when>
      <xsl:when test="$l6='a' or $l6='t'">BOOK</xsl:when>
      <xsl:when test="$l6='e' or $l6='f'">MAP</xsl:when>
      <xsl:when test="$l6='i' or $l6='j'">SOUND</xsl:when>
      <xsl:when test="$l6='g'">VIDEO</xsl:when>
      <xsl:when test="$l6='m'">COMP</xsl:when>
      <xsl:otherwise>GEN</xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
