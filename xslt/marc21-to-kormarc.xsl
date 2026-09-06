<?xml version="1.0" encoding="UTF-8"?>
<!--
  marc21-to-kormarc.xsl - MARC 21 Bibliographic to KORMARC Bibliographic,
  and the reverse of kormarc-to-marc21.xsl.

  Original crosswalk for the duckdb-marc21 project, written from the
  published KORMARC documentation - 한국문헌자동화목록형식 (KORMARC), the
  integrated bibliographic format, KS X 6006, National Library of Korea,
  <https://www.nl.go.kr/> - and from the MARC 21 Format for Bibliographic
  Data on the source side. Nothing is copied from those documents.

  SOURCE REACHABILITY: as in kormarc-to-marc21.xsl, the NLK's KORMARC field
  pages are refused by this environment's network egress policy, so the
  KORMARC side rests on the format's published field list (049, 052, 056,
  090, 940, 950 and the 9XX local block) rather than on a fetched copy of
  the standard.

  WHY THIS IS A SMALL SHEET: KORMARC is MARC 21-structured, so everything
  not named below is copied through unchanged, in tag order.

  CONTAINER: MARC 21 slim XML in and out.

  COVERAGE (MARC 21 -> KORMARC):
    084 with $2 kdc -> 056   $a -> $a, $b -> $b; the $2 scheme code is
                             consumed (056 is the KDC field by definition).
                             084 with any other $2, or none, is copied
                             through as 084
    852             -> 049   $p piece designation -> $l registration
      (+090)                 number, $c shelving location -> $f, $3 -> $v,
                             $t copy number -> $c; the call number in
                             $h/$i becomes a 090 ($a/$b).  852 fields
                             carrying neither holdings subfields nor a call
                             number are copied through as 852
    037 $c          -> 950   local price information, in $b
    everything else          copied verbatim, in tag order

  LOSSES AND EXCLUSIONS (deliberate):
    * 246 is NOT converted back to 940: MARC 21 246 covers many kinds of
      varying title, and only some libraries record any of them as a local
      940 heading. A 940 that made a 246 on the way out stays a 246 on the
      way back.
    * The KDC edition number that 056 can carry is not invented here: it
      was not in the MARC 21 record.
    * 052 is not generated: the National Library of Korea call number is
      not derivable from a MARC 21 record, and MARC 21's own 052 means
      Geographic Classification - so an incoming 052 is copied through
      unchanged and will read as geographic classification in KORMARC.
      Records converted with kormarc-to-marc21.xsl carry that call number
      in 852 and come back as 090.
    * 008 is copied unchanged: the KORMARC positions are MARC 21's.
    * 9XX local fields are copied through untyped.
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

  <xsl:template name="mk-copy">
    <datafield tag="{@tag}" ind1="{@ind1}" ind2="{@ind2}">
      <xsl:for-each select="marc:subfield">
        <subfield code="{@code}"><xsl:value-of select="."/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:template>

  <xsl:template match="/marc:record | marc:record">
    <xsl:variable name="holdings"
        select="marc:datafield[@tag='852'][marc:subfield[@code='p' or @code='c'
                or @code='3' or @code='t' or @code='h' or @code='i']]"/>
    <record>

      <xsl:copy-of select="marc:leader"/>
      <xsl:for-each select="marc:controlfield">
        <controlfield tag="{@tag}"><xsl:value-of select="."/></controlfield>
      </xsl:for-each>

      <!-- 010-036 -->
      <xsl:for-each select="marc:datafield[@tag &lt; 37]">
        <xsl:call-template name="mk-copy"/>
      </xsl:for-each>

      <!-- 037 without the price subfield stays; the price becomes 950 -->
      <xsl:for-each select="marc:datafield[@tag='037'][marc:subfield[not(@code='c')]]">
        <xsl:call-template name="mk-copy"/>
      </xsl:for-each>

      <!-- 038-048 -->
      <xsl:for-each select="marc:datafield[@tag &gt; 37 and @tag &lt; 49]">
        <xsl:call-template name="mk-copy"/>
      </xsl:for-each>

      <!-- 049 holdings, from 852 -->
      <xsl:for-each select="$holdings">
        <xsl:if test="marc:subfield[@code='p' or @code='c' or @code='3' or @code='t']">
          <datafield tag="049" ind1="0" ind2=" ">
            <xsl:for-each select="marc:subfield[@code='p']">
              <subfield code="l"><xsl:value-of select="normalize-space(.)"/></subfield>
            </xsl:for-each>
            <xsl:for-each select="marc:subfield[@code='c']">
              <subfield code="f"><xsl:value-of select="normalize-space(.)"/></subfield>
            </xsl:for-each>
            <xsl:for-each select="marc:subfield[@code='3']">
              <subfield code="v"><xsl:value-of select="normalize-space(.)"/></subfield>
            </xsl:for-each>
            <xsl:for-each select="marc:subfield[@code='t']">
              <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
            </xsl:for-each>
          </datafield>
        </xsl:if>
      </xsl:for-each>

      <!-- 050-055 -->
      <xsl:for-each select="marc:datafield[@tag &gt; 49 and @tag &lt; 56]">
        <xsl:call-template name="mk-copy"/>
      </xsl:for-each>

      <!-- 056 KDC classification, from 084 $2 kdc -->
      <xsl:for-each select="marc:datafield[@tag='084']
                            [normalize-space(marc:subfield[@code='2'][1]) = 'kdc']">
        <datafield tag="056" ind1=" " ind2=" ">
          <xsl:for-each select="marc:subfield[@code='a']">
            <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='b']">
            <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
        </datafield>
      </xsl:for-each>

      <!-- 057-089, with the KDC-sourced 084 already handled -->
      <xsl:for-each select="marc:datafield[@tag &gt; 56 and @tag &lt; 90]
                            [not(@tag='084'
                                 and normalize-space(marc:subfield[@code='2'][1]) = 'kdc')]">
        <xsl:call-template name="mk-copy"/>
      </xsl:for-each>

      <!-- 090 local call number, from the 852 call-number subfields -->
      <xsl:for-each select="$holdings[marc:subfield[@code='h' or @code='i']][1]">
        <datafield tag="090" ind1=" " ind2=" ">
          <xsl:for-each select="marc:subfield[@code='h']">
            <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='i']">
            <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
          </xsl:for-each>
        </datafield>
      </xsl:for-each>

      <!-- 091-851 -->
      <xsl:for-each select="marc:datafield[@tag &gt; 90 and @tag &lt; 852]">
        <xsl:call-template name="mk-copy"/>
      </xsl:for-each>

      <!-- 852 fields that carried nothing KORMARC keeps elsewhere -->
      <xsl:for-each select="marc:datafield[@tag='852'][not(marc:subfield[@code='p'
                            or @code='c' or @code='3' or @code='t' or @code='h'
                            or @code='i'])]">
        <xsl:call-template name="mk-copy"/>
      </xsl:for-each>

      <!-- 853-949 -->
      <xsl:for-each select="marc:datafield[@tag &gt; 852 and @tag &lt; 950]">
        <xsl:call-template name="mk-copy"/>
      </xsl:for-each>

      <!-- 950 local price information, from 037 $c -->
      <xsl:for-each select="marc:datafield[@tag='037']/marc:subfield[@code='c']">
        <datafield tag="950" ind1="0" ind2=" ">
          <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
        </datafield>
      </xsl:for-each>

      <!-- 951 and above -->
      <xsl:for-each select="marc:datafield[@tag &gt; 950]">
        <xsl:call-template name="mk-copy"/>
      </xsl:for-each>

    </record>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
