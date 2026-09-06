<?xml version="1.0" encoding="UTF-8"?>
<!--
  marc21-to-rusmarc.xsl - MARC 21 Bibliographic to RUSMARC Bibliographic:
  a DELTA layer over marc21-to-unimarc.xsl.

  Original crosswalk for the duckdb-marc21 project, and the reverse of
  rusmarc-to-marc21.xsl. RUSMARC is the Russian adaptation of UNIMARC
  published by the National RUSMARC Development Service (Russian National
  Library / RUSMARC service), so this stylesheet imports the MARC 21 ->
  UNIMARC crosswalk and states only the Russian additions.

  Written from the published RUSMARC documentation - "Формат RUSMARC
  представления библиографических данных в машиночитаемой форме" (Российский
  коммуникативный формат), National RUSMARC Development Service,
  <http://www.rusmarc.info/> and <https://nlr.ru/rusmarc> - with the IFLA
  "UNIMARC Manual: Bibliographic Format" (CC BY 4.0) inherited through the
  imported sheet, and the MARC 21 Format for Bibliographic Data on the
  source side. Nothing is copied from those documents.

  SOURCE REACHABILITY: the same limitation stated in rusmarc-to-marc21.xsl
  applies - the RUSMARC servers are refused by this environment's network
  egress policy, so the RUSMARC side rests on the format's published field
  list (686 with the classification system code in $2, 801 $a/$b/$c/$g,
  802 ISSN centre code, 9XX national and local block) and the MARC 21 side
  on the published MARC 21 format.

  IT NEEDS ITS BASE SHEET ON DISK. The xsl:import below is resolved
  relative to this file, so marc21-to-unimarc.xsl must sit in the same
  directory. Exporting this stylesheet on its own is not enough: export
  both, or run it from the repository's xslt/intl/.

  CONTAINER: MARC 21 slim XML in and out, as for the imported sheet.

  DELTA (everything else is the MARC 21 -> UNIMARC crosswalk's):
    084        -> 686      one 686 per 084; $a values carried across, and
                           the classification scheme source code in $2
                           carried verbatim ('rubbk' for ББК, the
                           Library-Bibliographical Classification)
    022 $2     -> 802 $a   source of the ISSN read back as the ISSN centre
                           code
    040        -> 801      as the imported sheet, plus the RUSMARC source
                           conventions: $a is the ISO country code of the
                           cataloguing agency (the 'country' parameter,
                           default RU), $c the date of record creation or
                           modification taken from 005/0-7, $g the
                           cataloguing rules from 040 $e
    9XX fields -> 9XX      MARC 21 local fields are copied through verbatim
                           into RUSMARC's national and local block, untyped

  LOSSES AND EXCLUSIONS (in addition to the imported sheet's):
    * 084 without $2 becomes a 686 without $2: no classification system is
      assumed for an unlabelled index.
    * 008/22 target audience and 008/28 government publication reach
      100 $a/17 and /20 through the imported sheet's own position table;
      this sheet does not re-code them.
    * 9XX content is passed through untyped - no MARC 21 local field is
      given RUSMARC semantics here.
  XSLT 1.0 (xsltproc-friendly).
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    xmlns="http://www.loc.gov/MARC21/slim"
    exclude-result-prefixes="marc">

  <!-- xsl:import (not xsl:include): the imported templates must have the
       lower precedence, so that the overrides below win. -->
  <xsl:import href="marc21-to-unimarc.xsl"/>

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <!-- ISO country code of the cataloguing agency, written in 801 $a -->
  <xsl:param name="country">RU</xsl:param>

  <!-- ===== 801 with the RUSMARC source conventions ===== -->
  <xsl:template name="mu2-source">
    <xsl:variable name="date" select="substring(marc:controlfield[@tag='005'][1], 1, 8)"/>
    <xsl:for-each select="marc:datafield[@tag='040'][1]">
      <xsl:for-each select="marc:subfield[@code='a']">
        <xsl:call-template name="mr-801">
          <xsl:with-param name="ind2" select="'0'"/>
          <xsl:with-param name="agency" select="normalize-space(.)"/>
          <xsl:with-param name="rules" select="normalize-space(../marc:subfield[@code='e'][1])"/>
          <xsl:with-param name="date" select="$date"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='c']">
        <xsl:call-template name="mr-801">
          <xsl:with-param name="ind2" select="'1'"/>
          <xsl:with-param name="agency" select="normalize-space(.)"/>
          <xsl:with-param name="date" select="$date"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='d']">
        <xsl:call-template name="mr-801">
          <xsl:with-param name="ind2" select="'2'"/>
          <xsl:with-param name="agency" select="normalize-space(.)"/>
          <xsl:with-param name="date" select="$date"/>
        </xsl:call-template>
      </xsl:for-each>
    </xsl:for-each>
  </xsl:template>

  <xsl:template name="mr-801">
    <xsl:param name="ind2"/>
    <xsl:param name="agency"/>
    <xsl:param name="rules" select="''"/>
    <xsl:param name="date" select="''"/>
    <datafield tag="801" ind1=" " ind2="{$ind2}">
      <xsl:if test="$country != ''">
        <subfield code="a"><xsl:value-of select="$country"/></subfield>
      </xsl:if>
      <subfield code="b"><xsl:value-of select="$agency"/></subfield>
      <xsl:if test="string-length($date) = 8">
        <subfield code="c"><xsl:value-of select="$date"/></subfield>
      </xsl:if>
      <xsl:if test="$rules != ''">
        <subfield code="g"><xsl:value-of select="$rules"/></subfield>
      </xsl:if>
    </datafield>
  </xsl:template>

  <!-- ===== national block: 686 classification, 802, 9XX local fields ===== -->
  <xsl:template name="mu2-national">

    <!-- 084 (other classification number) -> 686 -->
    <xsl:for-each select="marc:datafield[@tag='084']">
      <datafield tag="686" ind1=" " ind2=" ">
        <xsl:for-each select="marc:subfield[@code='a']">
          <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
        </xsl:for-each>
        <xsl:for-each select="marc:subfield[@code='2'][1]">
          <subfield code="2"><xsl:value-of select="normalize-space(.)"/></subfield>
        </xsl:for-each>
      </datafield>
    </xsl:for-each>

    <!-- 022 $2 (source of the ISSN) -> 802 ISSN centre code -->
    <xsl:for-each select="marc:datafield[@tag='022'][1]/marc:subfield[@code='2'][1]">
      <xsl:if test="normalize-space(.) != ''">
        <datafield tag="802" ind1=" " ind2=" ">
          <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
        </datafield>
      </xsl:if>
    </xsl:for-each>

    <!-- MARC 21 local block -> RUSMARC national and local block, untyped -->
    <xsl:for-each select="marc:datafield[starts-with(@tag, '9')]">
      <datafield tag="{@tag}" ind1="{@ind1}" ind2="{@ind2}">
        <xsl:for-each select="marc:subfield">
          <subfield code="{@code}"><xsl:value-of select="."/></subfield>
        </xsl:for-each>
      </datafield>
    </xsl:for-each>

  </xsl:template>

</xsl:stylesheet>
