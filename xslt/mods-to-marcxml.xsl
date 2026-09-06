<?xml version="1.0" encoding="UTF-8"?>
<!--
  mods-to-marcxml.xsl - MODS 3.x back to MARCXML (slim), covering the
  core elements the forward crosswalk (marcxml-to-mods.xsl) produces.

  Original crosswalk for the duckdb-marc21 project, implemented from the
  Library of Congress "MODS to MARC" mapping specification. The output
  is a well-formed slim collection with a synthesized leader and 008;
  ISBD punctuation is not regenerated (values are carried plain).

  Accepts mods:modsCollection or a single mods:mods root. XSLT 1.0.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:mods="http://www.loc.gov/mods/v3"
    xmlns="http://www.loc.gov/MARC21/slim"
    exclude-result-prefixes="mods">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:template match="/">
    <collection>
      <xsl:apply-templates select="//mods:mods"/>
    </collection>
  </xsl:template>

  <xsl:template match="mods:mods">
    <record>
      <leader>
        <xsl:call-template name="build-leader"/>
      </leader>
      <xsl:if test="mods:recordInfo/mods:recordIdentifier">
        <controlfield tag="001">
          <xsl:value-of select="normalize-space(mods:recordInfo/mods:recordIdentifier[1])"/>
        </controlfield>
        <xsl:if test="mods:recordInfo/mods:recordIdentifier[1]/@source">
          <controlfield tag="003">
            <xsl:value-of select="mods:recordInfo/mods:recordIdentifier[1]/@source"/>
          </controlfield>
        </xsl:if>
      </xsl:if>
      <controlfield tag="008">
        <xsl:call-template name="build-008"/>
      </controlfield>

      <xsl:apply-templates select="mods:identifier[@type='lccn']" mode="df010"/>
      <xsl:apply-templates select="mods:identifier[@type='isbn']" mode="df020"/>
      <xsl:apply-templates select="mods:identifier[@type='issn']" mode="df022"/>
      <xsl:apply-templates select="mods:classification" mode="dfclass"/>
      <xsl:apply-templates select="mods:name[@usage='primary']" mode="dfname"/>
      <xsl:apply-templates select="mods:titleInfo[@type='uniform']" mode="df240"/>
      <xsl:apply-templates select="mods:titleInfo[not(@type)][1]" mode="df245"/>
      <xsl:apply-templates select="mods:titleInfo[@type='alternative']" mode="df246"/>
      <xsl:apply-templates select="mods:originInfo/mods:edition" mode="df250"/>
      <xsl:call-template name="df26x"/>
      <xsl:apply-templates select="mods:physicalDescription/mods:extent" mode="df300"/>
      <xsl:apply-templates select="mods:relatedItem[@type='series']" mode="df490"/>
      <xsl:apply-templates select="mods:note[not(@type='statement of responsibility')]"
          mode="df500"/>
      <xsl:apply-templates select="mods:tableOfContents" mode="df505"/>
      <xsl:apply-templates select="mods:abstract" mode="df520"/>
      <xsl:apply-templates select="mods:targetAudience" mode="df521"/>
      <xsl:apply-templates select="mods:subject" mode="df6xx"/>
      <xsl:apply-templates select="mods:genre" mode="df655"/>
      <xsl:apply-templates select="mods:name[not(@usage='primary')]" mode="dfname"/>
      <xsl:apply-templates select="mods:relatedItem[@type='host']" mode="df773"/>
      <xsl:apply-templates select="mods:location/mods:url" mode="df856"/>
    </record>
  </xsl:template>

  <!-- ===================== fixed fields ========================== -->

  <xsl:template name="build-leader">
    <xsl:variable name="tor" select="normalize-space(mods:typeOfResource[1])"/>
    <xsl:variable name="c6">
      <xsl:choose>
        <xsl:when test="$tor = 'cartographic'">e</xsl:when>
        <xsl:when test="$tor = 'notated music'">c</xsl:when>
        <xsl:when test="$tor = 'sound recording-nonmusical'">i</xsl:when>
        <xsl:when test="$tor = 'sound recording-musical'">j</xsl:when>
        <xsl:when test="$tor = 'sound recording'">i</xsl:when>
        <xsl:when test="$tor = 'still image'">k</xsl:when>
        <xsl:when test="$tor = 'moving image'">g</xsl:when>
        <xsl:when test="$tor = 'software, multimedia'">m</xsl:when>
        <xsl:when test="$tor = 'three dimensional object'">r</xsl:when>
        <xsl:when test="$tor = 'mixed material'">p</xsl:when>
        <xsl:otherwise>a</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="issu" select="normalize-space(mods:originInfo/mods:issuance[1])"/>
    <xsl:variable name="c7">
      <xsl:choose>
        <xsl:when test="$issu = 'serial'">s</xsl:when>
        <xsl:when test="$issu = 'integrating resource'">i</xsl:when>
        <xsl:when test="$issu = 'continuing'">s</xsl:when>
        <xsl:otherwise>m</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:value-of select="concat('00000n', $c6, $c7, ' a2200000 a 4500')"/>
  </xsl:template>

  <xsl:template name="build-008">
    <xsl:variable name="entered">
      <xsl:choose>
        <xsl:when test="string-length(normalize-space(
                        mods:recordInfo/mods:recordCreationDate[@encoding='marc'][1])) = 6">
          <xsl:value-of select="normalize-space(
                        mods:recordInfo/mods:recordCreationDate[@encoding='marc'][1])"/>
        </xsl:when>
        <xsl:otherwise>
          <xsl:text>      </xsl:text>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="rawdate">
      <xsl:choose>
        <xsl:when test="mods:originInfo/mods:dateIssued[@encoding='marc'][not(@point='end')]">
          <xsl:value-of select="mods:originInfo/mods:dateIssued[@encoding='marc'][not(@point='end')][1]"/>
        </xsl:when>
        <xsl:otherwise>
          <xsl:value-of select="mods:originInfo/mods:dateIssued[1]"/>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="digits"
        select="translate($rawdate, translate($rawdate, '0123456789', ''), '')"/>
    <xsl:variable name="d1"
        select="substring(concat(substring($digits, 1, 4), '    '), 1, 4)"/>
    <xsl:variable name="dtype">
      <xsl:choose>
        <xsl:when test="translate($d1, ' ', '') = ''">n</xsl:when>
        <xsl:otherwise>s</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="lng"
        select="normalize-space(mods:language/mods:languageTerm[@type='code'][1])"/>
    <xsl:variable name="l3"
        select="substring(concat($lng, '   '), 1, 3)"/>
    <!-- 00-05 entered | 06 type | 07-10 date1 | 11-14 date2 | 15-17 place
         18-34 material blanks | 35-37 language | 38-39 -->
    <xsl:value-of select="concat($entered, $dtype, $d1, '    ', 'xx ',
                          '                 ', $l3, ' d')"/>
  </xsl:template>

  <!-- ===================== identifiers =========================== -->

  <xsl:template match="mods:identifier" mode="df010">
    <datafield tag="010" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
    </datafield>
  </xsl:template>

  <xsl:template match="mods:identifier" mode="df020">
    <datafield tag="020" ind1=" " ind2=" ">
      <subfield code="{substring('az', 1 + boolean(@invalid='yes'), 1)}">
        <xsl:value-of select="normalize-space(.)"/>
      </subfield>
    </datafield>
  </xsl:template>

  <xsl:template match="mods:identifier" mode="df022">
    <datafield tag="022" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
    </datafield>
  </xsl:template>

  <xsl:template match="mods:classification" mode="dfclass">
    <xsl:variable name="tag">
      <xsl:choose>
        <xsl:when test="@authority='lcc'">050</xsl:when>
        <xsl:when test="@authority='ddc'">082</xsl:when>
        <xsl:otherwise>084</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <datafield tag="{$tag}" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      <xsl:if test="$tag = '084' and @authority">
        <subfield code="2"><xsl:value-of select="@authority"/></subfield>
      </xsl:if>
    </datafield>
  </xsl:template>

  <!-- ======================== titles ============================= -->

  <xsl:template match="mods:titleInfo" mode="df245">
    <xsl:variable name="ns" select="normalize-space(mods:nonSort)"/>
    <xsl:variable name="skip">
      <xsl:choose>
        <xsl:when test="string-length($ns) &gt; 0 and string-length($ns) &lt; 9">
          <xsl:value-of select="string-length($ns) + 1"/>
        </xsl:when>
        <xsl:otherwise>0</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <datafield tag="245" ind2="{$skip}">
      <xsl:attribute name="ind1">
        <xsl:choose>
          <xsl:when test="../mods:name[@usage='primary']">1</xsl:when>
          <xsl:otherwise>0</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <subfield code="a">
        <xsl:if test="string-length($ns) &gt; 0">
          <xsl:value-of select="concat($ns, ' ')"/>
        </xsl:if>
        <xsl:value-of select="normalize-space(mods:title)"/>
        <xsl:if test="mods:subTitle">
          <xsl:text> :</xsl:text>
        </xsl:if>
      </subfield>
      <xsl:if test="mods:subTitle">
        <subfield code="b"><xsl:value-of select="normalize-space(mods:subTitle)"/></subfield>
      </xsl:if>
      <xsl:for-each select="mods:partNumber">
        <subfield code="n"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="mods:partName">
        <subfield code="p"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="../mods:note[@type='statement of responsibility'][1]">
        <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:template>

  <xsl:template match="mods:titleInfo" mode="df240">
    <datafield tag="240" ind1="1" ind2="0">
      <subfield code="a"><xsl:value-of select="normalize-space(mods:title)"/></subfield>
    </datafield>
  </xsl:template>

  <xsl:template match="mods:titleInfo" mode="df246">
    <datafield tag="246" ind1="3" ind2=" ">
      <xsl:if test="@displayLabel">
        <subfield code="i"><xsl:value-of select="@displayLabel"/></subfield>
      </xsl:if>
      <subfield code="a"><xsl:value-of select="normalize-space(mods:title)"/></subfield>
    </datafield>
  </xsl:template>

  <!-- ========================= names ============================= -->

  <xsl:template match="mods:name" mode="dfname">
    <xsl:variable name="tag">
      <xsl:choose>
        <xsl:when test="@usage='primary' and @type='corporate'">110</xsl:when>
        <xsl:when test="@usage='primary' and @type='conference'">111</xsl:when>
        <xsl:when test="@usage='primary'">100</xsl:when>
        <xsl:when test="@type='corporate'">710</xsl:when>
        <xsl:when test="@type='conference'">711</xsl:when>
        <xsl:otherwise>700</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="i1">
      <xsl:choose>
        <xsl:when test="@type='corporate'">2</xsl:when>
        <xsl:when test="@type='conference'">2</xsl:when>
        <xsl:when test="contains(mods:namePart[not(@type)][1], ',')">1</xsl:when>
        <xsl:otherwise>0</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <datafield tag="{$tag}" ind1="{$i1}" ind2=" ">
      <subfield code="a">
        <xsl:value-of select="normalize-space(mods:namePart[not(@type)][1])"/>
        <xsl:if test="mods:namePart[@type='date']">,</xsl:if>
      </subfield>
      <xsl:for-each select="mods:namePart[@type='date'][1]">
        <subfield code="d"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="mods:role/mods:roleTerm[@type='text']">
        <subfield code="e"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="mods:role/mods:roleTerm[@type='code']">
        <subfield code="4"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:template>

  <!-- ==================== imprint block ========================== -->

  <xsl:template match="mods:edition" mode="df250">
    <datafield tag="250" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
    </datafield>
  </xsl:template>

  <xsl:template name="df26x">
    <xsl:for-each select="mods:originInfo[mods:place or mods:publisher
                          or mods:dateIssued[not(@encoding)]][1]">
      <datafield tag="264" ind1=" " ind2="1">
        <xsl:for-each select="mods:place/mods:placeTerm[@type='text']">
          <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
        </xsl:for-each>
        <xsl:for-each select="mods:publisher">
          <subfield code="b"><xsl:value-of select="normalize-space(.)"/></subfield>
        </xsl:for-each>
        <xsl:for-each select="mods:dateIssued[not(@encoding)][1]">
          <subfield code="c"><xsl:value-of select="normalize-space(.)"/></subfield>
        </xsl:for-each>
      </datafield>
    </xsl:for-each>
    <xsl:for-each select="mods:originInfo/mods:copyrightDate[1]">
      <datafield tag="264" ind1=" " ind2="4">
        <subfield code="c">
          <xsl:value-of select="concat('©', normalize-space(.))"/>
        </subfield>
      </datafield>
    </xsl:for-each>
    <xsl:for-each select="mods:originInfo/mods:frequency">
      <datafield tag="310" ind1=" " ind2=" ">
        <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      </datafield>
    </xsl:for-each>
    <!-- languages beyond the first become 041 -->
    <xsl:if test="count(mods:language/mods:languageTerm[@type='code']) &gt; 1">
      <datafield tag="041" ind1=" " ind2=" ">
        <xsl:for-each select="mods:language/mods:languageTerm[@type='code']">
          <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
        </xsl:for-each>
      </datafield>
    </xsl:if>
  </xsl:template>

  <!-- ================= physical description ====================== -->

  <xsl:template match="mods:extent" mode="df300">
    <datafield tag="300" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
    </datafield>
  </xsl:template>

  <!-- ===================== notes block =========================== -->

  <xsl:template match="mods:note" mode="df500">
    <xsl:variable name="tag">
      <xsl:choose>
        <xsl:when test="@type='bibliography'">504</xsl:when>
        <xsl:when test="@type='performers'">511</xsl:when>
        <xsl:when test="@type='language'">546</xsl:when>
        <xsl:when test="@type='ownership'">561</xsl:when>
        <xsl:otherwise>500</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <datafield tag="{$tag}" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
    </datafield>
  </xsl:template>

  <xsl:template match="mods:tableOfContents" mode="df505">
    <datafield tag="505" ind1="0" ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
    </datafield>
  </xsl:template>

  <xsl:template match="mods:abstract" mode="df520">
    <datafield tag="520" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
    </datafield>
  </xsl:template>

  <xsl:template match="mods:targetAudience" mode="df521">
    <datafield tag="521" ind1=" " ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
    </datafield>
  </xsl:template>

  <!-- ======================= subjects ============================ -->

  <xsl:template match="mods:subject" mode="df6xx">
    <xsl:variable name="i2">
      <xsl:choose>
        <xsl:when test="@authority='lcsh'">0</xsl:when>
        <xsl:when test="@authority='lcshac'">1</xsl:when>
        <xsl:when test="@authority='mesh'">2</xsl:when>
        <xsl:when test="@authority='nal'">3</xsl:when>
        <xsl:when test="@authority='csh'">5</xsl:when>
        <xsl:when test="@authority='rvm'">6</xsl:when>
        <xsl:when test="@authority">7</xsl:when>
        <xsl:otherwise>4</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="tag">
      <xsl:choose>
        <xsl:when test="mods:name[@type='personal']">600</xsl:when>
        <xsl:when test="mods:name[@type='corporate']">610</xsl:when>
        <xsl:when test="mods:name[@type='conference']">611</xsl:when>
        <xsl:when test="mods:titleInfo">630</xsl:when>
        <xsl:when test="mods:geographic and not(mods:topic)">651</xsl:when>
        <xsl:when test="mods:temporal and not(mods:topic)">648</xsl:when>
        <xsl:otherwise>650</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <datafield tag="{$tag}" ind2="{$i2}">
      <xsl:attribute name="ind1">
        <xsl:choose>
          <xsl:when test="$tag='600'">1</xsl:when>
          <xsl:when test="$tag='610'">2</xsl:when>
          <xsl:otherwise><xsl:text> </xsl:text></xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <!-- heading -->
      <xsl:choose>
        <xsl:when test="mods:name">
          <subfield code="a">
            <xsl:value-of select="normalize-space(mods:name/mods:namePart[1])"/>
          </subfield>
        </xsl:when>
        <xsl:when test="mods:titleInfo">
          <subfield code="a">
            <xsl:value-of select="normalize-space(mods:titleInfo/mods:title[1])"/>
          </subfield>
        </xsl:when>
        <xsl:otherwise>
          <xsl:variable name="lead"
              select="(mods:topic | mods:geographic | mods:temporal)[1]"/>
          <subfield code="a"><xsl:value-of select="normalize-space($lead)"/></subfield>
        </xsl:otherwise>
      </xsl:choose>
      <!-- subdivisions: everything after the heading element -->
      <xsl:for-each select="(mods:topic | mods:geographic | mods:temporal | mods:genre)
                            [position() &gt; 1 or ../mods:name or ../mods:titleInfo]">
        <xsl:variable name="code">
          <xsl:choose>
            <xsl:when test="self::mods:topic">x</xsl:when>
            <xsl:when test="self::mods:geographic">z</xsl:when>
            <xsl:when test="self::mods:temporal">y</xsl:when>
            <xsl:otherwise>v</xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <subfield code="{$code}"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:if test="$i2 = '7' and @authority">
        <subfield code="2"><xsl:value-of select="@authority"/></subfield>
      </xsl:if>
    </datafield>
  </xsl:template>

  <xsl:template match="mods:genre" mode="df655">
    <datafield tag="655" ind1=" " ind2="7">
      <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
      <xsl:if test="@authority">
        <subfield code="2"><xsl:value-of select="@authority"/></subfield>
      </xsl:if>
    </datafield>
  </xsl:template>

  <!-- ==================== related items ========================== -->

  <xsl:template match="mods:relatedItem" mode="df490">
    <datafield tag="490" ind1="0" ind2=" ">
      <subfield code="a">
        <xsl:value-of select="normalize-space(mods:titleInfo/mods:title[1])"/>
      </subfield>
    </datafield>
  </xsl:template>

  <xsl:template match="mods:relatedItem" mode="df773">
    <datafield tag="773" ind1="0" ind2=" ">
      <xsl:if test="mods:titleInfo/mods:title">
        <subfield code="t">
          <xsl:value-of select="normalize-space(mods:titleInfo/mods:title[1])"/>
        </subfield>
      </xsl:if>
      <xsl:for-each select="mods:identifier[@type='issn']">
        <subfield code="x"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="mods:identifier[@type='isbn']">
        <subfield code="z"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="mods:identifier[@type='local']">
        <subfield code="w"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="mods:part/mods:text">
        <subfield code="g"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
    </datafield>
  </xsl:template>

  <!-- ====================== locations ============================ -->

  <xsl:template match="mods:url" mode="df856">
    <datafield tag="856" ind1="4" ind2="{substring('0 ', 2 - boolean(@usage), 1)}">
      <subfield code="u"><xsl:value-of select="normalize-space(.)"/></subfield>
      <xsl:if test="@displayLabel">
        <subfield code="z"><xsl:value-of select="@displayLabel"/></subfield>
      </xsl:if>
    </datafield>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
