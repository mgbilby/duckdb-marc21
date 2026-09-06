<?xml version="1.0" encoding="UTF-8"?>
<!--
  ibermarc-to-marc21.xsl - IBERMARC (Spain's former national exchange
  format) to MARC 21 Bibliographic: a legacy migration sheet.

  Original crosswalk for the duckdb-marc21 project, written from the
  Biblioteca Nacional de España's published IBERMARC/MARC 21 correspondence
  - "Tablas de conversión de IBERMARC a MARC 21" / "Tablas de comparación
  IBERMARC-MARC 21", BNE and the Grupo de Trabajo MARC 21 of the Consejo de
  Cooperación Bibliotecaria, <https://www.bne.es/> - and from the MARC 21
  Format for Bibliographic Data. Nothing is copied from those documents.

  SOURCE REACHABILITY: the BNE host (bne.es) is refused by this
  environment's network egress policy, so the comparison tables could not
  be read field by field. What the sheet acts on is what the published
  description of those tables states: IBERMARC belongs to the MARC family
  and its designators are MARC 21's except for a short list of changes, the
  tables mark in one colour the IBERMARC elements that no longer exist in
  MARC 21, the IBERMARC 017 control number is carried by MARC 21's 016, and
  the BNE kept the 59X block as local fields of internal use. Everything
  else is copied through unchanged rather than guessed at, which is the
  honest reading of "the two formats agree except where the tables say
  otherwise".

  WHAT THIS SHEET IS FOR, AND WHAT IT IS NOT. IBERMARC is retired: the BNE
  catalogues in MARC 21 and supplies MARC 21. If the records can be
  re-obtained from the BNE, that is the better path by a wide margin. This
  sheet is for legacy files nobody can re-supply.

  CONTAINER: MARC 21 slim XML in and out - the shape
  read_marc('ibermarc.mrc', encoding := 'utf8') followed by
  COPY (FORMAT marcxml) produces. Legacy IBERMARC tapes are not UTF-8;
  convert the character encoding before ingest.

  COVERAGE (IBERMARC -> MARC 21):
    record label -> leader   copied position by position (the two formats
                             share the MARC label), with the record and
                             directory lengths zeroed and position 9 set to
                             'a': the pipeline that produced the input is
                             UTF-8, whatever the tape was
    control fields           copied (001, 003, 005, 006, 007, 008 - the
                             MARC family's own fixed fields)
    017          -> 016      national bibliographic agency control number,
                             the one control-field change the BNE tables
                             name
    59X          -> 59X      kept, not dropped: the BNE retained the 59X
                             block as local fields of internal use
    everything else          copied verbatim, in tag order

  LOSSES AND EXCLUSIONS (deliberate):
    * IBERMARC designators that MARC 21 no longer defines are NOT silently
      re-tagged: they are copied through with their original tag, so they
      stay visible and queryable and no meaning is invented for them. A
      MARC 21 validator will flag them; that flag is the honest signal that
      a human has to decide what they meant.
    * No coded value inside 006/007/008 is re-coded: where IBERMARC's code
      lists diverged from MARC 21's, the positions come across as they were
      written.
    * Character-set conversion is not this sheet's job (XSLT sees the input
      already decoded).
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

  <xsl:template name="ib-copy">
    <xsl:param name="tag" select="@tag"/>
    <datafield tag="{$tag}" ind1="{@ind1}" ind2="{@ind2}">
      <xsl:for-each select="marc:subfield">
        <subfield code="{@code}"><xsl:value-of select="."/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:template>

  <xsl:template match="/marc:record | marc:record">
    <xsl:variable name="label" select="marc:leader"/>
    <record>

      <leader>
        <xsl:text>00000</xsl:text>
        <xsl:value-of select="substring($label, 6, 3)"/>
        <xsl:value-of select="substring($label, 9, 1)"/>
        <xsl:text>a</xsl:text>
        <xsl:text>22</xsl:text>
        <xsl:text>00000</xsl:text>
        <xsl:value-of select="substring($label, 18, 3)"/>
        <xsl:text>4500</xsl:text>
      </leader>

      <xsl:for-each select="marc:controlfield">
        <controlfield tag="{@tag}"><xsl:value-of select="."/></controlfield>
      </xsl:for-each>

      <!-- 010-015 -->
      <xsl:for-each select="marc:datafield[@tag &lt; 16]">
        <xsl:call-template name="ib-copy"/>
      </xsl:for-each>

      <!-- 016: existing, plus the IBERMARC 017 control number -->
      <xsl:for-each select="marc:datafield[@tag='016' or @tag='017']">
        <xsl:call-template name="ib-copy">
          <xsl:with-param name="tag" select="'016'"/>
        </xsl:call-template>
      </xsl:for-each>

      <!-- everything from 018 up, unchanged (59X included) -->
      <xsl:for-each select="marc:datafield[@tag &gt; 17]">
        <xsl:call-template name="ib-copy"/>
      </xsl:for-each>

    </record>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
