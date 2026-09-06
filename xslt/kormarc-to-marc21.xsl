<?xml version="1.0" encoding="UTF-8"?>
<!--
  kormarc-to-marc21.xsl - KORMARC Bibliographic to MARC 21 Bibliographic.

  Original crosswalk for the duckdb-marc21 project, written from the
  published KORMARC documentation - 한국문헌자동화목록형식 (KORMARC), the
  integrated bibliographic format, KS X 6006, National Library of Korea,
  <https://www.nl.go.kr/> and the NLK's KORMARC field documentation - and
  from the MARC 21 Format for Bibliographic Data on the target side.
  Nothing is copied from those documents.

  SOURCE REACHABILITY. The NLK's KORMARC field pages (librarian.nl.go.kr)
  are refused by this environment's network egress policy, so the KORMARC
  side of each mapping below rests on the format's published field list -
  056 한국십진분류기호 (KDC classification), 052 국립중앙도서관 청구기호
  (National Library call number), 049 소장사항 (holdings), 090 자관 청구기호
  (local call number), 940 로컬표목-표제 (local title heading), 950
  로컬정보-가격 (local price information), and the 9XX block reserved for
  local fields - rather than on a fetched copy of the standard. The MARC 21
  side is the published MARC 21 format.

  WHY THIS IS A SMALL SHEET. KORMARC is deliberately MARC 21-structured:
  the leader, the tags, the indicators and the subfield codes of the shared
  fields are MARC 21's, so a KORMARC record is already a MARC 21 record
  except for the Korean local fields and one tag collision. Everything not
  named below is copied through unchanged, in tag order.

  CONTAINER: MARC 21 slim XML in and out - the shape
  read_marc('kormarc.mrc', encoding := 'utf8') followed by
  COPY (FORMAT marcxml) produces. Accepts a bare record or a collection.

  COVERAGE (KORMARC -> MARC 21):
    056 KDC      -> 084      $a -> $a (classification number), $b -> $b
                             (book number), and $2 set to 'kdc', the MARC 21
                             classification scheme source code for the
                             Korean Decimal Classification
    049 holdings -> 852      one 852 (ind1 8, other scheme) per 049:
                             $l registration number -> $p piece designation,
                             $f separate-location mark -> $c shelving
                             location, $v volume -> $3 materials specified,
                             $c copy -> $t copy number; the call number from
                             090 (or 052) is carried in $h/$i of the same
                             852
    090 local    -> 852      $a -> $h classification part, $b -> $i item
      call number            part; emitted as its own 852 when there is no
                             049 to attach it to
    052 NLK call -> 852      same treatment as 090, and a REQUIRED rewrite:
      number                 MARC 21 052 is Geographic Classification, so a
                             KORMARC 052 left in place would be read as
                             something else entirely
    940 local    -> 246      ind1 3 ind2 blank, $a -> $a: a variant title
      title heading          recorded as a local heading
    950 price    -> 037      $c terms of availability (the price as
                             transcribed); ind1 blank
    008/15-17,   -> 008      passed through; when the incoming positions are
    008/35-37                blank or '|||' they are filled from the
                             'country' and 'language' parameters, which
                             default to the codes Korean cataloguing uses
                             ('ko ' and 'kor'). Set either parameter to the
                             empty string to disable that fill.
    245                      copied; the only rewrite is the nonfiling
                             indicator: when the title proper does not start
                             with a Latin letter (a Hangul or Hanja title
                             cannot carry a leading article) ind2 is forced
                             to 0
    other 9XX    -> 9XX      copied through verbatim, untyped: MARC 21
                             reserves 9XX for local use as well
    everything else          copied verbatim, in tag order

  LOSSES AND EXCLUSIONS (deliberate):
    * The KDC edition number recorded in 056 does not survive: MARC 21 084
      has no edition subfield ($2 carries the scheme, not the edition).
    * KORMARC 049's first indicator (whether every piece in the record sits
      in one location) has no 852 counterpart and is dropped.
    * Parallel-script and romanized fields (880 and its $6 linkage) are
      copied untouched; repairing or minting $6 linkage is the separate job
      of japanmarc-normalize.xsl, which is script-agnostic.
    * KORMARC-specific coded values inside otherwise shared fields (for
      example Korean-only codes in 007/008 positions) are not translated -
      the positions are MARC 21's, the code lists may not be.
    * Local fields other than 940 and 950 are passed through untyped: no
      library-specific 09X/9XX convention is assumed.
  XSLT 1.0 (xsltproc-friendly).
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    xmlns="http://www.loc.gov/MARC21/slim"
    exclude-result-prefixes="marc">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <!-- 008/15-17 and 008/35-37 fill for records that leave them uncoded -->
  <xsl:param name="country">ko </xsl:param>
  <xsl:param name="language">kor</xsl:param>

  <xsl:variable name="latin"
    >ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz</xsl:variable>

  <xsl:template match="/marc:collection">
    <collection>
      <xsl:apply-templates select="marc:record"/>
    </collection>
  </xsl:template>

  <!-- copy one field through unchanged -->
  <xsl:template name="ko-copy">
    <datafield tag="{@tag}" ind1="{@ind1}" ind2="{@ind2}">
      <xsl:for-each select="marc:subfield">
        <subfield code="{@code}"><xsl:value-of select="."/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:template>

  <!-- the call-number subfields shared by 090 and 052 -->
  <xsl:template name="ko-call-number">
    <xsl:param name="field"/>
    <xsl:for-each select="$field/marc:subfield[@code='a']">
      <subfield code="h"><xsl:value-of select="normalize-space(.)"/></subfield>
    </xsl:for-each>
    <xsl:for-each select="$field/marc:subfield[@code='b']">
      <subfield code="i"><xsl:value-of select="normalize-space(.)"/></subfield>
    </xsl:for-each>
  </xsl:template>

  <xsl:template match="/marc:record | marc:record">
    <!-- the local call number: 090 when the library recorded one, else the
         National Library call number from 052 -->
    <xsl:variable name="f090" select="marc:datafield[@tag='090'][1]"/>
    <xsl:variable name="call"
        select="$f090 | marc:datafield[@tag='052'][1][not($f090)]"/>
    <record>

      <xsl:copy-of select="marc:leader"/>

      <!-- control fields; 008 gets the country/language fill -->
      <xsl:for-each select="marc:controlfield">
        <xsl:choose>
          <xsl:when test="@tag = '008' and string-length(.) &gt;= 38">
            <controlfield tag="008">
              <xsl:value-of select="substring(., 1, 15)"/>
              <xsl:variable name="cc" select="substring(., 16, 3)"/>
              <xsl:choose>
                <xsl:when test="(normalize-space($cc) = '' or $cc = '|||')
                                and $country != ''">
                  <xsl:value-of select="substring(concat($country, '   '), 1, 3)"/>
                </xsl:when>
                <xsl:otherwise><xsl:value-of select="$cc"/></xsl:otherwise>
              </xsl:choose>
              <xsl:value-of select="substring(., 19, 17)"/>
              <xsl:variable name="lg" select="substring(., 36, 3)"/>
              <xsl:choose>
                <xsl:when test="(normalize-space($lg) = '' or $lg = '|||')
                                and $language != ''">
                  <xsl:value-of select="substring(concat($language, '   '), 1, 3)"/>
                </xsl:when>
                <xsl:otherwise><xsl:value-of select="$lg"/></xsl:otherwise>
              </xsl:choose>
              <xsl:value-of select="substring(., 39)"/>
            </controlfield>
          </xsl:when>
          <xsl:otherwise>
            <controlfield tag="{@tag}"><xsl:value-of select="."/></controlfield>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:for-each>

      <!-- 010-035 -->
      <xsl:for-each select="marc:datafield[@tag &lt; 37]">
        <xsl:call-template name="ko-copy"/>
      </xsl:for-each>

      <!-- 037: existing, plus the price from 950 -->
      <xsl:for-each select="marc:datafield[@tag = '037']">
        <xsl:call-template name="ko-copy"/>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='950'][marc:subfield]">
        <datafield tag="037" ind1=" " ind2=" ">
          <subfield code="c">
            <xsl:value-of select="normalize-space(marc:subfield[@code='b' or @code='a'][1])"/>
          </subfield>
        </datafield>
      </xsl:for-each>

      <!-- 038-083, minus the KORMARC local fields handled below -->
      <xsl:for-each select="marc:datafield[@tag &gt; 37 and @tag &lt; 84
                            and not(@tag='049' or @tag='052' or @tag='056')]">
        <xsl:call-template name="ko-copy"/>
      </xsl:for-each>

      <!-- 084: existing, plus the KDC classification from 056 -->
      <xsl:for-each select="marc:datafield[@tag = '084']">
        <xsl:call-template name="ko-copy"/>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='056']">
        <datafield tag="084" ind1=" " ind2=" ">
          <xsl:for-each select="marc:subfield[@code='a']">
            <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='b']">
            <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <subfield code="2">kdc</subfield>
        </datafield>
      </xsl:for-each>

      <!-- 085-245, minus 090 (a call number, handled with 852) -->
      <xsl:for-each select="marc:datafield[@tag &gt; 84 and @tag &lt; 246
                            and not(@tag='090')]">
        <xsl:choose>
          <xsl:when test="@tag = '245'">
            <xsl:variable name="first"
                select="substring(normalize-space(marc:subfield[@code='a'][1]), 1, 1)"/>
            <datafield tag="245" ind1="{@ind1}">
              <xsl:attribute name="ind2">
                <xsl:choose>
                  <xsl:when test="$first != '' and not(contains($latin, $first))">0</xsl:when>
                  <xsl:otherwise><xsl:value-of select="@ind2"/></xsl:otherwise>
                </xsl:choose>
              </xsl:attribute>
              <xsl:for-each select="marc:subfield">
                <subfield code="{@code}"><xsl:value-of select="."/></subfield>
              </xsl:for-each>
            </datafield>
          </xsl:when>
          <xsl:otherwise>
            <xsl:call-template name="ko-copy"/>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:for-each>

      <!-- 246: existing, plus the local title heading from 940 -->
      <xsl:for-each select="marc:datafield[@tag = '246']">
        <xsl:call-template name="ko-copy"/>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='940'][marc:subfield[@code='a']]">
        <datafield tag="246" ind1="3" ind2=" ">
          <xsl:for-each select="marc:subfield[@code='a']">
            <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='b']">
            <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
        </datafield>
      </xsl:for-each>

      <!-- 247-851 -->
      <xsl:for-each select="marc:datafield[@tag &gt; 246 and @tag &lt; 852]">
        <xsl:call-template name="ko-copy"/>
      </xsl:for-each>

      <!-- 852: existing, plus holdings built from 049 and the call number -->
      <xsl:for-each select="marc:datafield[@tag = '852']">
        <xsl:call-template name="ko-copy"/>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='049']">
        <datafield tag="852" ind1="8" ind2=" ">
          <xsl:for-each select="marc:subfield[@code='f']">
            <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:call-template name="ko-call-number">
            <xsl:with-param name="field" select="$call"/>
          </xsl:call-template>
          <xsl:for-each select="marc:subfield[@code='v']">
            <subfield code="3"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='c']">
            <subfield code="t"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='l']">
            <subfield code="p"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
        </datafield>
      </xsl:for-each>
      <!-- a call number with no 049 to hang it on still becomes an 852 -->
      <xsl:if test="$call and not(marc:datafield[@tag='049'])">
        <datafield tag="852" ind1="8" ind2=" ">
          <xsl:call-template name="ko-call-number">
            <xsl:with-param name="field" select="$call"/>
          </xsl:call-template>
        </datafield>
      </xsl:if>

      <!-- 853-899 -->
      <xsl:for-each select="marc:datafield[@tag &gt; 852 and @tag &lt; 900]">
        <xsl:call-template name="ko-copy"/>
      </xsl:for-each>

      <!-- remaining local block -->
      <xsl:for-each select="marc:datafield[@tag &gt;= 900
                            and not(@tag='940' or @tag='950')]">
        <xsl:call-template name="ko-copy"/>
      </xsl:for-each>

    </record>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
