<?xml version="1.0" encoding="UTF-8"?>
<!--
  bibframe2-to-marcxml.xsl - BIBFRAME 2.x RDF/XML back to MARCXML (slim).

  Original, compact crosswalk for the duckdb-marc21 project. The mapping
  semantics follow the public-domain Library of Congress sources (the
  BIBFRAME 2 ontology and the documented conversion logic of LC's
  bibframe2marc project); the implementation is written from scratch.

  Subset contract: this stylesheet inverts exactly the output shape of
  the companion marcxml-to-bibframe2.xsl - sibling bf:Work / bf:Instance
  / bf:Item resources, the Instance found through bf:hasInstance (or
  bf:instanceOf as a fallback). It is NOT a general BIBFRAME reader:
  descriptions produced by other converters map only as far as they use
  the same property shapes. Reconstructed fields:

    leader      00000n{06}{07} a2200000 a 4500 - Leader/06 from the Work
                subclass (Text->a, NotatedMusic->c, Cartography->e,
                MovingImage->g, Audio->j, StillImage->k, Multimedia->m,
                Object->r, MixedMaterial->p, default a); Leader/07 s when
                the Instance carries a bf:Issn, else m.
    001         bf:adminMetadata bf:Local rdf:value
    008         type s; date from the bf:Publication bf:date when it is a
                four-digit year; language from the bf:language URI
    010/020/022/035  bf:Lccn / bf:Isbn / bf:Issn / bf:OclcNumber
                rdf:value; the OCLC number regains its (OCoLC) prefix
    050/082     bf:ClassificationLcc (a/b), bf:ClassificationDdc (a)
    1XX/7XX     bf:contribution: 100/110/111 when typed
                bflc:PrimaryContribution, else 700/710/711; the tag from
                the agent class (Person/Organization/Meeting), $a from
                the agent label, $4 from a relators bf:role URI, $e from
                a bf:Role label
    245         Instance bf:title mainTitle/subtitle -> $a/$b (ISBD colon
                restored when a subtitle exists), $c from
                bf:responsibilityStatement
    264 _1      bf:Publication place/agent/date -> $a :/$b,/$c
    300         bf:extent label -> $a
    336/337/338 bf:content / bf:media / bf:carrier URIs -> $b code with
                the matching $2 rda source
    6XX         bf:subject: Topic->650, Place->651, Temporal->648; the
                label splits on double hyphen into $a plus repeated $x;
                an rdf:about becomes $0 (ind2 0 for id.loc.gov, else 4)
    852         bf:Item heldBy -> $a, shelfMark -> $h
    856 40      bf:electronicLocator -> $u

  Everything else in the input is ignored. Punctuation stripped by the
  forward pass is re-added only where noted, so a forward-reverse round
  trip is stable but not byte-identical. XSLT 1.0.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    xmlns:rdfs="http://www.w3.org/2000/01/rdf-schema#"
    xmlns:bf="http://id.loc.gov/ontologies/bibframe/"
    xmlns:bflc="http://id.loc.gov/ontologies/bflc/"
    xmlns="http://www.loc.gov/MARC21/slim"
    exclude-result-prefixes="rdf rdfs bf bflc">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:key name="bx-instance" match="bf:Instance" use="@rdf:about"/>
  <xsl:key name="bx-item" match="bf:Item" use="@rdf:about"/>

  <xsl:template match="/">
    <collection>
      <xsl:apply-templates select="//bf:Work"/>
    </collection>
  </xsl:template>

  <xsl:template match="bf:Work">
    <xsl:variable name="inst"
        select="(key('bx-instance', bf:hasInstance/@rdf:resource)
                 | //bf:Instance[bf:instanceOf/@rdf:resource = current()/@rdf:about])[1]"/>
    <xsl:variable name="item" select="key('bx-item', $inst/bf:hasItem/@rdf:resource)[1]"/>

    <record>
      <!-- leader -->
      <xsl:variable name="wt" select="string(rdf:type/@rdf:resource)"/>
      <xsl:variable name="t6">
        <xsl:choose>
          <xsl:when test="contains($wt, 'NotatedMusic')">c</xsl:when>
          <xsl:when test="contains($wt, 'Cartography')">e</xsl:when>
          <xsl:when test="contains($wt, 'MovingImage')">g</xsl:when>
          <xsl:when test="contains($wt, 'Audio')">j</xsl:when>
          <xsl:when test="contains($wt, 'StillImage')">k</xsl:when>
          <xsl:when test="contains($wt, 'Multimedia')">m</xsl:when>
          <xsl:when test="contains($wt, 'Object')">r</xsl:when>
          <xsl:when test="contains($wt, 'MixedMaterial')">p</xsl:when>
          <xsl:otherwise>a</xsl:otherwise>
        </xsl:choose>
      </xsl:variable>
      <xsl:variable name="t7">
        <xsl:choose>
          <xsl:when test="$inst/bf:identifiedBy/bf:Issn">s</xsl:when>
          <xsl:otherwise>m</xsl:otherwise>
        </xsl:choose>
      </xsl:variable>
      <leader><xsl:value-of select="concat('00000n', $t6, $t7, ' a2200000 a 4500')"/></leader>

      <!-- 001 from admin metadata -->
      <xsl:variable name="cn"
          select="normalize-space(bf:adminMetadata/bf:AdminMetadata
                  /bf:identifiedBy/bf:Local/rdf:value)"/>
      <xsl:if test="$cn != ''">
        <controlfield tag="001"><xsl:value-of select="$cn"/></controlfield>
      </xsl:if>

      <!-- 008: date type s, year, place xx, language, source d -->
      <xsl:variable name="pdate"
          select="normalize-space($inst/bf:provisionActivity/bf:Publication/bf:date)"/>
      <xsl:variable name="y4">
        <xsl:choose>
          <xsl:when test="string-length($pdate) = 4
                          and translate($pdate, '0123456789', '') = ''">
            <xsl:value-of select="$pdate"/>
          </xsl:when>
          <xsl:otherwise><xsl:text>    </xsl:text></xsl:otherwise>
        </xsl:choose>
      </xsl:variable>
      <xsl:variable name="l3">
        <xsl:choose>
          <xsl:when test="contains(bf:language/@rdf:resource, '/languages/')">
            <xsl:value-of
                select="substring(substring-after(bf:language/@rdf:resource, '/languages/'), 1, 3)"/>
          </xsl:when>
          <xsl:otherwise><xsl:text>   </xsl:text></xsl:otherwise>
        </xsl:choose>
      </xsl:variable>
      <controlfield tag="008">
        <xsl:value-of select="concat('000000s', $y4, '    xx ',
                                     '                 ', $l3, ' d')"/>
      </controlfield>

      <!-- identifiers -->
      <xsl:for-each select="$inst/bf:identifiedBy/bf:Lccn/rdf:value">
        <datafield tag="010" ind1=" " ind2=" ">
          <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
        </datafield>
      </xsl:for-each>
      <xsl:for-each select="$inst/bf:identifiedBy/bf:Isbn/rdf:value">
        <datafield tag="020" ind1=" " ind2=" ">
          <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
        </datafield>
      </xsl:for-each>
      <xsl:for-each select="$inst/bf:identifiedBy/bf:Issn/rdf:value">
        <datafield tag="022" ind1=" " ind2=" ">
          <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
        </datafield>
      </xsl:for-each>
      <xsl:for-each select="$inst/bf:identifiedBy/bf:OclcNumber/rdf:value">
        <datafield tag="035" ind1=" " ind2=" ">
          <subfield code="a"><xsl:value-of select="concat('(OCoLC)', normalize-space(.))"/></subfield>
        </datafield>
      </xsl:for-each>

      <!-- classification -->
      <xsl:for-each select="bf:classification/bf:ClassificationLcc">
        <datafield tag="050" ind1=" " ind2="0">
          <subfield code="a"><xsl:value-of select="normalize-space(bf:classificationPortion)"/></subfield>
          <xsl:if test="bf:itemPortion">
            <subfield code="b"><xsl:value-of select="normalize-space(bf:itemPortion)"/></subfield>
          </xsl:if>
        </datafield>
      </xsl:for-each>
      <xsl:for-each select="bf:classification/bf:ClassificationDdc">
        <datafield tag="082" ind1="0" ind2="4">
          <subfield code="a"><xsl:value-of select="normalize-space(bf:classificationPortion)"/></subfield>
        </datafield>
      </xsl:for-each>

      <!-- 1XX: the primary contribution -->
      <xsl:for-each select="bf:contribution/bf:Contribution
                            [rdf:type[contains(@rdf:resource, 'PrimaryContribution')]][1]">
        <xsl:call-template name="bx-heading">
          <xsl:with-param name="base" select="1"/>
        </xsl:call-template>
      </xsl:for-each>

      <!-- 245 from the Instance (falling back to the Work title) -->
      <xsl:variable name="title" select="($inst/bf:title/bf:Title | bf:title/bf:Title)[1]"/>
      <xsl:if test="$title">
        <datafield tag="245">
          <xsl:attribute name="ind1">
            <xsl:choose>
              <xsl:when test="bf:contribution/bf:Contribution
                              [rdf:type[contains(@rdf:resource, 'PrimaryContribution')]]">1</xsl:when>
              <xsl:otherwise>0</xsl:otherwise>
            </xsl:choose>
          </xsl:attribute>
          <xsl:attribute name="ind2">0</xsl:attribute>
          <subfield code="a">
            <xsl:value-of select="normalize-space($title/bf:mainTitle)"/>
            <xsl:if test="$title/bf:subtitle"><xsl:text> :</xsl:text></xsl:if>
          </subfield>
          <xsl:if test="$title/bf:subtitle">
            <subfield code="b"><xsl:value-of select="normalize-space($title/bf:subtitle)"/></subfield>
          </xsl:if>
          <xsl:if test="$inst/bf:responsibilityStatement">
            <subfield code="c">
              <xsl:value-of select="normalize-space($inst/bf:responsibilityStatement)"/>
            </subfield>
          </xsl:if>
        </datafield>
      </xsl:if>

      <!-- 264 _1 from the publication activity -->
      <xsl:for-each select="$inst/bf:provisionActivity/bf:Publication[1]">
        <datafield tag="264" ind1=" " ind2="1">
          <xsl:if test="bf:place/bf:Place/rdfs:label">
            <subfield code="a">
              <xsl:value-of select="normalize-space(bf:place/bf:Place/rdfs:label)"/>
              <xsl:text> :</xsl:text>
            </subfield>
          </xsl:if>
          <xsl:if test="bf:agent/bf:Agent/rdfs:label">
            <subfield code="b">
              <xsl:value-of select="normalize-space(bf:agent/bf:Agent/rdfs:label)"/>
              <xsl:text>,</xsl:text>
            </subfield>
          </xsl:if>
          <xsl:if test="bf:date">
            <subfield code="c"><xsl:value-of select="normalize-space(bf:date)"/></subfield>
          </xsl:if>
        </datafield>
      </xsl:for-each>

      <!-- 300 -->
      <xsl:for-each select="$inst/bf:extent/bf:Extent/rdfs:label">
        <datafield tag="300" ind1=" " ind2=" ">
          <subfield code="a"><xsl:value-of select="normalize-space(.)"/></subfield>
        </datafield>
      </xsl:for-each>

      <!-- 336 / 337 / 338 from the vocabulary URIs -->
      <xsl:for-each select="bf:content[contains(@rdf:resource, '/contentTypes/')]">
        <datafield tag="336" ind1=" " ind2=" ">
          <subfield code="b">
            <xsl:value-of select="substring-after(@rdf:resource, '/contentTypes/')"/>
          </subfield>
          <subfield code="2">rdacontent</subfield>
        </datafield>
      </xsl:for-each>
      <xsl:for-each select="$inst/bf:media[contains(@rdf:resource, '/mediaTypes/')]">
        <datafield tag="337" ind1=" " ind2=" ">
          <subfield code="b">
            <xsl:value-of select="substring-after(@rdf:resource, '/mediaTypes/')"/>
          </subfield>
          <subfield code="2">rdamedia</subfield>
        </datafield>
      </xsl:for-each>
      <xsl:for-each select="$inst/bf:carrier[contains(@rdf:resource, '/carriers/')]">
        <datafield tag="338" ind1=" " ind2=" ">
          <subfield code="b">
            <xsl:value-of select="substring-after(@rdf:resource, '/carriers/')"/>
          </subfield>
          <subfield code="2">rdacarrier</subfield>
        </datafield>
      </xsl:for-each>

      <!-- subjects -->
      <xsl:for-each select="bf:subject/*[self::bf:Topic or self::bf:Place or self::bf:Temporal]">
        <xsl:variable name="tag">
          <xsl:choose>
            <xsl:when test="self::bf:Place">651</xsl:when>
            <xsl:when test="self::bf:Temporal">648</xsl:when>
            <xsl:otherwise>650</xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <datafield tag="{$tag}" ind1=" ">
          <xsl:attribute name="ind2">
            <xsl:choose>
              <xsl:when test="not(@rdf:about) or contains(@rdf:about, 'id.loc.gov')">0</xsl:when>
              <xsl:otherwise>4</xsl:otherwise>
            </xsl:choose>
          </xsl:attribute>
          <xsl:variable name="lbl" select="normalize-space(rdfs:label)"/>
          <xsl:choose>
            <xsl:when test="contains($lbl, '--')">
              <subfield code="a"><xsl:value-of select="substring-before($lbl, '--')"/></subfield>
              <xsl:call-template name="bx-xsubs">
                <xsl:with-param name="s" select="substring-after($lbl, '--')"/>
              </xsl:call-template>
            </xsl:when>
            <xsl:otherwise>
              <subfield code="a"><xsl:value-of select="$lbl"/></subfield>
            </xsl:otherwise>
          </xsl:choose>
          <xsl:if test="@rdf:about">
            <subfield code="0"><xsl:value-of select="@rdf:about"/></subfield>
          </xsl:if>
        </datafield>
      </xsl:for-each>

      <!-- 7XX: the non-primary contributions -->
      <xsl:for-each select="bf:contribution/bf:Contribution
                            [not(rdf:type[contains(@rdf:resource, 'PrimaryContribution')])]">
        <xsl:call-template name="bx-heading">
          <xsl:with-param name="base" select="7"/>
        </xsl:call-template>
      </xsl:for-each>

      <!-- 852 from the Item -->
      <xsl:if test="$item">
        <datafield tag="852" ind1=" " ind2=" ">
          <xsl:if test="$item/bf:heldBy/bf:Agent/rdfs:label">
            <subfield code="a">
              <xsl:value-of select="normalize-space($item/bf:heldBy/bf:Agent/rdfs:label)"/>
            </subfield>
          </xsl:if>
          <xsl:if test="$item/bf:shelfMark/bf:ShelfMark/rdfs:label">
            <subfield code="h">
              <xsl:value-of select="normalize-space($item/bf:shelfMark/bf:ShelfMark/rdfs:label)"/>
            </subfield>
          </xsl:if>
        </datafield>
      </xsl:if>

      <!-- 856 -->
      <xsl:for-each select="$inst/bf:electronicLocator[@rdf:resource]">
        <datafield tag="856" ind1="4" ind2="0">
          <subfield code="u"><xsl:value-of select="@rdf:resource"/></subfield>
        </datafield>
      </xsl:for-each>
    </record>
  </xsl:template>

  <!-- one contribution back to a 1XX or 7XX heading -->
  <xsl:template name="bx-heading">
    <xsl:param name="base"/>
    <xsl:variable name="agent"
        select="bf:agent/*[self::bf:Person or self::bf:Organization
                           or self::bf:Meeting or self::bf:Agent][1]"/>
    <xsl:variable name="tag">
      <xsl:choose>
        <xsl:when test="$agent/self::bf:Organization"><xsl:value-of select="$base"/>10</xsl:when>
        <xsl:when test="$agent/self::bf:Meeting"><xsl:value-of select="$base"/>11</xsl:when>
        <xsl:otherwise><xsl:value-of select="$base"/>00</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="ind1">
      <xsl:choose>
        <xsl:when test="$agent/self::bf:Organization or $agent/self::bf:Meeting">2</xsl:when>
        <xsl:otherwise>1</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <datafield tag="{$tag}" ind1="{$ind1}" ind2=" ">
      <subfield code="a"><xsl:value-of select="normalize-space($agent/rdfs:label)"/></subfield>
      <xsl:for-each select="bf:role/bf:Role/rdfs:label">
        <subfield code="e"><xsl:value-of select="normalize-space(.)"/></subfield>
      </xsl:for-each>
      <xsl:for-each select="bf:role[contains(@rdf:resource, '/relators/')]">
        <subfield code="4">
          <xsl:value-of select="substring-after(@rdf:resource, '/relators/')"/>
        </subfield>
      </xsl:for-each>
    </datafield>
  </xsl:template>

  <!-- repeated $x for the double-hyphen-joined remainder of a subject label -->
  <xsl:template name="bx-xsubs">
    <xsl:param name="s"/>
    <xsl:if test="string-length($s) &gt; 0">
      <xsl:choose>
        <xsl:when test="contains($s, '--')">
          <subfield code="x"><xsl:value-of select="substring-before($s, '--')"/></subfield>
          <xsl:call-template name="bx-xsubs">
            <xsl:with-param name="s" select="substring-after($s, '--')"/>
          </xsl:call-template>
        </xsl:when>
        <xsl:otherwise>
          <subfield code="x"><xsl:value-of select="$s"/></subfield>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:if>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
