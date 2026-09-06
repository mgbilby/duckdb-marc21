<?xml version="1.0" encoding="UTF-8"?>
<!--
  japanmarc-normalize.xsl - JAPAN/MARC (National Diet Library) reading and
  parallel-script conventions, expressed as standard MARC 21 880 / $6
  linkage.

  Original stylesheet for the duckdb-marc21 project, written from the NDL's
  published documentation - "JAPAN/MARC MARC21フォーマット マニュアル"
  (JAPAN/MARC MARC21 Format Manual, monographs and serials edition, and the
  authorities edition), National Diet Library,
  <https://www.ndl.go.jp/jp/data/catstandards/jm/index.html>, together with
  the NDL's 文字・読みの基準 (character and reading standards),
  <https://www.ndl.go.jp/data/catstandards/characters> - and from the MARC
  21 Format for Bibliographic Data, Appendix A (Control Subfields), on the
  target side. Nothing is copied from those documents.

  SOURCE REACHABILITY: the NDL host (ndl.go.jp) is refused by this
  environment's network egress policy, so the manual PDFs could not be
  read. What is implemented rests on the conventions the NDL's published
  format documentation states: JAPAN/MARC MARC21 records carry the reading
  (ヨミ) of a heading or title in a paired 880 field; the $6 of that 880 is
  [tag of the paired field]-[occurrence number]/[script identification
  code], the code being '$1' for a katakana (or hangul) reading form and
  '(B' for a romaji reading form, following MARC 21 Appendix A; and the
  880's indicators repeat the paired field's. The MARC 21 side is the
  published MARC 21 format.

  WHY A NORMALIZER AND NOT A CROSSWALK. The JAPAN/MARC MARC21 format IS
  MARC 21: the NDL made the switch, and current NDL data reads directly.
  What differs is a set of *practices* around readings and parallel script,
  and what breaks in a general MARC 21 consumer is the linkage those
  practices depend on. So this sheet changes linkage, never content.

  WHAT IT DOES (record by record, in this order):
    1. Pairs each 880 with its regular field: by the tag in the 880's $6,
       and among fields of that tag by position - the k-th 880 naming tag T
       pairs with the k-th field with tag T. When there are more 880s
       naming T than there are T fields, the extra ones are further script
       representations of the last of them: a katakana reading and a romaji
       reading of one title link to that one title.
    2. Numbers the pairs: an occurrence number belongs to the *linked
       field*, so every 880 that represents the same field carries the same
       number and they differ only in their script code. The number is the
       field's position among the fields some 880 in the record names, which
       makes it unique and stable and lets both ends compute it
       independently - so a record whose numbers were absent, duplicated or
       out of step comes out consistent.
    3. Writes the reciprocal linkage: every paired regular field gets
       $6 880-NN as its FIRST subfield, which is what a MARC 21 consumer
       looks for to find the alternate-script form; every 880 gets
       $6 TTT-NN/script as its first subfield.
    4. Keeps or derives the script identification code: an incoming code is
       kept as it stands; when there is none, the sheet writes '(B' if the
       880's data is written in Latin script (a romaji reading) and '$1'
       otherwise (a katakana or kanji form) - the two codes the NDL
       conventions use.
    5. Repeats the paired field's indicators on the 880.
    6. Emits the 880 fields together at the end of the record, after the
       regular fields, as MARC 21 records conventionally do.

  WHAT IT DELIBERATELY LEAVES ALONE:
    * Content. No reading is generated, romanized, transliterated,
      normalized for word division, or corrected - the NDL's reading
      standards decide what a reading says, and this sheet has no opinion.
    * The leader, all control fields (008 included), and every field
      without a reading pair: copied through byte for byte.
    * Which fields carry readings. If the NDL paired a reading with 245 and
      not with 250, so does the output.
    * 880 fields whose $6 occurrence number is 00 - MARC 21's "no
      corresponding field" - which stay unpaired, keep their 00, and keep
      their own indicators and script code.
    * Subfield order inside a field, apart from moving $6 to the front.
    * Records with no 880 at all: they come out identical to the input.
    * Any other NDL practice (the 007/008 coded values, the NDL's own
      classification and subject fields, the authority-record format).

  CONTAINER: MARC 21 slim XML in and out - the shape
  read_marc('japanmarc.mrc', encoding := 'utf8') followed by
  COPY (FORMAT marcxml) produces. Accepts a bare record or a collection.
  XSLT 1.0 (xsltproc-friendly).
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    xmlns="http://www.loc.gov/MARC21/slim"
    exclude-result-prefixes="marc">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <!-- characters that make a string "Latin script" for the purpose of
       choosing a script identification code -->
  <xsl:variable name="latin"
    >ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,:;/()[]-'"?!&amp;+=*@#$%</xsl:variable>

  <xsl:template match="/marc:collection">
    <collection>
      <xsl:apply-templates select="marc:record"/>
    </collection>
  </xsl:template>

  <!-- the tag named by an 880's $6 -->
  <xsl:template name="jm-linked-tag">
    <xsl:value-of select="substring(normalize-space(marc:subfield[@code='6'][1]), 1, 3)"/>
  </xsl:template>

  <!-- script identification code of an 880: kept if present, else derived
       from the script the field's data is written in -->
  <xsl:template name="jm-script">
    <xsl:variable name="six" select="normalize-space(marc:subfield[@code='6'][1])"/>
    <xsl:choose>
      <xsl:when test="contains($six, '/')">
        <xsl:value-of select="substring-after($six, '/')"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:variable name="data">
          <xsl:for-each select="marc:subfield[not(@code='6')]">
            <xsl:value-of select="."/>
          </xsl:for-each>
        </xsl:variable>
        <xsl:choose>
          <xsl:when test="translate($data, $latin, '') = ''">
            <xsl:text>(B</xsl:text>
          </xsl:when>
          <xsl:otherwise>
            <xsl:text>$1</xsl:text>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- everything except $6, which this sheet writes itself -->
  <xsl:template name="jm-subfields">
    <xsl:for-each select="marc:subfield[not(@code='6')]">
      <subfield code="{@code}"><xsl:value-of select="."/></subfield>
    </xsl:for-each>
  </xsl:template>

  <!-- occurrence number of a regular field: its position among the fields
       whose tag some 880 in the record names, so the numbers are unique and
       stable and both ends of a pair compute the same one -->
  <xsl:template name="jm-occurrence">
    <xsl:param name="linked"/>
    <xsl:number format="01"
        value="count(preceding-sibling::marc:datafield[not(@tag='880')]
               [contains($linked, concat('|', @tag, '|'))]) + 1"/>
  </xsl:template>

  <xsl:template match="/marc:record | marc:record">
    <!-- '|tag|' for every tag an 880 in this record names -->
    <xsl:variable name="linked">
      <xsl:for-each select="marc:datafield[@tag='880']">
        <xsl:text>|</xsl:text>
        <xsl:call-template name="jm-linked-tag"/>
        <xsl:text>|</xsl:text>
      </xsl:for-each>
    </xsl:variable>

    <record>
      <xsl:copy-of select="marc:leader"/>
      <xsl:for-each select="marc:controlfield">
        <controlfield tag="{@tag}"><xsl:value-of select="."/></controlfield>
      </xsl:for-each>

      <!-- regular fields, in document order, with the reciprocal linkage -->
      <xsl:for-each select="marc:datafield[not(@tag='880')]">
        <xsl:variable name="tag" select="@tag"/>
        <xsl:variable name="k"
            select="count(preceding-sibling::marc:datafield[@tag = $tag]) + 1"/>
        <xsl:variable name="pairs"
            select="../marc:datafield[@tag='880']
                    [substring(normalize-space(marc:subfield[@code='6'][1]), 1, 3) = $tag]
                    [substring(normalize-space(marc:subfield[@code='6'][1]), 5, 2) != '00']"/>
        <datafield tag="{@tag}" ind1="{@ind1}" ind2="{@ind2}">
          <xsl:if test="count($pairs) &gt;= $k">
            <subfield code="6">
              <xsl:text>880-</xsl:text>
              <xsl:call-template name="jm-occurrence">
                <xsl:with-param name="linked" select="$linked"/>
              </xsl:call-template>
            </subfield>
          </xsl:if>
          <xsl:call-template name="jm-subfields"/>
        </datafield>
      </xsl:for-each>

      <!-- the alternate-script fields, at the end of the record -->
      <xsl:for-each select="marc:datafield[@tag='880']">
        <xsl:variable name="tag">
          <xsl:call-template name="jm-linked-tag"/>
        </xsl:variable>
        <xsl:variable name="script">
          <xsl:call-template name="jm-script"/>
        </xsl:variable>
        <xsl:variable name="unpaired"
            select="substring(normalize-space(marc:subfield[@code='6'][1]), 5, 2) = '00'"/>
        <!-- the j-th 880 naming tag T belongs to the j-th field with that
             tag; 880s beyond the last such field are further script
             representations of it (a kana reading and a romaji reading of
             the same field), and share its occurrence number -->
        <xsl:variable name="j"
            select="count(preceding-sibling::marc:datafield[@tag='880']
                    [substring(normalize-space(marc:subfield[@code='6'][1]), 1, 3) = $tag]
                    [substring(normalize-space(marc:subfield[@code='6'][1]), 5, 2) != '00']) + 1"/>
        <xsl:variable name="fields" select="../marc:datafield[@tag = $tag]"/>
        <xsl:variable name="idx">
          <xsl:choose>
            <xsl:when test="$j &gt; count($fields)"><xsl:value-of select="count($fields)"/></xsl:when>
            <xsl:otherwise><xsl:value-of select="$j"/></xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <xsl:variable name="owner" select="$fields[position() = number($idx)]"/>
        <datafield tag="880">
          <xsl:attribute name="ind1">
            <xsl:choose>
              <xsl:when test="$owner and not($unpaired)"><xsl:value-of select="$owner/@ind1"/></xsl:when>
              <xsl:otherwise><xsl:value-of select="@ind1"/></xsl:otherwise>
            </xsl:choose>
          </xsl:attribute>
          <xsl:attribute name="ind2">
            <xsl:choose>
              <xsl:when test="$owner and not($unpaired)"><xsl:value-of select="$owner/@ind2"/></xsl:when>
              <xsl:otherwise><xsl:value-of select="@ind2"/></xsl:otherwise>
            </xsl:choose>
          </xsl:attribute>
          <subfield code="6">
            <xsl:value-of select="$tag"/>
            <xsl:text>-</xsl:text>
            <xsl:choose>
              <xsl:when test="$unpaired or not($owner)"><xsl:text>00</xsl:text></xsl:when>
              <xsl:otherwise>
                <xsl:for-each select="$owner">
                  <xsl:call-template name="jm-occurrence">
                    <xsl:with-param name="linked" select="$linked"/>
                  </xsl:call-template>
                </xsl:for-each>
              </xsl:otherwise>
            </xsl:choose>
            <xsl:if test="$script != ''">
              <xsl:text>/</xsl:text>
              <xsl:value-of select="$script"/>
            </xsl:if>
          </subfield>
          <xsl:call-template name="jm-subfields"/>
        </datafield>
      </xsl:for-each>

    </record>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
