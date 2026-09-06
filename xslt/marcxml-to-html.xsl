<?xml version="1.0" encoding="UTF-8"?>
<!--
  marcxml-to-html.xsl - a clean, human-readable rendering of MARCXML.

  Original display stylesheet for the duckdb-marc21 project. One card
  per record: the 245 as heading, then the leader, control fields and
  data fields as a fixed-width table with tag, indicators, and subfields
  marked with their codes. XSLT 1.0.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    exclude-result-prefixes="marc">

  <xsl:include href="marc-utils.xsl"/>

  <xsl:output method="html" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:template match="/">
    <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <title>MARC record display</title>
        <style>
          body { font-family: system-ui, sans-serif; margin: 2rem auto;
                 max-width: 60rem; color: #1c2126; background: #fafbfc; }
          h1   { font-size: 1.3rem; border-bottom: 2px solid #2a5d8f;
                 padding-bottom: .3rem; }
          .rec { border: 1px solid #d4dae0; border-radius: 6px;
                 margin: 1.2rem 0; padding: .8rem 1rem; background: #fff; }
          .rec h2 { font-size: 1.05rem; margin: 0 0 .6rem 0; color: #2a5d8f; }
          table.fields { border-collapse: collapse; width: 100%;
                         font-family: ui-monospace, monospace; font-size: .85rem; }
          table.fields td { vertical-align: top; padding: .15rem .5rem;
                            border-top: 1px solid #eef1f4; }
          td.tg  { width: 3em; font-weight: 600; color: #7a3e9d; }
          td.in  { width: 2.5em; color: #8a949e; white-space: pre; }
          span.sc { color: #b3541e; font-weight: 600; }
          span.sc:before { content: "\2021"; }  /* double dagger */
          .ldr td { color: #5c6670; font-style: italic; }
        </style>
      </head>
      <body>
        <h1>
          <xsl:text>MARC records (</xsl:text>
          <xsl:value-of select="count(//marc:record)"/>
          <xsl:text>)</xsl:text>
        </h1>
        <xsl:apply-templates select="//marc:record"/>
      </body>
    </html>
  </xsl:template>

  <xsl:template match="marc:record">
    <div class="rec">
      <h2>
        <xsl:choose>
          <xsl:when test="marc:datafield[@tag='245']">
            <xsl:for-each select="marc:datafield[@tag='245'][1]">
              <xsl:call-template name="mu-chomp">
                <xsl:with-param name="s">
                  <xsl:call-template name="mu-field-text">
                    <xsl:with-param name="want" select="'abnp'"/>
                  </xsl:call-template>
                </xsl:with-param>
              </xsl:call-template>
            </xsl:for-each>
          </xsl:when>
          <xsl:otherwise>
            <xsl:text>[record </xsl:text>
            <xsl:value-of select="normalize-space(marc:controlfield[@tag='001'])"/>
            <xsl:text>]</xsl:text>
          </xsl:otherwise>
        </xsl:choose>
      </h2>
      <table class="fields">
        <tr class="ldr">
          <td class="tg">LDR</td>
          <td class="in"/>
          <td><xsl:value-of select="marc:leader"/></td>
        </tr>
        <xsl:apply-templates select="marc:controlfield | marc:datafield"/>
      </table>
    </div>
  </xsl:template>

  <xsl:template match="marc:controlfield">
    <tr>
      <td class="tg"><xsl:value-of select="@tag"/></td>
      <td class="in"/>
      <td><xsl:value-of select="."/></td>
    </tr>
  </xsl:template>

  <xsl:template match="marc:datafield">
    <tr>
      <td class="tg"><xsl:value-of select="@tag"/></td>
      <td class="in">
        <xsl:call-template name="show-ind">
          <xsl:with-param name="v" select="@ind1"/>
        </xsl:call-template>
        <xsl:call-template name="show-ind">
          <xsl:with-param name="v" select="@ind2"/>
        </xsl:call-template>
      </td>
      <td>
        <xsl:for-each select="marc:subfield">
          <xsl:if test="position() &gt; 1">
            <xsl:text> </xsl:text>
          </xsl:if>
          <span class="sc"><xsl:value-of select="@code"/></span>
          <xsl:text> </xsl:text>
          <xsl:value-of select="."/>
        </xsl:for-each>
      </td>
    </tr>
  </xsl:template>

  <!-- blank indicators print as '#' so alignment is visible -->
  <xsl:template name="show-ind">
    <xsl:param name="v"/>
    <xsl:choose>
      <xsl:when test="normalize-space($v) = ''">#</xsl:when>
      <xsl:otherwise><xsl:value-of select="$v"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
