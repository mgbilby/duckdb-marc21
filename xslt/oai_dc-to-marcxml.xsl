<?xml version="1.0" encoding="UTF-8"?>
<!--
  oai_dc-to-marcxml.xsl - simple Dublin Core (OAI-PMH oai_dc container)
  to minimally valid MARCXML (slim).

  Original crosswalk for the duckdb-marc21 project, written from:
    * the DCMES 1.1 element definitions (dublincore.org, DCMI namespace
      http://purl.org/dc/elements/1.1/),
    * the Library of Congress "Dublin Core to MARC" mapping specification
      and the MARC 21 bibliographic format documentation (leader, 008,
      020/022/024, 041, 100/700, 245/246, 264, 300, 520, 540, 650, 856).

  Input: any document containing one or more oai_dc:dc containers (a
  bare oai_dc:dc, an OAI-PMH response, or the dcRecords wrapper the
  companion marcxml-to-oai_dc.xsl emits). Output is always a
  marc:collection.

  Construction notes:
    - Leader: 24 characters, type of record from dc:type against the
      DCMI Type Vocabulary (Text -> a, Sound -> i, MovingImage -> g,
      StillImage -> k, Software/Dataset -> m, PhysicalObject -> r,
      Collection -> bibliographic level c), default "nam".
    - 008: 40 characters; date type 's' plus date1 when a four-digit
      year is extractable from dc:date, language from dc:language when
      it is already a three-letter code, 'xx ' place, 'd' source.
    - dc:identifier discrimination: URI schemes (http/https/ftp/urn)
      go to 856 40 $u, ISBN-shaped values (10 or 13 digits after
      separator stripping, urn:isbn accepted) to 020 $a, ISSN-shaped
      values (NNNN-NNNC) to 022 $a, everything else to 024 8# $a.

  XSLT 1.0, xsltproc-friendly.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:oai_dc="http://www.openarchives.org/OAI/2.0/oai_dc/"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    exclude-result-prefixes="oai_dc dc">

  <xsl:include href="marc-utils.xsl"/>

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:template match="/">
    <marc:collection>
      <xsl:apply-templates select="//oai_dc:dc"/>
    </marc:collection>
  </xsl:template>

  <xsl:template match="oai_dc:dc">
    <xsl:variable name="year">
      <xsl:call-template name="mu-first-year">
        <xsl:with-param name="s" select="dc:date[1]"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="lang1" select="normalize-space(dc:language[1])"/>
    <xsl:variable name="lang008">
      <xsl:choose>
        <xsl:when test="string-length($lang1) = 3
                        and translate($lang1,
                            'abcdefghijklmnopqrstuvwxyz', '') = ''">
          <xsl:value-of select="$lang1"/>
        </xsl:when>
        <xsl:otherwise>
          <xsl:text>   </xsl:text>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:variable>

    <marc:record>
      <marc:leader>
        <xsl:text>00000n</xsl:text>
        <xsl:call-template name="dc-leader-type"/>
        <xsl:text> a2200000 a 4500</xsl:text>
      </marc:leader>

      <!-- 008: 00-05 entered, 06 date type, 07-10 date1, 11-14 date2,
           15-17 place, 18-34 material blanks, 35-37 language,
           38 modified, 39 source -->
      <marc:controlfield tag="008">
        <xsl:text>000000</xsl:text>
        <xsl:choose>
          <xsl:when test="string-length($year) = 4">
            <xsl:text>s</xsl:text>
            <xsl:value-of select="$year"/>
          </xsl:when>
          <xsl:otherwise>
            <xsl:text>n    </xsl:text>
          </xsl:otherwise>
        </xsl:choose>
        <xsl:text>    xx </xsl:text>
        <xsl:text>                 </xsl:text>
        <xsl:value-of select="$lang008"/>
        <xsl:text> d</xsl:text>
      </marc:controlfield>

      <!-- extra languages (or a non-mappable first one) go to 041 -->
      <xsl:if test="dc:language[normalize-space(.) != string($lang008)]">
        <marc:datafield tag="041" ind1=" " ind2=" ">
          <xsl:for-each select="dc:language[normalize-space(.) != string($lang008)]">
            <marc:subfield code="a">
              <xsl:value-of select="normalize-space(.)"/>
            </marc:subfield>
          </xsl:for-each>
        </marc:datafield>
      </xsl:if>

      <!-- identifiers, discriminated -->
      <xsl:apply-templates select="dc:identifier"/>

      <!-- first creator to 100, the rest and contributors to 700 -->
      <xsl:for-each select="dc:creator">
        <xsl:choose>
          <xsl:when test="position() = 1">
            <marc:datafield tag="100" ind1="1" ind2=" ">
              <marc:subfield code="a">
                <xsl:value-of select="normalize-space(.)"/>
              </marc:subfield>
            </marc:datafield>
          </xsl:when>
          <xsl:otherwise>
            <xsl:call-template name="dc-added-entry"/>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:for-each>

      <!-- first title to 245, the rest to 246 -->
      <xsl:for-each select="dc:title">
        <xsl:choose>
          <xsl:when test="position() = 1">
            <marc:datafield tag="245" ind2="0">
              <xsl:attribute name="ind1">
                <xsl:choose>
                  <xsl:when test="../dc:creator">1</xsl:when>
                  <xsl:otherwise>0</xsl:otherwise>
                </xsl:choose>
              </xsl:attribute>
              <marc:subfield code="a">
                <xsl:value-of select="normalize-space(.)"/>
              </marc:subfield>
            </marc:datafield>
          </xsl:when>
          <xsl:otherwise>
            <marc:datafield tag="246" ind1="3" ind2=" ">
              <marc:subfield code="a">
                <xsl:value-of select="normalize-space(.)"/>
              </marc:subfield>
            </marc:datafield>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:for-each>

      <!-- imprint: publisher and/or date to a 264 publication statement -->
      <xsl:if test="dc:publisher or dc:date">
        <marc:datafield tag="264" ind1=" " ind2="1">
          <xsl:if test="dc:publisher">
            <marc:subfield code="b">
              <xsl:value-of select="normalize-space(dc:publisher[1])"/>
            </marc:subfield>
          </xsl:if>
          <xsl:if test="dc:date">
            <marc:subfield code="c">
              <xsl:value-of select="normalize-space(dc:date[1])"/>
            </marc:subfield>
          </xsl:if>
        </marc:datafield>
      </xsl:if>

      <!-- physical/media description -->
      <xsl:for-each select="dc:format">
        <marc:datafield tag="300" ind1=" " ind2=" ">
          <marc:subfield code="a">
            <xsl:value-of select="normalize-space(.)"/>
          </marc:subfield>
        </marc:datafield>
      </xsl:for-each>

      <!-- descriptions become summary notes -->
      <xsl:for-each select="dc:description">
        <marc:datafield tag="520" ind1=" " ind2=" ">
          <marc:subfield code="a">
            <xsl:value-of select="normalize-space(.)"/>
          </marc:subfield>
        </marc:datafield>
      </xsl:for-each>

      <!-- rights become terms-of-use notes -->
      <xsl:for-each select="dc:rights">
        <marc:datafield tag="540" ind1=" " ind2=" ">
          <marc:subfield code="a">
            <xsl:value-of select="normalize-space(.)"/>
          </marc:subfield>
        </marc:datafield>
      </xsl:for-each>

      <!-- subjects: source unspecified, so ind2 = 4 -->
      <xsl:for-each select="dc:subject">
        <marc:datafield tag="650" ind1=" " ind2="4">
          <marc:subfield code="a">
            <xsl:value-of select="normalize-space(.)"/>
          </marc:subfield>
        </marc:datafield>
      </xsl:for-each>

      <xsl:for-each select="dc:contributor">
        <xsl:call-template name="dc-added-entry"/>
      </xsl:for-each>
    </marc:record>
  </xsl:template>

  <!-- ================================================================
       dc:identifier discrimination: URI -> 856, ISBN -> 020,
       ISSN -> 022, other -> 024 8#.
       ================================================================ -->
  <xsl:template match="dc:identifier">
    <xsl:variable name="v" select="normalize-space(.)"/>
    <xsl:variable name="lc"
        select="translate($v,
                'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
                'abcdefghijklmnopqrstuvwxyz')"/>
    <xsl:variable name="isbn">
      <xsl:call-template name="mu-isbn13">
        <xsl:with-param name="s">
          <xsl:choose>
            <xsl:when test="starts-with($lc, 'urn:isbn:')">
              <xsl:value-of select="substring($v, 10)"/>
            </xsl:when>
            <xsl:otherwise>
              <xsl:value-of select="$v"/>
            </xsl:otherwise>
          </xsl:choose>
        </xsl:with-param>
      </xsl:call-template>
    </xsl:variable>
    <xsl:choose>
      <xsl:when test="starts-with($lc, 'http://')
                      or starts-with($lc, 'https://')
                      or starts-with($lc, 'ftp://')">
        <marc:datafield tag="856" ind1="4" ind2="0">
          <marc:subfield code="u"><xsl:value-of select="$v"/></marc:subfield>
        </marc:datafield>
      </xsl:when>
      <xsl:when test="string-length($isbn) = 13">
        <marc:datafield tag="020" ind1=" " ind2=" ">
          <marc:subfield code="a"><xsl:value-of select="$isbn"/></marc:subfield>
        </marc:datafield>
      </xsl:when>
      <xsl:when test="string-length($v) = 9
                      and substring($v, 5, 1) = '-'
                      and translate(substring($v, 1, 4), '0123456789', '') = ''
                      and translate(substring($v, 6, 3), '0123456789', '') = ''
                      and contains('0123456789Xx', substring($v, 9, 1))">
        <marc:datafield tag="022" ind1=" " ind2=" ">
          <marc:subfield code="a"><xsl:value-of select="$v"/></marc:subfield>
        </marc:datafield>
      </xsl:when>
      <xsl:otherwise>
        <marc:datafield tag="024" ind1="8" ind2=" ">
          <marc:subfield code="a"><xsl:value-of select="$v"/></marc:subfield>
        </marc:datafield>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- non-primary agents: 700 added entry -->
  <xsl:template name="dc-added-entry">
    <marc:datafield tag="700" ind1="1" ind2=" ">
      <marc:subfield code="a">
        <xsl:value-of select="normalize-space(.)"/>
      </marc:subfield>
    </marc:datafield>
  </xsl:template>

  <!-- leader/06-07 (and only those two) from the DCMI Type Vocabulary -->
  <xsl:template name="dc-leader-type">
    <xsl:variable name="t" select="normalize-space(dc:type[1])"/>
    <xsl:variable name="level">
      <xsl:choose>
        <xsl:when test="dc:type[normalize-space(.) = 'Collection']">c</xsl:when>
        <xsl:otherwise>m</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:choose>
      <xsl:when test="$t = 'Sound'">i</xsl:when>
      <xsl:when test="$t = 'MovingImage'">g</xsl:when>
      <xsl:when test="$t = 'StillImage' or $t = 'Image'">k</xsl:when>
      <xsl:when test="$t = 'Software' or $t = 'Dataset'
                      or $t = 'InteractiveResource'">m</xsl:when>
      <xsl:when test="$t = 'PhysicalObject'">r</xsl:when>
      <xsl:otherwise>a</xsl:otherwise>
    </xsl:choose>
    <xsl:value-of select="$level"/>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
