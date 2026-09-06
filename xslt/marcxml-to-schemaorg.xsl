<?xml version="1.0" encoding="UTF-8"?>
<!--
  marcxml-to-schemaorg.xsl - MARCXML (slim) to schema.org JSON-LD,
  one JSON object per record, newline separated (NDJSON).

  Original crosswalk for the duckdb-marc21 project, written from:
    * the schema.org vocabulary documentation (CreativeWork and its
      subtypes; name/author/contributor/publisher/datePublished/
      inLanguage/about/description/isbn/issn/url/sameAs),
    * RFC 8259 for the string-escaping rules,
    * the MARC 21 bibliographic format documentation for the sources.

  This stylesheet deliberately mirrors the extension's own marc_jsonld
  SQL macro (src/macros/formats.sql): the same key set, the same
  leader/06-07 to @type table, the same field sources, and the same
  "absent data drops its key" behavior, so the SQL and XSLT export
  paths agree. Differences from the macro are minimal and documented:
  the ISSN here is normalized by shape (NNNN-NNNC) without checksum
  validation, and identifier URIs ($0/$1) are recognized by an
  http(s):// prefix test.

  Output method is text; escaping of quotes, backslashes and control
  characters is handled by mu-json-escape in lib/marc-utils.xsl.
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
    <xsl:text>{"@context":"https://schema.org","@type":"</xsl:text>
    <xsl:call-template name="so-type"/>
    <xsl:text>"</xsl:text>

    <!-- name : 245 $a $b, punctuation trimmed -->
    <xsl:variable name="name">
      <xsl:for-each select="marc:datafield[@tag='245'][1]">
        <xsl:call-template name="mu-chomp">
          <xsl:with-param name="s">
            <xsl:call-template name="mu-field-text">
              <xsl:with-param name="want" select="'ab'"/>
            </xsl:call-template>
          </xsl:with-param>
        </xsl:call-template>
      </xsl:for-each>
    </xsl:variable>
    <xsl:call-template name="so-pair">
      <xsl:with-param name="key" select="'name'"/>
      <xsl:with-param name="value" select="$name"/>
    </xsl:call-template>

    <!-- author : first 100/110/111 $a as a Person node -->
    <xsl:variable name="author">
      <xsl:for-each select="(marc:datafield[@tag='100' or @tag='110'
                             or @tag='111']/marc:subfield[@code='a'])[1]">
        <xsl:call-template name="mu-chomp">
          <xsl:with-param name="s" select="."/>
        </xsl:call-template>
      </xsl:for-each>
    </xsl:variable>
    <xsl:if test="string($author) != ''">
      <xsl:text>,"author":{"@type":"Person","name":"</xsl:text>
      <xsl:call-template name="mu-json-escape">
        <xsl:with-param name="s" select="string($author)"/>
      </xsl:call-template>
      <xsl:text>"}</xsl:text>
    </xsl:if>

    <!-- contributor : 700/710/711 $a as Person nodes -->
    <xsl:if test="marc:datafield[@tag='700' or @tag='710' or @tag='711']
                  /marc:subfield[@code='a']">
      <xsl:text>,"contributor":[</xsl:text>
      <xsl:for-each select="marc:datafield[@tag='700' or @tag='710' or @tag='711']
                            /marc:subfield[@code='a']">
        <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
        <xsl:text>{"@type":"Person","name":"</xsl:text>
        <xsl:variable name="c">
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </xsl:variable>
        <xsl:call-template name="mu-json-escape">
          <xsl:with-param name="s" select="string($c)"/>
        </xsl:call-template>
        <xsl:text>"}</xsl:text>
      </xsl:for-each>
      <xsl:text>]</xsl:text>
    </xsl:if>

    <!-- publisher : 260$b else 264$b, as an Organization node -->
    <xsl:variable name="pub">
      <xsl:for-each select="(marc:datafield[@tag='260']/marc:subfield[@code='b']
                             | marc:datafield[@tag='264']/marc:subfield[@code='b'])[1]">
        <xsl:call-template name="mu-chomp">
          <xsl:with-param name="s" select="."/>
        </xsl:call-template>
      </xsl:for-each>
    </xsl:variable>
    <xsl:if test="string($pub) != ''">
      <xsl:text>,"publisher":{"@type":"Organization","name":"</xsl:text>
      <xsl:call-template name="mu-json-escape">
        <xsl:with-param name="s" select="string($pub)"/>
      </xsl:call-template>
      <xsl:text>"}</xsl:text>
    </xsl:if>

    <!-- datePublished : 260$c / 264$c, else 008/07-10 -->
    <xsl:variable name="date">
      <xsl:choose>
        <xsl:when test="marc:datafield[@tag='260' or @tag='264']
                        /marc:subfield[@code='c']">
          <xsl:for-each select="(marc:datafield[@tag='260' or @tag='264']
                                 /marc:subfield[@code='c'])[1]">
            <xsl:call-template name="mu-chomp">
              <xsl:with-param name="s" select="."/>
            </xsl:call-template>
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
            <xsl:value-of select="normalize-space($d8)"/>
          </xsl:if>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:call-template name="so-pair">
      <xsl:with-param name="key" select="'datePublished'"/>
      <xsl:with-param name="value" select="$date"/>
    </xsl:call-template>

    <!-- inLanguage : 008/35-37 else 041$a -->
    <xsl:variable name="lg8">
      <xsl:call-template name="mu-cf-slice">
        <xsl:with-param name="pos" select="35"/>
        <xsl:with-param name="len" select="3"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="lang">
      <xsl:choose>
        <xsl:when test="translate($lg8, ' |', '') != ''">
          <xsl:value-of select="$lg8"/>
        </xsl:when>
        <xsl:otherwise>
          <xsl:value-of select="normalize-space(
              marc:datafield[@tag='041']/marc:subfield[@code='a'][1])"/>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:call-template name="so-pair">
      <xsl:with-param name="key" select="'inLanguage'"/>
      <xsl:with-param name="value" select="$lang"/>
    </xsl:call-template>

    <!-- about : first $a of each 6XX -->
    <xsl:if test="marc:datafield[starts-with(@tag, '6')]
                  /marc:subfield[@code='a']">
      <xsl:text>,"about":[</xsl:text>
      <xsl:for-each select="marc:datafield[starts-with(@tag, '6')]
                            [marc:subfield[@code='a']]">
        <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
        <xsl:text>"</xsl:text>
        <xsl:variable name="subj">
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
          </xsl:call-template>
        </xsl:variable>
        <xsl:call-template name="mu-json-escape">
          <xsl:with-param name="s" select="string($subj)"/>
        </xsl:call-template>
        <xsl:text>"</xsl:text>
      </xsl:for-each>
      <xsl:text>]</xsl:text>
    </xsl:if>

    <!-- description : 520$a else 500$a -->
    <xsl:variable name="desc">
      <xsl:choose>
        <xsl:when test="marc:datafield[@tag='520']/marc:subfield[@code='a']">
          <xsl:value-of select="(marc:datafield[@tag='520']
                                 /marc:subfield[@code='a'])[1]"/>
        </xsl:when>
        <xsl:otherwise>
          <xsl:value-of select="(marc:datafield[@tag='500']
                                 /marc:subfield[@code='a'])[1]"/>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:call-template name="so-pair">
      <xsl:with-param name="key" select="'description'"/>
      <xsl:with-param name="value" select="$desc"/>
    </xsl:call-template>

    <!-- isbn : first 020$a, normalized to 13 digits -->
    <xsl:variable name="isbn">
      <xsl:call-template name="mu-isbn13">
        <xsl:with-param name="s"
            select="(marc:datafield[@tag='020']/marc:subfield[@code='a'])[1]"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:call-template name="so-pair">
      <xsl:with-param name="key" select="'isbn'"/>
      <xsl:with-param name="value" select="$isbn"/>
    </xsl:call-template>

    <!-- issn : first 022$a with the NNNN-NNNC shape -->
    <xsl:variable name="issnraw"
        select="normalize-space((marc:datafield[@tag='022']
                                 /marc:subfield[@code='a'])[1])"/>
    <xsl:variable name="issnbare"
        select="translate($issnraw, 'x- ', 'X')"/>
    <xsl:variable name="issn">
      <xsl:if test="string-length($issnbare) = 8
                    and translate(substring($issnbare, 1, 7), '0123456789', '') = ''
                    and contains('0123456789X', substring($issnbare, 8, 1))">
        <xsl:value-of select="concat(substring($issnbare, 1, 4), '-',
                                     substring($issnbare, 5, 4))"/>
      </xsl:if>
    </xsl:variable>
    <xsl:call-template name="so-pair">
      <xsl:with-param name="key" select="'issn'"/>
      <xsl:with-param name="value" select="$issn"/>
    </xsl:call-template>

    <!-- url : every 856$u -->
    <xsl:if test="marc:datafield[@tag='856']/marc:subfield[@code='u']">
      <xsl:text>,"url":[</xsl:text>
      <xsl:for-each select="marc:datafield[@tag='856']/marc:subfield[@code='u']">
        <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
        <xsl:text>"</xsl:text>
        <xsl:call-template name="mu-json-escape">
          <xsl:with-param name="s" select="normalize-space(.)"/>
        </xsl:call-template>
        <xsl:text>"</xsl:text>
      </xsl:for-each>
      <xsl:text>]</xsl:text>
    </xsl:if>

    <!-- sameAs : authority URIs in $0/$1 -->
    <xsl:if test="marc:datafield/marc:subfield[(@code='0' or @code='1')
                  and (starts-with(normalize-space(.), 'http://')
                       or starts-with(normalize-space(.), 'https://'))]">
      <xsl:text>,"sameAs":[</xsl:text>
      <xsl:for-each select="marc:datafield/marc:subfield[(@code='0' or @code='1')
                            and (starts-with(normalize-space(.), 'http://')
                                 or starts-with(normalize-space(.), 'https://'))]">
        <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
        <xsl:text>"</xsl:text>
        <xsl:call-template name="mu-json-escape">
          <xsl:with-param name="s" select="normalize-space(.)"/>
        </xsl:call-template>
        <xsl:text>"</xsl:text>
      </xsl:for-each>
      <xsl:text>]</xsl:text>
    </xsl:if>

    <xsl:text>}&#10;</xsl:text>
  </xsl:template>

  <!-- one optional string member: ,"key":"escaped value" -->
  <xsl:template name="so-pair">
    <xsl:param name="key"/>
    <xsl:param name="value"/>
    <xsl:if test="string($value) != ''">
      <xsl:text>,"</xsl:text>
      <xsl:value-of select="$key"/>
      <xsl:text>":"</xsl:text>
      <xsl:call-template name="mu-json-escape">
        <xsl:with-param name="s" select="string($value)"/>
      </xsl:call-template>
      <xsl:text>"</xsl:text>
    </xsl:if>
  </xsl:template>

  <!-- schema.org @type from leader/06 (+07 for continuing resources),
       same table as the marc_jsonld_type SQL macro -->
  <xsl:template name="so-type">
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
                      and ($l7='b' or $l7='i' or $l7='s')">Periodical</xsl:when>
      <xsl:when test="$l6='a' or $l6='t'">Book</xsl:when>
      <xsl:when test="$l6='e' or $l6='f'">Map</xsl:when>
      <xsl:when test="$l6='c' or $l6='d'">MusicComposition</xsl:when>
      <xsl:when test="$l6='j'">MusicRecording</xsl:when>
      <xsl:when test="$l6='i'">AudioObject</xsl:when>
      <xsl:when test="$l6='g'">Movie</xsl:when>
      <xsl:when test="$l6='k'">ImageObject</xsl:when>
      <xsl:when test="$l6='m'">SoftwareApplication</xsl:when>
      <xsl:when test="$l6='p'">Collection</xsl:when>
      <xsl:otherwise>CreativeWork</xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
