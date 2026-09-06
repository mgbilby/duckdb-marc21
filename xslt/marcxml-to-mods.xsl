<?xml version="1.0" encoding="UTF-8"?>
<!--
  marcxml-to-mods.xsl - MARCXML (slim) to MODS 3.7.

  Original crosswalk for the duckdb-marc21 project, implemented directly
  from the Library of Congress "MARC to MODS" mapping specification
  (a public-domain mapping document). Template structure and naming are
  this project's own; see xslt/DISTINCTNESS.md.

  Accepts either a single marc:record document element or a
  marc:collection of records. XSLT 1.0.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns="http://www.loc.gov/mods/v3"
    exclude-result-prefixes="marc">

  <xsl:include href="marc-utils.xsl"/>

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <!-- =========================== roots =========================== -->

  <xsl:template match="/marc:collection">
    <modsCollection
        xsi:schemaLocation="http://www.loc.gov/mods/v3 http://www.loc.gov/standards/mods/v3/mods-3-7.xsd">
      <xsl:apply-templates select="marc:record"/>
    </modsCollection>
  </xsl:template>

  <xsl:template match="/marc:record">
    <xsl:call-template name="one-mods">
      <xsl:with-param name="standalone" select="true()"/>
    </xsl:call-template>
  </xsl:template>

  <!-- tolerate records reached under other wrappers (OAI/SRU slices) -->
  <xsl:template match="marc:record">
    <xsl:call-template name="one-mods"/>
  </xsl:template>

  <!-- ======================= one record ========================== -->

  <xsl:template name="one-mods">
    <xsl:param name="standalone" select="false()"/>
    <mods version="3.7">
      <xsl:if test="$standalone">
        <xsl:attribute name="xsi:schemaLocation">http://www.loc.gov/mods/v3 http://www.loc.gov/standards/mods/v3/mods-3-7.xsd</xsl:attribute>
      </xsl:if>

      <xsl:apply-templates select="marc:datafield[@tag='245']" mode="m-title"/>
      <xsl:apply-templates select="marc:datafield[@tag='130' or @tag='240']" mode="m-title-uniform"/>
      <xsl:apply-templates select="marc:datafield[@tag='246']" mode="m-title-alt"/>
      <xsl:apply-templates select="marc:datafield[@tag='880']" mode="m-vernacular"/>

      <xsl:apply-templates
          select="marc:datafield[@tag='100' or @tag='110' or @tag='111'
                  or @tag='700' or @tag='710' or @tag='711']" mode="m-agent"/>

      <xsl:call-template name="m-resource-type"/>
      <xsl:apply-templates select="marc:datafield[@tag='655']" mode="m-genre"/>

      <xsl:call-template name="m-origin"/>
      <xsl:call-template name="m-language"/>
      <xsl:call-template name="m-physical"/>

      <xsl:apply-templates select="marc:datafield[@tag='520']" mode="m-abstract"/>
      <xsl:apply-templates select="marc:datafield[@tag='505']" mode="m-toc"/>
      <xsl:apply-templates select="marc:datafield[@tag='521']" mode="m-audience"/>
      <xsl:apply-templates
          select="marc:datafield[starts-with(@tag,'5')
                  and not(@tag='505' or @tag='520' or @tag='521')]" mode="m-note"/>
      <xsl:apply-templates select="marc:datafield[@tag='245'][marc:subfield[@code='c']]"
          mode="m-responsibility"/>

      <xsl:apply-templates
          select="marc:datafield[@tag='600' or @tag='610' or @tag='611'
                  or @tag='630' or @tag='648' or @tag='650' or @tag='651']" mode="m-subject"/>

      <xsl:apply-templates select="marc:datafield[@tag='050' or @tag='082' or @tag='084']"
          mode="m-class"/>

      <xsl:apply-templates
          select="marc:datafield[@tag='010' or @tag='020' or @tag='022'
                  or @tag='024' or @tag='035']" mode="m-ident"/>

      <xsl:apply-templates select="marc:datafield[@tag='856']" mode="m-location"/>
      <xsl:apply-templates select="marc:datafield[@tag='852']" mode="m-holding"/>

      <xsl:apply-templates
          select="marc:datafield[@tag='440' or @tag='490'
                  or @tag='800' or @tag='810' or @tag='811' or @tag='830']" mode="m-series"/>
      <xsl:apply-templates
          select="marc:datafield[@tag &gt;= '760' and @tag &lt;= '787']" mode="m-linking"/>

      <xsl:call-template name="m-recordinfo"/>
    </mods>
  </xsl:template>

  <!-- ========================= titles ============================ -->

  <xsl:template match="marc:datafield" mode="m-title">
    <titleInfo>
      <xsl:if test="../marc:datafield[@tag='880']
                    [marc:subfield[@code='6'][starts-with(normalize-space(.), '245')]]">
        <xsl:attribute name="altRepGroup">t245</xsl:attribute>
      </xsl:if>
      <xsl:call-template name="m-title-body"/>
    </titleInfo>
  </xsl:template>

  <xsl:template name="m-title-body">
    <xsl:variable name="skip">
      <xsl:call-template name="mu-ind-number">
        <xsl:with-param name="ind" select="@ind2"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="raw" select="normalize-space(marc:subfield[@code='a'][1])"/>
    <xsl:if test="$skip &gt; 0">
      <nonSort>
        <xsl:value-of select="normalize-space(substring($raw, 1, $skip))"/>
      </nonSort>
    </xsl:if>
    <title>
      <xsl:call-template name="mu-chomp">
        <xsl:with-param name="s" select="substring($raw, $skip + 1)"/>
      </xsl:call-template>
    </title>
    <xsl:if test="marc:subfield[@code='b']">
      <subTitle>
        <xsl:call-template name="mu-chomp">
          <xsl:with-param name="s">
            <xsl:call-template name="mu-field-text">
              <xsl:with-param name="want" select="'b'"/>
            </xsl:call-template>
          </xsl:with-param>
        </xsl:call-template>
      </subTitle>
    </xsl:if>
    <xsl:for-each select="marc:subfield[@code='n']">
      <partNumber>
        <xsl:call-template name="mu-chomp">
          <xsl:with-param name="s" select="."/>
        </xsl:call-template>
      </partNumber>
    </xsl:for-each>
    <xsl:for-each select="marc:subfield[@code='p']">
      <partName>
        <xsl:call-template name="mu-chomp">
          <xsl:with-param name="s" select="."/>
        </xsl:call-template>
      </partName>
    </xsl:for-each>
  </xsl:template>

  <xsl:template match="marc:datafield" mode="m-title-uniform">
    <titleInfo type="uniform">
      <title>
        <xsl:call-template name="mu-chomp">
          <xsl:with-param name="s">
            <xsl:call-template name="mu-field-text">
              <xsl:with-param name="want" select="'adfghklmnoprs'"/>
            </xsl:call-template>
          </xsl:with-param>
        </xsl:call-template>
      </title>
    </titleInfo>
  </xsl:template>

  <xsl:template match="marc:datafield" mode="m-title-alt">
    <titleInfo type="alternative">
      <xsl:if test="marc:subfield[@code='i']">
        <xsl:attribute name="displayLabel">
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="marc:subfield[@code='i'][1]"/>
          </xsl:call-template>
        </xsl:attribute>
      </xsl:if>
      <title>
        <xsl:call-template name="mu-chomp">
          <xsl:with-param name="s">
            <xsl:call-template name="mu-field-text">
              <xsl:with-param name="want" select="'abfnp'"/>
            </xsl:call-template>
          </xsl:with-param>
        </xsl:call-template>
      </title>
    </titleInfo>
  </xsl:template>

  <!-- 880: alternate graphic representation. Linked 245s become paired
       titleInfo elements; every other linkage is kept as a note so the
       data is never dropped. -->
  <xsl:template match="marc:datafield" mode="m-vernacular">
    <xsl:variable name="host">
      <xsl:call-template name="mu-linkage-tag">
        <xsl:with-param name="sf6" select="marc:subfield[@code='6'][1]"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:choose>
      <xsl:when test="$host = '245'">
        <titleInfo altRepGroup="t245">
          <xsl:call-template name="m-title-body"/>
        </titleInfo>
      </xsl:when>
      <xsl:otherwise>
        <note type="alternate-script">
          <xsl:if test="string-length($host) &gt; 0">
            <xsl:attribute name="displayLabel">
              <xsl:value-of select="concat('linked to ', $host)"/>
            </xsl:attribute>
          </xsl:if>
          <xsl:call-template name="mu-field-text"/>
        </note>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- ========================= agents ============================ -->

  <xsl:template match="marc:datafield" mode="m-agent">
    <name>
      <xsl:attribute name="type">
        <xsl:choose>
          <xsl:when test="@tag='100' or @tag='700'">personal</xsl:when>
          <xsl:when test="@tag='110' or @tag='710'">corporate</xsl:when>
          <xsl:otherwise>conference</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <xsl:if test="@tag='100' or @tag='110' or @tag='111'">
        <xsl:attribute name="usage">primary</xsl:attribute>
      </xsl:if>
      <namePart>
        <xsl:call-template name="mu-chomp">
          <xsl:with-param name="s">
            <xsl:call-template name="mu-field-text">
              <xsl:with-param name="want">
                <xsl:choose>
                  <xsl:when test="@tag='100' or @tag='700'">abcq</xsl:when>
                  <xsl:otherwise>abcdn</xsl:otherwise>
                </xsl:choose>
              </xsl:with-param>
            </xsl:call-template>
          </xsl:with-param>
        </xsl:call-template>
      </namePart>
      <xsl:if test="(@tag='100' or @tag='700') and marc:subfield[@code='d']">
        <namePart type="date">
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="marc:subfield[@code='d'][1]"/>
          </xsl:call-template>
        </namePart>
      </xsl:if>
      <xsl:for-each select="marc:subfield[@code='e' or (@code='j' and ../@tag='111')]">
        <role>
          <roleTerm type="text">
            <xsl:call-template name="mu-chomp">
              <xsl:with-param name="s" select="."/>
            </xsl:call-template>
          </roleTerm>
        </role>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='4']">
        <role>
          <roleTerm type="code" authority="marcrelator">
            <xsl:value-of select="normalize-space(.)"/>
          </roleTerm>
        </role>
      </xsl:for-each>
    </name>
  </xsl:template>

  <!-- ==================== type / genre =========================== -->

  <xsl:template name="m-resource-type">
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
    <xsl:variable name="term">
      <xsl:choose>
        <xsl:when test="$l6='a' or $l6='t'">text</xsl:when>
        <xsl:when test="$l6='e' or $l6='f'">cartographic</xsl:when>
        <xsl:when test="$l6='c' or $l6='d'">notated music</xsl:when>
        <xsl:when test="$l6='i'">sound recording-nonmusical</xsl:when>
        <xsl:when test="$l6='j'">sound recording-musical</xsl:when>
        <xsl:when test="$l6='k'">still image</xsl:when>
        <xsl:when test="$l6='g'">moving image</xsl:when>
        <xsl:when test="$l6='m'">software, multimedia</xsl:when>
        <xsl:when test="$l6='r'">three dimensional object</xsl:when>
        <xsl:when test="$l6='o' or $l6='p'">mixed material</xsl:when>
      </xsl:choose>
    </xsl:variable>
    <xsl:if test="string-length($term) &gt; 0">
      <typeOfResource>
        <xsl:if test="$l7='c' or $l7='s'">
          <xsl:attribute name="collection">yes</xsl:attribute>
        </xsl:if>
        <xsl:value-of select="$term"/>
      </typeOfResource>
    </xsl:if>
  </xsl:template>

  <xsl:template match="marc:datafield" mode="m-genre">
    <genre>
      <xsl:variable name="scheme">
        <xsl:call-template name="mu-subject-scheme">
          <xsl:with-param name="ind2" select="@ind2"/>
          <xsl:with-param name="sf2" select="marc:subfield[@code='2'][1]"/>
        </xsl:call-template>
      </xsl:variable>
      <xsl:if test="string-length($scheme) &gt; 0">
        <xsl:attribute name="authority">
          <xsl:value-of select="$scheme"/>
        </xsl:attribute>
      </xsl:if>
      <xsl:call-template name="mu-chomp">
        <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
      </xsl:call-template>
    </genre>
  </xsl:template>

  <!-- ====================== originInfo =========================== -->

  <xsl:template name="m-origin">
    <xsl:variable name="d1">
      <xsl:call-template name="mu-cf-slice">
        <xsl:with-param name="pos" select="7"/>
        <xsl:with-param name="len" select="4"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="d2">
      <xsl:call-template name="mu-cf-slice">
        <xsl:with-param name="pos" select="11"/>
        <xsl:with-param name="len" select="4"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="dtype">
      <xsl:call-template name="mu-cf-slice">
        <xsl:with-param name="pos" select="6"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="l7">
      <xsl:call-template name="mu-leader-at">
        <xsl:with-param name="pos" select="7"/>
      </xsl:call-template>
    </xsl:variable>

    <xsl:if test="marc:datafield[@tag='260' or @tag='264' or @tag='250' or @tag='310']
                  or translate($d1, ' |', '') != ''">
      <originInfo>
        <xsl:for-each select="marc:datafield[@tag='260'
                              or (@tag='264' and (@ind2='1' or @ind2=' ' or @ind2=''))][1]">
          <xsl:if test="@tag='264'">
            <xsl:attribute name="eventType">publication</xsl:attribute>
          </xsl:if>
          <xsl:for-each select="marc:subfield[@code='a']">
            <place>
              <placeTerm type="text">
                <xsl:call-template name="mu-chomp">
                  <xsl:with-param name="s" select="."/>
                </xsl:call-template>
              </placeTerm>
            </place>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='b']">
            <publisher>
              <xsl:call-template name="mu-chomp">
                <xsl:with-param name="s" select="."/>
              </xsl:call-template>
            </publisher>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='c']">
            <dateIssued>
              <xsl:call-template name="mu-unbracket">
                <xsl:with-param name="s">
                  <xsl:call-template name="mu-chomp">
                    <xsl:with-param name="s" select="."/>
                  </xsl:call-template>
                </xsl:with-param>
              </xsl:call-template>
            </dateIssued>
          </xsl:for-each>
        </xsl:for-each>

        <xsl:if test="translate($d1, ' |', '') != ''">
          <dateIssued encoding="marc">
            <xsl:if test="contains('cdikmq', $dtype)">
              <xsl:attribute name="point">start</xsl:attribute>
            </xsl:if>
            <xsl:value-of select="normalize-space($d1)"/>
          </dateIssued>
          <xsl:if test="contains('cdikmq', $dtype) and translate($d2, ' |', '') != ''">
            <dateIssued encoding="marc" point="end">
              <xsl:value-of select="normalize-space($d2)"/>
            </dateIssued>
          </xsl:if>
        </xsl:if>
        <xsl:for-each select="marc:datafield[@tag='264'][@ind2='4']/marc:subfield[@code='c']">
          <copyrightDate>
            <xsl:call-template name="mu-chomp">
              <xsl:with-param name="s" select="translate(., '©', '')"/>
            </xsl:call-template>
          </copyrightDate>
        </xsl:for-each>

        <xsl:for-each select="marc:datafield[@tag='250']/marc:subfield[@code='a']">
          <edition>
            <xsl:call-template name="mu-chomp">
              <xsl:with-param name="s" select="."/>
            </xsl:call-template>
          </edition>
        </xsl:for-each>
        <xsl:choose>
          <xsl:when test="$l7='m'"><issuance>monographic</issuance></xsl:when>
          <xsl:when test="$l7='s'"><issuance>serial</issuance></xsl:when>
          <xsl:when test="$l7='i'"><issuance>integrating resource</issuance></xsl:when>
        </xsl:choose>
        <xsl:for-each select="marc:datafield[@tag='310']/marc:subfield[@code='a']">
          <frequency>
            <xsl:call-template name="mu-chomp">
              <xsl:with-param name="s" select="."/>
            </xsl:call-template>
          </frequency>
        </xsl:for-each>
      </originInfo>
    </xsl:if>
  </xsl:template>

  <!-- ======================= language ============================ -->

  <xsl:template name="m-language">
    <xsl:variable name="cfl">
      <xsl:call-template name="mu-cf-slice">
        <xsl:with-param name="pos" select="35"/>
        <xsl:with-param name="len" select="3"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:if test="translate($cfl, ' |', '') != ''">
      <language>
        <languageTerm type="code" authority="iso639-2b">
          <xsl:value-of select="$cfl"/>
        </languageTerm>
      </language>
    </xsl:if>
    <xsl:for-each select="marc:datafield[@tag='041']/marc:subfield[@code='a']">
      <xsl:variable name="code" select="normalize-space(.)"/>
      <xsl:if test="$code != $cfl">
        <language>
          <languageTerm type="code" authority="iso639-2b">
            <xsl:value-of select="$code"/>
          </languageTerm>
        </language>
      </xsl:if>
    </xsl:for-each>
  </xsl:template>

  <!-- ================== physical description ===================== -->

  <xsl:template name="m-physical">
    <xsl:if test="marc:datafield[@tag='300'] or marc:datafield[@tag='856']/marc:subfield[@code='q']">
      <physicalDescription>
        <xsl:for-each select="marc:datafield[@tag='300']">
          <extent>
            <xsl:call-template name="mu-chomp">
              <xsl:with-param name="s">
                <xsl:call-template name="mu-field-text">
                  <xsl:with-param name="want" select="'abcefg'"/>
                </xsl:call-template>
              </xsl:with-param>
            </xsl:call-template>
          </extent>
        </xsl:for-each>
        <xsl:for-each select="marc:datafield[@tag='856']/marc:subfield[@code='q']">
          <internetMediaType>
            <xsl:value-of select="normalize-space(.)"/>
          </internetMediaType>
        </xsl:for-each>
      </physicalDescription>
    </xsl:if>
  </xsl:template>

  <!-- ================== notes and summaries ====================== -->

  <xsl:template match="marc:datafield" mode="m-abstract">
    <abstract>
      <xsl:call-template name="mu-field-text">
        <xsl:with-param name="want" select="'ab'"/>
      </xsl:call-template>
    </abstract>
  </xsl:template>

  <xsl:template match="marc:datafield" mode="m-toc">
    <tableOfContents>
      <xsl:call-template name="mu-field-text">
        <xsl:with-param name="want" select="'agrt'"/>
      </xsl:call-template>
    </tableOfContents>
  </xsl:template>

  <xsl:template match="marc:datafield" mode="m-audience">
    <targetAudience>
      <xsl:call-template name="mu-chomp">
        <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
      </xsl:call-template>
    </targetAudience>
  </xsl:template>

  <xsl:template match="marc:datafield" mode="m-responsibility">
    <note type="statement of responsibility">
      <xsl:call-template name="mu-chomp">
        <xsl:with-param name="s" select="marc:subfield[@code='c'][1]"/>
      </xsl:call-template>
    </note>
  </xsl:template>

  <xsl:template match="marc:datafield" mode="m-note">
    <note>
      <xsl:choose>
        <xsl:when test="@tag='504'">
          <xsl:attribute name="type">bibliography</xsl:attribute>
        </xsl:when>
        <xsl:when test="@tag='511'">
          <xsl:attribute name="type">performers</xsl:attribute>
        </xsl:when>
        <xsl:when test="@tag='518'">
          <xsl:attribute name="type">venue</xsl:attribute>
        </xsl:when>
        <xsl:when test="@tag='546'">
          <xsl:attribute name="type">language</xsl:attribute>
        </xsl:when>
        <xsl:when test="@tag='561'">
          <xsl:attribute name="type">ownership</xsl:attribute>
        </xsl:when>
      </xsl:choose>
      <xsl:call-template name="mu-field-text">
        <xsl:with-param name="want" select="'3abcdu'"/>
      </xsl:call-template>
    </note>
  </xsl:template>

  <!-- ======================== subjects =========================== -->

  <xsl:template match="marc:datafield" mode="m-subject">
    <subject>
      <xsl:variable name="scheme">
        <xsl:call-template name="mu-subject-scheme">
          <xsl:with-param name="ind2" select="@ind2"/>
          <xsl:with-param name="sf2" select="marc:subfield[@code='2'][1]"/>
        </xsl:call-template>
      </xsl:variable>
      <xsl:if test="string-length($scheme) &gt; 0">
        <xsl:attribute name="authority">
          <xsl:value-of select="$scheme"/>
        </xsl:attribute>
      </xsl:if>

      <xsl:choose>
        <xsl:when test="@tag='600'">
          <name type="personal">
            <namePart>
              <xsl:call-template name="mu-chomp">
                <xsl:with-param name="s">
                  <xsl:call-template name="mu-field-text">
                    <xsl:with-param name="want" select="'abcdq'"/>
                  </xsl:call-template>
                </xsl:with-param>
              </xsl:call-template>
            </namePart>
          </name>
        </xsl:when>
        <xsl:when test="@tag='610' or @tag='611'">
          <name>
            <xsl:attribute name="type">
              <xsl:choose>
                <xsl:when test="@tag='610'">corporate</xsl:when>
                <xsl:otherwise>conference</xsl:otherwise>
              </xsl:choose>
            </xsl:attribute>
            <namePart>
              <xsl:call-template name="mu-chomp">
                <xsl:with-param name="s">
                  <xsl:call-template name="mu-field-text">
                    <xsl:with-param name="want" select="'abcdn'"/>
                  </xsl:call-template>
                </xsl:with-param>
              </xsl:call-template>
            </namePart>
          </name>
        </xsl:when>
        <xsl:when test="@tag='630'">
          <titleInfo>
            <title>
              <xsl:call-template name="mu-chomp">
                <xsl:with-param name="s">
                  <xsl:call-template name="mu-field-text">
                    <xsl:with-param name="want" select="'adfp'"/>
                  </xsl:call-template>
                </xsl:with-param>
              </xsl:call-template>
            </title>
          </titleInfo>
        </xsl:when>
        <xsl:when test="@tag='648'">
          <temporal>
            <xsl:call-template name="mu-chomp">
              <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
            </xsl:call-template>
          </temporal>
        </xsl:when>
        <xsl:when test="@tag='651'">
          <geographic>
            <xsl:call-template name="mu-chomp">
              <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
            </xsl:call-template>
          </geographic>
        </xsl:when>
        <xsl:otherwise>
          <!-- 650: every $a is a topic -->
          <xsl:for-each select="marc:subfield[@code='a']">
            <topic>
              <xsl:call-template name="mu-chomp">
                <xsl:with-param name="s" select="."/>
              </xsl:call-template>
            </topic>
          </xsl:for-each>
        </xsl:otherwise>
      </xsl:choose>

      <!-- subdivisions, in document order -->
      <xsl:for-each select="marc:subfield[@code='x' or @code='y' or @code='z' or @code='v']">
        <xsl:variable name="txt">
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s" select="."/>
          </xsl:call-template>
        </xsl:variable>
        <xsl:choose>
          <xsl:when test="@code='x'"><topic><xsl:value-of select="$txt"/></topic></xsl:when>
          <xsl:when test="@code='y'"><temporal><xsl:value-of select="$txt"/></temporal></xsl:when>
          <xsl:when test="@code='z'"><geographic><xsl:value-of select="$txt"/></geographic></xsl:when>
          <xsl:otherwise><genre><xsl:value-of select="$txt"/></genre></xsl:otherwise>
        </xsl:choose>
      </xsl:for-each>
    </subject>
  </xsl:template>

  <!-- ==================== classification ========================= -->

  <xsl:template match="marc:datafield" mode="m-class">
    <classification>
      <xsl:choose>
        <xsl:when test="@tag='050'">
          <xsl:attribute name="authority">lcc</xsl:attribute>
        </xsl:when>
        <xsl:when test="@tag='082'">
          <xsl:attribute name="authority">ddc</xsl:attribute>
        </xsl:when>
        <xsl:when test="marc:subfield[@code='2']">
          <xsl:attribute name="authority">
            <xsl:value-of select="normalize-space(marc:subfield[@code='2'][1])"/>
          </xsl:attribute>
        </xsl:when>
      </xsl:choose>
      <xsl:call-template name="mu-field-text">
        <xsl:with-param name="want" select="'ab'"/>
      </xsl:call-template>
    </classification>
  </xsl:template>

  <!-- ====================== identifiers ========================== -->

  <xsl:template match="marc:datafield" mode="m-ident">
    <xsl:variable name="kind">
      <xsl:choose>
        <xsl:when test="@tag='010'">lccn</xsl:when>
        <xsl:when test="@tag='020'">isbn</xsl:when>
        <xsl:when test="@tag='022'">issn</xsl:when>
        <xsl:when test="@tag='024' and @ind1='0'">isrc</xsl:when>
        <xsl:when test="@tag='024' and @ind1='1'">upc</xsl:when>
        <xsl:when test="@tag='024' and @ind1='2'">ismn</xsl:when>
        <xsl:when test="@tag='024' and @ind1='7'">
          <xsl:value-of select="normalize-space(marc:subfield[@code='2'][1])"/>
        </xsl:when>
        <xsl:when test="@tag='024'">unspecified</xsl:when>
        <xsl:otherwise>local</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:for-each select="marc:subfield[@code='a']">
      <identifier type="{$kind}">
        <xsl:value-of select="normalize-space(.)"/>
      </identifier>
    </xsl:for-each>
    <xsl:for-each select="marc:subfield[@code='z']">
      <identifier type="{$kind}" invalid="yes">
        <xsl:value-of select="normalize-space(.)"/>
      </identifier>
    </xsl:for-each>
  </xsl:template>

  <!-- ======================= locations =========================== -->

  <xsl:template match="marc:datafield" mode="m-location">
    <xsl:if test="marc:subfield[@code='u']">
      <location>
        <url>
          <xsl:if test="marc:subfield[@code='y' or @code='z']">
            <xsl:attribute name="displayLabel">
              <xsl:value-of select="normalize-space(marc:subfield[@code='y' or @code='z'][1])"/>
            </xsl:attribute>
          </xsl:if>
          <xsl:if test="@ind2='0'">
            <xsl:attribute name="usage">primary display</xsl:attribute>
          </xsl:if>
          <xsl:value-of select="normalize-space(marc:subfield[@code='u'][1])"/>
        </url>
      </location>
    </xsl:if>
  </xsl:template>

  <xsl:template match="marc:datafield" mode="m-holding">
    <xsl:if test="marc:subfield[@code='a']">
      <location>
        <physicalLocation>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s">
              <xsl:call-template name="mu-field-text">
                <xsl:with-param name="want" select="'abc'"/>
              </xsl:call-template>
            </xsl:with-param>
          </xsl:call-template>
        </physicalLocation>
      </location>
    </xsl:if>
  </xsl:template>

  <!-- ====================== related items ======================== -->

  <xsl:template match="marc:datafield" mode="m-series">
    <relatedItem type="series">
      <titleInfo>
        <title>
          <xsl:call-template name="mu-chomp">
            <xsl:with-param name="s">
              <xsl:call-template name="mu-field-text">
                <xsl:with-param name="want">
                  <xsl:choose>
                    <xsl:when test="@tag='440' or @tag='490' or @tag='830'">anpv</xsl:when>
                    <xsl:otherwise>tv</xsl:otherwise>
                  </xsl:choose>
                </xsl:with-param>
              </xsl:call-template>
            </xsl:with-param>
          </xsl:call-template>
        </title>
      </titleInfo>
      <xsl:if test="(@tag='800' or @tag='810' or @tag='811') and marc:subfield[@code='a']">
        <name>
          <namePart>
            <xsl:call-template name="mu-chomp">
              <xsl:with-param name="s">
                <xsl:call-template name="mu-field-text">
                  <xsl:with-param name="want" select="'abcdq'"/>
                </xsl:call-template>
              </xsl:with-param>
            </xsl:call-template>
          </namePart>
        </name>
      </xsl:if>
    </relatedItem>
  </xsl:template>

  <xsl:template match="marc:datafield" mode="m-linking">
    <relatedItem>
      <xsl:choose>
        <xsl:when test="@tag='760' or @tag='762'">
          <xsl:attribute name="type">series</xsl:attribute>
        </xsl:when>
        <xsl:when test="@tag='765' or @tag='767' or @tag='775'">
          <xsl:attribute name="type">otherVersion</xsl:attribute>
        </xsl:when>
        <xsl:when test="@tag='770' or @tag='774'">
          <xsl:attribute name="type">constituent</xsl:attribute>
        </xsl:when>
        <xsl:when test="@tag='772' or @tag='773'">
          <xsl:attribute name="type">host</xsl:attribute>
        </xsl:when>
        <xsl:when test="@tag='776'">
          <xsl:attribute name="type">otherFormat</xsl:attribute>
        </xsl:when>
        <xsl:when test="@tag='780'">
          <xsl:attribute name="type">preceding</xsl:attribute>
        </xsl:when>
        <xsl:when test="@tag='785'">
          <xsl:attribute name="type">succeeding</xsl:attribute>
        </xsl:when>
        <xsl:when test="@tag='786'">
          <xsl:attribute name="type">original</xsl:attribute>
        </xsl:when>
      </xsl:choose>
      <xsl:if test="marc:subfield[@code='t' or @code='a']">
        <titleInfo>
          <title>
            <xsl:call-template name="mu-chomp">
              <xsl:with-param name="s" select="marc:subfield[@code='t' or @code='a'][1]"/>
            </xsl:call-template>
          </title>
        </titleInfo>
      </xsl:if>
      <xsl:for-each select="marc:subfield[@code='x']">
        <identifier type="issn"><xsl:value-of select="normalize-space(.)"/></identifier>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='z']">
        <identifier type="isbn"><xsl:value-of select="normalize-space(.)"/></identifier>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='w']">
        <identifier type="local"><xsl:value-of select="normalize-space(.)"/></identifier>
      </xsl:for-each>
      <xsl:for-each select="marc:subfield[@code='g']">
        <part>
          <text><xsl:value-of select="normalize-space(.)"/></text>
        </part>
      </xsl:for-each>
    </relatedItem>
  </xsl:template>

  <!-- ======================= recordInfo ========================== -->

  <xsl:template name="m-recordinfo">
    <recordInfo>
      <xsl:for-each select="marc:datafield[@tag='040']/marc:subfield[@code='a']">
        <recordContentSource authority="marcorg">
          <xsl:value-of select="normalize-space(.)"/>
        </recordContentSource>
      </xsl:for-each>
      <xsl:variable name="created">
        <xsl:call-template name="mu-cf-slice">
          <xsl:with-param name="pos" select="0"/>
          <xsl:with-param name="len" select="6"/>
        </xsl:call-template>
      </xsl:variable>
      <xsl:if test="translate($created, ' |', '') != ''">
        <recordCreationDate encoding="marc">
          <xsl:value-of select="$created"/>
        </recordCreationDate>
      </xsl:if>
      <xsl:for-each select="marc:controlfield[@tag='001'][1]">
        <recordIdentifier>
          <xsl:if test="../marc:controlfield[@tag='003']">
            <xsl:attribute name="source">
              <xsl:value-of select="normalize-space(../marc:controlfield[@tag='003'][1])"/>
            </xsl:attribute>
          </xsl:if>
          <xsl:value-of select="normalize-space(.)"/>
        </recordIdentifier>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='040']/marc:subfield[@code='b']">
        <languageOfCataloging>
          <languageTerm type="code" authority="iso639-2b">
            <xsl:value-of select="normalize-space(.)"/>
          </languageTerm>
        </languageOfCataloging>
      </xsl:for-each>
    </recordInfo>
  </xsl:template>

  <!-- swallow anything unmapped -->
  <xsl:template match="text()"/>

</xsl:stylesheet>
