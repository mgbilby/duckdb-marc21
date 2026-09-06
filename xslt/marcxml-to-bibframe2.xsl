<?xml version="1.0" encoding="UTF-8"?>
<!--
  marcxml-to-bibframe2.xsl - MARCXML (slim) to BIBFRAME 2.x RDF/XML.

  Original, compact crosswalk for the duckdb-marc21 project. The mapping
  semantics follow the public-domain Library of Congress sources: the
  BIBFRAME 2 ontology (http://id.loc.gov/ontologies/bibframe/), the
  id.loc.gov value vocabularies, and the documented conversion logic of
  LC's marc2bibframe2 project. The implementation is written from
  scratch; none of the LC converter code is vendored.

  Coverage (the honest subset - see docs/BIBFRAME.md for the contract):
    Work        rdf:type from Leader/06 (Text, NotatedMusic, Cartography,
                MovingImage, Audio, StillImage, Multimedia, Object,
                MixedMaterial); bf:title (245 a/b); bf:contribution
                (1XX/7XX, agent class from the tag, role from $4 as an
                id.loc.gov/vocabulary/relators URI or $e as a label;
                1XX additionally typed bflc:PrimaryContribution);
                bf:subject (600/610/611/630/648/650/651/653, label
                subdivided with double hyphen, @rdf:about from an http $0);
                bf:language (008/35-37 as id.loc.gov/vocabulary/languages);
                bf:classification (050 Lcc, 082 Ddc); bf:content (336$b as
                id.loc.gov/vocabulary/contentTypes); bf:adminMetadata
                carrying the 001 as a bf:Local identifier.
    Instance    bf:instanceOf/bf:hasInstance links; bf:title (245);
                bf:responsibilityStatement (245$c); bf:provisionActivity
                (264 _1 preferred over 260, bf:Publication with place,
                agent, date); bf:identifiedBy (020 Isbn, 022 Issn,
                010 Lccn, 035 OclcNumber for (OCoLC)-prefixed values);
                bf:extent (300$a); bf:media (337$b mediaTypes) and
                bf:carrier (338$b carriers); bf:electronicLocator (856$u).
    Item        only when an 852 is present: bf:heldBy (852 a/b) and
                bf:shelfMark (852 h/i/j/k).

  Not covered: 130/240 uniform titles, series, notes, 041 multiple
  languages, relationship entries (76X-78X), events, and everything else
  outside the list above. Unmapped fields are dropped silently.

  Node URIs are minted from the stylesheet parameter $baseuri plus the
  001 control number (generate-id() when there is no 001):
      {$baseuri}{001}#Work / #Instance / #Item
  XSLT 1.0; accepts a marc:collection or a bare marc:record.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    xmlns:rdfs="http://www.w3.org/2000/01/rdf-schema#"
    xmlns:bf="http://id.loc.gov/ontologies/bibframe/"
    xmlns:bflc="http://id.loc.gov/ontologies/bflc/"
    exclude-result-prefixes="marc">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:param name="baseuri" select="'http://example.org/'"/>

  <xsl:template match="/">
    <rdf:RDF>
      <xsl:apply-templates select="//marc:record"/>
    </rdf:RDF>
  </xsl:template>

  <xsl:template match="marc:record">
    <xsl:variable name="cn" select="normalize-space(marc:controlfield[@tag='001'])"/>
    <xsl:variable name="recid">
      <xsl:choose>
        <xsl:when test="$cn != ''"><xsl:value-of select="$cn"/></xsl:when>
        <xsl:otherwise><xsl:value-of select="generate-id(.)"/></xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="wuri" select="concat($baseuri, $recid, '#Work')"/>
    <xsl:variable name="iuri" select="concat($baseuri, $recid, '#Instance')"/>
    <xsl:variable name="cf008" select="marc:controlfield[@tag='008']"/>
    <xsl:variable name="l6" select="substring(marc:leader, 7, 1)"/>

    <!-- ================= Work ================= -->
    <bf:Work rdf:about="{$wuri}">
      <xsl:variable name="wclass">
        <xsl:choose>
          <xsl:when test="$l6='a' or $l6='t'">Text</xsl:when>
          <xsl:when test="$l6='c' or $l6='d'">NotatedMusic</xsl:when>
          <xsl:when test="$l6='e' or $l6='f'">Cartography</xsl:when>
          <xsl:when test="$l6='g'">MovingImage</xsl:when>
          <xsl:when test="$l6='i' or $l6='j'">Audio</xsl:when>
          <xsl:when test="$l6='k'">StillImage</xsl:when>
          <xsl:when test="$l6='m'">Multimedia</xsl:when>
          <xsl:when test="$l6='r'">Object</xsl:when>
          <xsl:when test="$l6='o' or $l6='p'">MixedMaterial</xsl:when>
        </xsl:choose>
      </xsl:variable>
      <xsl:if test="$wclass != ''">
        <rdf:type rdf:resource="http://id.loc.gov/ontologies/bibframe/{$wclass}"/>
      </xsl:if>

      <!-- 001 kept as admin metadata so the reverse crosswalk can restore it -->
      <xsl:if test="$cn != ''">
        <bf:adminMetadata>
          <bf:AdminMetadata>
            <bf:identifiedBy>
              <bf:Local><rdf:value><xsl:value-of select="$cn"/></rdf:value></bf:Local>
            </bf:identifiedBy>
          </bf:AdminMetadata>
        </bf:adminMetadata>
      </xsl:if>

      <xsl:call-template name="bx-title"/>

      <!-- contribution: 1XX primary, 7XX plain -->
      <xsl:for-each select="marc:datafield[@tag='100' or @tag='110' or @tag='111'
                            or @tag='700' or @tag='710' or @tag='711']">
        <bf:contribution>
          <bf:Contribution>
            <xsl:if test="starts-with(@tag, '1')">
              <rdf:type rdf:resource="http://id.loc.gov/ontologies/bflc/PrimaryContribution"/>
            </xsl:if>
            <bf:agent>
              <xsl:variable name="aclass">
                <xsl:choose>
                  <xsl:when test="substring(@tag,2)='00'">Person</xsl:when>
                  <xsl:when test="substring(@tag,2)='10'">Organization</xsl:when>
                  <xsl:otherwise>Meeting</xsl:otherwise>
                </xsl:choose>
              </xsl:variable>
              <xsl:element name="bf:{$aclass}">
                <rdfs:label>
                  <xsl:call-template name="bx-chomp">
                    <xsl:with-param name="s">
                      <xsl:for-each select="marc:subfield[contains('abcdq', @code)]">
                        <xsl:value-of select="."/><xsl:text> </xsl:text>
                      </xsl:for-each>
                    </xsl:with-param>
                  </xsl:call-template>
                </rdfs:label>
              </xsl:element>
            </bf:agent>
            <xsl:for-each select="marc:subfield[@code='4']">
              <bf:role rdf:resource="http://id.loc.gov/vocabulary/relators/{normalize-space(.)}"/>
            </xsl:for-each>
            <xsl:if test="not(marc:subfield[@code='4'])">
              <xsl:for-each select="marc:subfield[@code='e']">
                <bf:role>
                  <bf:Role>
                    <rdfs:label>
                      <xsl:call-template name="bx-chomp-dot">
                        <xsl:with-param name="s" select="."/>
                      </xsl:call-template>
                    </rdfs:label>
                  </bf:Role>
                </bf:role>
              </xsl:for-each>
            </xsl:if>
          </bf:Contribution>
        </bf:contribution>
      </xsl:for-each>

      <!-- subjects -->
      <xsl:for-each select="marc:datafield[@tag='600' or @tag='610' or @tag='611'
                            or @tag='630' or @tag='648' or @tag='650' or @tag='651'
                            or @tag='653']">
        <bf:subject>
          <xsl:variable name="sclass">
            <xsl:choose>
              <xsl:when test="@tag='651'">Place</xsl:when>
              <xsl:when test="@tag='648'">Temporal</xsl:when>
              <xsl:otherwise>Topic</xsl:otherwise>
            </xsl:choose>
          </xsl:variable>
          <xsl:element name="bf:{$sclass}">
            <xsl:if test="starts-with(normalize-space(marc:subfield[@code='0'][1]), 'http')">
              <xsl:attribute name="rdf:about">
                <xsl:value-of select="normalize-space(marc:subfield[@code='0'][1])"/>
              </xsl:attribute>
            </xsl:if>
            <rdfs:label>
              <xsl:for-each select="marc:subfield[contains('abcdqtvxyz', @code)]">
                <xsl:if test="position() &gt; 1">--</xsl:if>
                <xsl:call-template name="bx-chomp-dot">
                  <xsl:with-param name="s" select="."/>
                </xsl:call-template>
              </xsl:for-each>
            </rdfs:label>
          </xsl:element>
        </bf:subject>
      </xsl:for-each>

      <!-- language from 008/35-37 -->
      <xsl:variable name="lang" select="substring($cf008, 36, 3)"/>
      <xsl:if test="string-length($lang) = 3 and
                    translate($lang, 'abcdefghijklmnopqrstuvwxyz', '') = ''">
        <bf:language rdf:resource="http://id.loc.gov/vocabulary/languages/{$lang}"/>
      </xsl:if>

      <!-- classification -->
      <xsl:for-each select="marc:datafield[@tag='050'][marc:subfield[@code='a']]">
        <bf:classification>
          <bf:ClassificationLcc>
            <bf:classificationPortion>
              <xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/>
            </bf:classificationPortion>
            <xsl:if test="marc:subfield[@code='b']">
              <bf:itemPortion>
                <xsl:value-of select="normalize-space(marc:subfield[@code='b'][1])"/>
              </bf:itemPortion>
            </xsl:if>
          </bf:ClassificationLcc>
        </bf:classification>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='082'][marc:subfield[@code='a']]">
        <bf:classification>
          <bf:ClassificationDdc>
            <bf:classificationPortion>
              <xsl:value-of select="normalize-space(marc:subfield[@code='a'][1])"/>
            </bf:classificationPortion>
          </bf:ClassificationDdc>
        </bf:classification>
      </xsl:for-each>

      <!-- content type (Work side of 336-338) -->
      <xsl:for-each select="marc:datafield[@tag='336']/marc:subfield[@code='b']">
        <bf:content rdf:resource="http://id.loc.gov/vocabulary/contentTypes/{normalize-space(.)}"/>
      </xsl:for-each>

      <bf:hasInstance rdf:resource="{$iuri}"/>
    </bf:Work>

    <!-- ================= Instance ================= -->
    <bf:Instance rdf:about="{$iuri}">
      <bf:instanceOf rdf:resource="{$wuri}"/>

      <xsl:call-template name="bx-title"/>
      <xsl:if test="marc:datafield[@tag='245']/marc:subfield[@code='c']">
        <bf:responsibilityStatement>
          <xsl:call-template name="bx-chomp">
            <xsl:with-param name="s"
                select="marc:datafield[@tag='245'][1]/marc:subfield[@code='c'][1]"/>
          </xsl:call-template>
        </bf:responsibilityStatement>
      </xsl:if>

      <!-- provisionActivity: RDA 264 _1 preferred, then 260, then any 264 -->
      <xsl:variable name="p264" select="marc:datafield[@tag='264'][@ind2='1'][1]"/>
      <xsl:variable name="pub"
          select="($p264
                   | marc:datafield[@tag='260'][1][not($p264)]
                   | marc:datafield[@tag='264'][1]
                     [not($p264) and not(../marc:datafield[@tag='260'])])[1]"/>
      <xsl:if test="$pub">
        <bf:provisionActivity>
          <bf:Publication>
            <xsl:if test="$pub/marc:subfield[@code='a']">
              <bf:place>
                <bf:Place>
                  <rdfs:label>
                    <xsl:call-template name="bx-chomp">
                      <xsl:with-param name="s" select="$pub/marc:subfield[@code='a'][1]"/>
                    </xsl:call-template>
                  </rdfs:label>
                </bf:Place>
              </bf:place>
            </xsl:if>
            <xsl:if test="$pub/marc:subfield[@code='b']">
              <bf:agent>
                <bf:Agent>
                  <rdfs:label>
                    <xsl:call-template name="bx-chomp">
                      <xsl:with-param name="s" select="$pub/marc:subfield[@code='b'][1]"/>
                    </xsl:call-template>
                  </rdfs:label>
                </bf:Agent>
              </bf:agent>
            </xsl:if>
            <xsl:if test="$pub/marc:subfield[@code='c']">
              <bf:date>
                <xsl:call-template name="bx-chomp-dot">
                  <xsl:with-param name="s"
                      select="translate($pub/marc:subfield[@code='c'][1], '[]', '')"/>
                </xsl:call-template>
              </bf:date>
            </xsl:if>
          </bf:Publication>
        </bf:provisionActivity>
      </xsl:if>

      <!-- identifiers -->
      <xsl:for-each select="marc:datafield[@tag='020']/marc:subfield[@code='a']">
        <bf:identifiedBy>
          <bf:Isbn><rdf:value><xsl:value-of select="normalize-space(.)"/></rdf:value></bf:Isbn>
        </bf:identifiedBy>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='022']/marc:subfield[@code='a']">
        <bf:identifiedBy>
          <bf:Issn><rdf:value><xsl:value-of select="normalize-space(.)"/></rdf:value></bf:Issn>
        </bf:identifiedBy>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='010']/marc:subfield[@code='a']">
        <bf:identifiedBy>
          <bf:Lccn><rdf:value><xsl:value-of select="normalize-space(.)"/></rdf:value></bf:Lccn>
        </bf:identifiedBy>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='035']/marc:subfield[@code='a']
                            [starts-with(normalize-space(.), '(OCoLC)')]">
        <bf:identifiedBy>
          <bf:OclcNumber>
            <rdf:value>
              <xsl:value-of select="substring-after(normalize-space(.), '(OCoLC)')"/>
            </rdf:value>
          </bf:OclcNumber>
        </bf:identifiedBy>
      </xsl:for-each>

      <!-- extent -->
      <xsl:for-each select="marc:datafield[@tag='300']/marc:subfield[@code='a'][1]">
        <bf:extent>
          <bf:Extent>
            <rdfs:label>
              <xsl:call-template name="bx-chomp"><xsl:with-param name="s" select="."/></xsl:call-template>
            </rdfs:label>
          </bf:Extent>
        </bf:extent>
      </xsl:for-each>

      <!-- media / carrier (Instance side of 336-338) -->
      <xsl:for-each select="marc:datafield[@tag='337']/marc:subfield[@code='b']">
        <bf:media rdf:resource="http://id.loc.gov/vocabulary/mediaTypes/{normalize-space(.)}"/>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='338']/marc:subfield[@code='b']">
        <bf:carrier rdf:resource="http://id.loc.gov/vocabulary/carriers/{normalize-space(.)}"/>
      </xsl:for-each>

      <!-- online access -->
      <xsl:for-each select="marc:datafield[@tag='856']/marc:subfield[@code='u']">
        <bf:electronicLocator rdf:resource="{normalize-space(.)}"/>
      </xsl:for-each>

      <xsl:if test="marc:datafield[@tag='852']">
        <bf:hasItem rdf:resource="{concat($baseuri, $recid, '#Item')}"/>
      </xsl:if>
    </bf:Instance>

    <!-- ================= Item (852 only) ================= -->
    <xsl:for-each select="marc:datafield[@tag='852'][1]">
      <bf:Item rdf:about="{concat($baseuri, $recid, '#Item')}">
        <bf:itemOf rdf:resource="{$iuri}"/>
        <xsl:if test="marc:subfield[@code='a' or @code='b']">
          <bf:heldBy>
            <bf:Agent>
              <rdfs:label>
                <xsl:call-template name="bx-chomp">
                  <xsl:with-param name="s">
                    <xsl:for-each select="marc:subfield[@code='a' or @code='b']">
                      <xsl:value-of select="."/><xsl:text> </xsl:text>
                    </xsl:for-each>
                  </xsl:with-param>
                </xsl:call-template>
              </rdfs:label>
            </bf:Agent>
          </bf:heldBy>
        </xsl:if>
        <xsl:if test="marc:subfield[@code='h' or @code='i' or @code='j' or @code='k']">
          <bf:shelfMark>
            <bf:ShelfMark>
              <rdfs:label>
                <xsl:call-template name="bx-chomp">
                  <xsl:with-param name="s">
                    <xsl:for-each
                        select="marc:subfield[@code='h' or @code='i' or @code='j' or @code='k']">
                      <xsl:value-of select="."/><xsl:text> </xsl:text>
                    </xsl:for-each>
                  </xsl:with-param>
                </xsl:call-template>
              </rdfs:label>
            </bf:ShelfMark>
          </bf:shelfMark>
        </xsl:if>
      </bf:Item>
    </xsl:for-each>
  </xsl:template>

  <!-- 245 -> bf:title (shared by Work and Instance) -->
  <xsl:template name="bx-title">
    <xsl:for-each select="marc:datafield[@tag='245'][1]">
      <bf:title>
        <bf:Title>
          <xsl:if test="marc:subfield[@code='a']">
            <bf:mainTitle>
              <xsl:call-template name="bx-chomp">
                <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
              </xsl:call-template>
            </bf:mainTitle>
          </xsl:if>
          <xsl:if test="marc:subfield[@code='b']">
            <bf:subtitle>
              <xsl:call-template name="bx-chomp">
                <xsl:with-param name="s" select="marc:subfield[@code='b'][1]"/>
              </xsl:call-template>
            </bf:subtitle>
          </xsl:if>
        </bf:Title>
      </bf:title>
    </xsl:for-each>
  </xsl:template>

  <!-- strip trailing ISBD separators: / : ; , and whitespace -->
  <xsl:template name="bx-chomp">
    <xsl:param name="s"/>
    <xsl:variable name="t" select="normalize-space($s)"/>
    <xsl:variable name="last" select="substring($t, string-length($t))"/>
    <xsl:choose>
      <xsl:when test="$t = ''"/>
      <xsl:when test="$last='/' or $last=':' or $last=';' or $last=','">
        <xsl:call-template name="bx-chomp">
          <xsl:with-param name="s" select="substring($t, 1, string-length($t) - 1)"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$t"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- bx-chomp that also drops a trailing period (dates, role terms, headings) -->
  <xsl:template name="bx-chomp-dot">
    <xsl:param name="s"/>
    <xsl:variable name="t" select="normalize-space($s)"/>
    <xsl:variable name="last" select="substring($t, string-length($t))"/>
    <xsl:choose>
      <xsl:when test="$t = ''"/>
      <xsl:when test="$last='/' or $last=':' or $last=';' or $last=',' or $last='.'">
        <xsl:call-template name="bx-chomp-dot">
          <xsl:with-param name="s" select="substring($t, 1, string-length($t) - 1)"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$t"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
