<?xml version="1.0" encoding="UTF-8"?>
<!--
  marcxml-to-ead.xsl - MARCXML (slim) to a collection-level EAD3
  finding-aid skeleton.

  Original crosswalk for the duckdb-marc21 project, written from:
    * the EAD3 schema and tag library published by the Library of
      Congress and the Society of American Archivists (namespace
      http://ead3.archivists.org/schema/): control (recordid, filedesc,
      maintenancestatus, maintenanceagency, maintenancehistory),
      archdesc/did (unittitle, unitdate, unitid, origination, physdesc,
      langmaterial), scopecontent, controlaccess;
    * the MARC 21 bibliographic format documentation for the source
      fields (001/003/008, 1XX, 245, 260/264, 300, 520, 545, 6XX).

  Scope: this produces a SKELETON - one <ead> with a collection-level
  <archdesc> per MARC record, meant as a starting point for archival
  description, not a complete finding aid (no <dsc>, no components).
  A marc:collection input yields several <ead> documents inside a
  neutral no-namespace <eadRecords> wrapper (EAD3 itself has no
  multi-ead container); a bare marc:record yields one bare <ead>.

  XSLT 1.0, xsltproc-friendly.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    xmlns="http://ead3.archivists.org/schema/"
    exclude-result-prefixes="marc">

  <xsl:include href="marc-utils.xsl"/>

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:template match="/marc:collection">
    <eadRecords xmlns="">
      <xsl:apply-templates select="marc:record"/>
    </eadRecords>
  </xsl:template>

  <xsl:template match="/marc:record | marc:record">
    <xsl:variable name="title">
      <xsl:for-each select="marc:datafield[@tag='245'][1]">
        <xsl:call-template name="mu-chomp">
          <xsl:with-param name="s">
            <xsl:call-template name="mu-field-text">
              <xsl:with-param name="want" select="'abnp'"/>
            </xsl:call-template>
          </xsl:with-param>
        </xsl:call-template>
      </xsl:for-each>
    </xsl:variable>

    <ead>
      <!-- ============================================================
           control: identity and provenance of this EAD instance,
           from 001/003/008 of the source record
           ============================================================ -->
      <control>
        <recordid>
          <xsl:choose>
            <xsl:when test="normalize-space(marc:controlfield[@tag='001']) != ''">
              <xsl:if test="normalize-space(marc:controlfield[@tag='003']) != ''">
                <xsl:value-of select="normalize-space(marc:controlfield[@tag='003'])"/>
                <xsl:text>-</xsl:text>
              </xsl:if>
              <xsl:value-of select="normalize-space(marc:controlfield[@tag='001'])"/>
            </xsl:when>
            <xsl:otherwise>
              <xsl:text>marc-derived-</xsl:text>
              <xsl:value-of select="position()"/>
            </xsl:otherwise>
          </xsl:choose>
        </recordid>
        <filedesc>
          <titlestmt>
            <titleproper>
              <xsl:choose>
                <xsl:when test="string($title) != ''">
                  <xsl:value-of select="$title"/>
                </xsl:when>
                <xsl:otherwise>Untitled collection</xsl:otherwise>
              </xsl:choose>
            </titleproper>
          </titlestmt>
        </filedesc>
        <maintenancestatus value="derived"/>
        <maintenanceagency>
          <agencyname>
            <xsl:choose>
              <xsl:when test="normalize-space(marc:controlfield[@tag='003']) != ''">
                <xsl:value-of select="normalize-space(marc:controlfield[@tag='003'])"/>
              </xsl:when>
              <xsl:otherwise>unassigned</xsl:otherwise>
            </xsl:choose>
          </agencyname>
        </maintenanceagency>
        <!-- language of the material's cataloguing, 008/35-37 -->
        <xsl:variable name="lg8">
          <xsl:call-template name="mu-cf-slice">
            <xsl:with-param name="pos" select="35"/>
            <xsl:with-param name="len" select="3"/>
          </xsl:call-template>
        </xsl:variable>
        <xsl:if test="translate($lg8, ' |', '') != ''">
          <languagedeclaration>
            <language langcode="{$lg8}"><xsl:value-of select="$lg8"/></language>
            <script scriptcode="Zyyy"/>
          </languagedeclaration>
        </xsl:if>
        <maintenancehistory>
          <maintenanceevent>
            <eventtype value="derived"/>
            <eventdatetime>
              <!-- date entered on file, 008/00-05 (YYMMDD) -->
              <xsl:variable name="d0">
                <xsl:call-template name="mu-cf-slice">
                  <xsl:with-param name="pos" select="0"/>
                  <xsl:with-param name="len" select="6"/>
                </xsl:call-template>
              </xsl:variable>
              <xsl:choose>
                <xsl:when test="translate($d0, '0123456789', '') = ''
                                and string-length($d0) = 6">
                  <xsl:value-of select="$d0"/>
                </xsl:when>
                <xsl:otherwise>unknown</xsl:otherwise>
              </xsl:choose>
            </eventdatetime>
            <agenttype value="machine"/>
            <agent>duckdb-marc21 marcxml-to-ead crosswalk</agent>
            <eventdescription>Derived from a MARC 21 bibliographic record.</eventdescription>
          </maintenanceevent>
        </maintenancehistory>
      </control>

      <!-- ============================================================
           archdesc: collection-level description
           ============================================================ -->
      <archdesc level="collection">
        <did>
          <xsl:if test="normalize-space(marc:controlfield[@tag='001']) != ''">
            <unitid>
              <xsl:value-of select="normalize-space(marc:controlfield[@tag='001'])"/>
            </unitid>
          </xsl:if>

          <unittitle>
            <xsl:choose>
              <xsl:when test="string($title) != ''">
                <xsl:value-of select="$title"/>
              </xsl:when>
              <xsl:otherwise>Untitled collection</xsl:otherwise>
            </xsl:choose>
          </unittitle>

          <!-- unitdate from the imprint date (260/264 $c) -->
          <xsl:for-each select="(marc:datafield[@tag='260' or @tag='264']
                                 /marc:subfield[@code='c'])[1]">
            <xsl:variable name="dtext">
              <xsl:call-template name="mu-unbracket">
                <xsl:with-param name="s">
                  <xsl:call-template name="mu-chomp">
                    <xsl:with-param name="s" select="."/>
                  </xsl:call-template>
                </xsl:with-param>
              </xsl:call-template>
            </xsl:variable>
            <unitdate>
              <xsl:variable name="y">
                <xsl:call-template name="mu-first-year">
                  <xsl:with-param name="s" select="$dtext"/>
                </xsl:call-template>
              </xsl:variable>
              <xsl:if test="string-length($y) = 4">
                <xsl:attribute name="normal"><xsl:value-of select="$y"/></xsl:attribute>
              </xsl:if>
              <xsl:value-of select="$dtext"/>
            </unitdate>
          </xsl:for-each>

          <!-- origination from the 1XX main entry -->
          <xsl:for-each select="marc:datafield[@tag='100' or @tag='110' or @tag='111'][1]">
            <origination label="creator">
              <xsl:variable name="agent">
                <xsl:call-template name="mu-chomp">
                  <xsl:with-param name="s">
                    <xsl:call-template name="mu-field-text">
                      <xsl:with-param name="want" select="'abcdq'"/>
                    </xsl:call-template>
                  </xsl:with-param>
                </xsl:call-template>
              </xsl:variable>
              <xsl:choose>
                <xsl:when test="@tag='100'">
                  <persname><part><xsl:value-of select="$agent"/></part></persname>
                </xsl:when>
                <xsl:when test="@tag='110'">
                  <corpname><part><xsl:value-of select="$agent"/></part></corpname>
                </xsl:when>
                <xsl:otherwise>
                  <corpname><part><xsl:value-of select="$agent"/></part></corpname>
                </xsl:otherwise>
              </xsl:choose>
            </origination>
          </xsl:for-each>

          <!-- physdesc from 300 -->
          <xsl:for-each select="marc:datafield[@tag='300']">
            <physdesc>
              <xsl:call-template name="mu-chomp">
                <xsl:with-param name="s">
                  <xsl:call-template name="mu-field-text">
                    <xsl:with-param name="want" select="'abcef'"/>
                  </xsl:call-template>
                </xsl:with-param>
              </xsl:call-template>
            </physdesc>
          </xsl:for-each>

          <!-- language of the materials -->
          <xsl:variable name="lg8b">
            <xsl:call-template name="mu-cf-slice">
              <xsl:with-param name="pos" select="35"/>
              <xsl:with-param name="len" select="3"/>
            </xsl:call-template>
          </xsl:variable>
          <xsl:if test="translate($lg8b, ' |', '') != ''">
            <langmaterial>
              <language langcode="{$lg8b}"><xsl:value-of select="$lg8b"/></language>
            </langmaterial>
          </xsl:if>
        </did>

        <!-- scopecontent from 520 (and 545 biographical/historical) -->
        <xsl:if test="marc:datafield[@tag='520']">
          <scopecontent>
            <xsl:for-each select="marc:datafield[@tag='520']">
              <p>
                <xsl:call-template name="mu-field-text">
                  <xsl:with-param name="want" select="'ab'"/>
                </xsl:call-template>
              </p>
            </xsl:for-each>
          </scopecontent>
        </xsl:if>
        <xsl:if test="marc:datafield[@tag='545']">
          <bioghist>
            <xsl:for-each select="marc:datafield[@tag='545']">
              <p>
                <xsl:call-template name="mu-field-text">
                  <xsl:with-param name="want" select="'ab'"/>
                </xsl:call-template>
              </p>
            </xsl:for-each>
          </bioghist>
        </xsl:if>

        <!-- controlaccess from the 6XX access points -->
        <xsl:if test="marc:datafield[@tag='600' or @tag='610' or @tag='611'
                      or @tag='650' or @tag='651' or @tag='655']">
          <controlaccess>
            <xsl:for-each select="marc:datafield[@tag='600']">
              <persname><part><xsl:call-template name="ead-heading"/></part></persname>
            </xsl:for-each>
            <xsl:for-each select="marc:datafield[@tag='610' or @tag='611']">
              <corpname><part><xsl:call-template name="ead-heading"/></part></corpname>
            </xsl:for-each>
            <xsl:for-each select="marc:datafield[@tag='650']">
              <subject>
                <xsl:call-template name="ead-source"/>
                <part><xsl:call-template name="ead-heading"/></part>
              </subject>
            </xsl:for-each>
            <xsl:for-each select="marc:datafield[@tag='651']">
              <geogname>
                <xsl:call-template name="ead-source"/>
                <part><xsl:call-template name="ead-heading"/></part>
              </geogname>
            </xsl:for-each>
            <xsl:for-each select="marc:datafield[@tag='655']">
              <genreform>
                <xsl:call-template name="ead-source"/>
                <part><xsl:call-template name="ead-heading"/></part>
              </genreform>
            </xsl:for-each>
          </controlaccess>
        </xsl:if>
      </archdesc>
    </ead>
  </xsl:template>

  <!-- one 6XX heading with subdivisions joined by double dash -->
  <xsl:template name="ead-heading">
    <xsl:for-each select="marc:subfield[contains('abcdqtxyzv', @code)]">
      <xsl:if test="position() &gt; 1">
        <xsl:choose>
          <xsl:when test="contains('xyzv', @code)">--</xsl:when>
          <xsl:otherwise><xsl:text> </xsl:text></xsl:otherwise>
        </xsl:choose>
      </xsl:if>
      <xsl:call-template name="mu-chomp">
        <xsl:with-param name="s" select="."/>
      </xsl:call-template>
    </xsl:for-each>
  </xsl:template>

  <!-- @source on an access point, from ind2 / $2 -->
  <xsl:template name="ead-source">
    <xsl:variable name="scheme">
      <xsl:call-template name="mu-subject-scheme">
        <xsl:with-param name="ind2" select="@ind2"/>
        <xsl:with-param name="sf2" select="marc:subfield[@code='2']"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:if test="$scheme != ''">
      <xsl:attribute name="source"><xsl:value-of select="$scheme"/></xsl:attribute>
    </xsl:if>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
