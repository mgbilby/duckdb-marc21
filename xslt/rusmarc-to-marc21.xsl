<?xml version="1.0" encoding="UTF-8"?>
<!--
  rusmarc-to-marc21.xsl - RUSMARC Bibliographic to MARC 21 Bibliographic:
  a DELTA layer over unimarc-to-marc21.xsl.

  Original crosswalk for the duckdb-marc21 project. RUSMARC is the Russian
  adaptation of UNIMARC published by the National RUSMARC Development
  Service (Russian National Library / RUSMARC service): the record label,
  the block structure and the great majority of field and subfield
  semantics are UNIMARC's, so this stylesheet imports the UNIMARC crosswalk
  and states only what RUSMARC adds or codes differently.

  Written from the published RUSMARC documentation - "Формат RUSMARC
  представления библиографических данных в машиночитаемой форме" (Российский
  коммуникативный формат), National RUSMARC Development Service,
  <http://www.rusmarc.info/> and <https://nlr.ru/rusmarc> - together with
  the IFLA "UNIMARC Manual: Bibliographic Format" (CC BY 4.0) inherited
  through the imported sheet, and the MARC 21 Format for Bibliographic Data
  on the target side. Nothing is copied from those documents.

  SOURCE REACHABILITY. The RUSMARC servers (rusmarc.info, rusmarc.ru,
  nlr.ru) are not reachable from the environment this sheet was written in:
  the network egress policy refuses them. The field semantics used here are
  the ones the published RUSMARC field list states and that are visible in
  the format's public documentation index - 686 with the classification
  system code in $2, 801 $a country / $b agency / $c date / $g cataloguing
  rules, 802 ISSN centre code, the 9XX block reserved for national and
  local data, and the 100 $a coded positions (0-7 date entered, 8 type of
  date, 9-16 dates, 17-19 target audience, 20 government publication,
  22-24 language of cataloguing, 26-29 and 30-33 character sets). Anything
  beyond that list is left to the imported UNIMARC behaviour rather than
  guessed at; the MARC 21 side of every mapping is the published MARC 21
  format.

  IT NEEDS ITS BASE SHEET ON DISK. The xsl:import below is resolved
  relative to this file, so unimarc-to-marc21.xsl must sit in the same
  directory. Exporting this stylesheet on its own is not enough: export
  both, or run it from the repository's xslt/intl/.

  CONTAINER, as for the imported sheet: MARC 21 slim XML in and out - the
  shape read_marc('rusmarc.mrc', encoding := 'utf8') followed by
  COPY (FORMAT marcxml) produces. Cyrillic content is carried as UTF-8;
  RUSMARC exchange tapes in older Cyrillic encodings must be converted
  before ingest.

  DELTA (what this sheet changes or adds; everything else is the UNIMARC
  crosswalk's, unchanged):
    686        -> 084      one 084 per 686; every $a becomes an 084 $a, $b
                           (base index) becomes a further $a, and the
                           classification system code in $2 is carried
                           verbatim - RUSMARC writes 'rubbk' there for the
                           Library-Bibliographical Classification (ББК),
                           which is also the MARC 21 classification scheme
                           source code for it
    802 $a     -> 022 $2   ISSN centre code, attached to the 022 built from
                           011 as the source of the ISSN
    100 $a/17-19 -> 008/22 target audience (a,b,c,d as-is; e adult general
                           -> e; k adult serious -> f specialized; m -> e;
                           anything else -> '|')
    100 $a/20  -> 008/28   government publication ('0' or blank -> blank;
                           any other coded value -> 'o', government
                           publication, level undetermined - RUSMARC's
                           numeric levels have no MARC 21 counterpart)
    9XX fields -> 9XX      RUSMARC's national and local block is copied
                           through verbatim (tag, indicators, subfields):
                           MARC 21 likewise reserves 9XX for local use, so
                           the data survives instead of being dropped, and
                           it is not reinterpreted
    801                    the imported sheet's 040 mapping is kept; the
                           RUSMARC conventions it carries are $b agency
                           codes (e.g. RuMoRGB) into 040 $a/$c/$d by the
                           ind2 role and $g cataloguing rules (e.g. psbo)
                           into 040 $e

  LOSSES AND EXCLUSIONS (in addition to the imported sheet's):
    * 686 $b is emitted as another 084 $a: MARC 21 084 $b is an item
      number, not a base classification index, so the RUSMARC "attach to
      this base index" instruction does not survive.
    * 686 fields with no $2 produce an 084 with no $2 - the crosswalk does
      not assume ББК for an unlabelled index.
    * The RUSMARC character-set positions (100 $a/26-29 and /30-33) are
      consumed, not converted: this pipeline is UTF-8 and MARC 21 records
      that in leader/09.
    * 100 $a/21 (record modification) is not mapped: no defensible
      counterpart among the MARC 21 008/38 values.
    * The target-audience code does not survive a round trip through
      marc21-to-rusmarc.xsl: that direction uses the audience table of the
      imported MARC 21 -> UNIMARC sheet, which aligns the age bands
      differently from the reading here (each code mapped to its nearest
      MARC 21 equivalent by meaning).
    * RUSMARC 9XX content is passed through untyped - no local field is
      given MARC 21 semantics here.
  XSLT 1.0 (xsltproc-friendly).
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    xmlns="http://www.loc.gov/MARC21/slim"
    exclude-result-prefixes="marc">

  <!-- xsl:import (not xsl:include): the imported templates must have the
       lower precedence, so that the overrides below win. -->
  <xsl:import href="unimarc-to-marc21.xsl"/>

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <!-- ===== 008/18-34, coded from the RUSMARC 100 $a positions ===== -->
  <xsl:template name="iu-008-18-34">
    <xsl:variable name="f100"
        select="marc:datafield[@tag='100'][1]/marc:subfield[@code='a'][1]"/>
    <!-- /18-21 illustrations: not coded -->
    <xsl:text>||||</xsl:text>
    <!-- /22 target audience from 100 $a/17 (first of the three codes) -->
    <xsl:variable name="ta" select="substring($f100, 18, 1)"/>
    <xsl:choose>
      <xsl:when test="contains('abcde', $ta) and $ta != ''">
        <xsl:value-of select="$ta"/>
      </xsl:when>
      <xsl:when test="$ta = 'k'">f</xsl:when>
      <xsl:when test="$ta = 'm'">e</xsl:when>
      <xsl:otherwise>|</xsl:otherwise>
    </xsl:choose>
    <!-- /23-27 form of item, nature of contents: not coded -->
    <xsl:text>|||||</xsl:text>
    <!-- /28 government publication from 100 $a/20 -->
    <xsl:variable name="gp" select="substring($f100, 21, 1)"/>
    <xsl:choose>
      <xsl:when test="$gp = '0' or $gp = '' or $gp = ' '">
        <xsl:text> </xsl:text>
      </xsl:when>
      <xsl:when test="$gp = '|'">|</xsl:when>
      <xsl:otherwise>o</xsl:otherwise>
    </xsl:choose>
    <!-- /29-34: not coded -->
    <xsl:text>||||||</xsl:text>
  </xsl:template>

  <!-- ===== 802 ISSN centre code -> source of the ISSN in 022 $2 ===== -->
  <!-- the context node here is the source 011 field, so '..' is the record -->
  <xsl:template name="iu-022-tail">
    <xsl:for-each select="../marc:datafield[@tag='802'][1]/marc:subfield[@code='a'][1]">
      <xsl:if test="normalize-space(.) != ''">
        <subfield code="2"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:if>
    </xsl:for-each>
  </xsl:template>

  <!-- ===== national block: 686 classification, 9XX local fields ===== -->
  <xsl:template name="iu-national">

    <!-- 686 (BBK and other national classification indexes) -> 084 -->
    <xsl:for-each select="marc:datafield[@tag='686']">
      <datafield tag="084" ind1=" " ind2=" ">
        <xsl:for-each select="marc:subfield[@code='a' or @code='b']">
          <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
        </xsl:for-each>
        <xsl:for-each select="marc:subfield[@code='2'][1]">
          <subfield code="2"><xsl:value-of select="normalize-space(.)"/></subfield>
        </xsl:for-each>
      </datafield>
    </xsl:for-each>

    <!-- 9XX national/local block: copied through, untyped -->
    <xsl:for-each select="marc:datafield[starts-with(@tag, '9')]">
      <datafield tag="{@tag}" ind1="{@ind1}" ind2="{@ind2}">
        <xsl:for-each select="marc:subfield">
          <subfield code="{@code}"><xsl:value-of select="."/></subfield>
        </xsl:for-each>
      </datafield>
    </xsl:for-each>

  </xsl:template>

</xsl:stylesheet>
