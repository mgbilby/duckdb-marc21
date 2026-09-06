<?xml version="1.0" encoding="UTF-8"?>
<!--
  marc-utils.xsl - shared helper templates for the duckdb-marc21 XSLT
  crosswalk set. Original work for this project, written against the
  public MARC 21 format documentation. XSLT 1.0 (xsltproc-friendly).

  Naming convention: every helper here is a named template with the
  "mu-" prefix so importing stylesheets can mix in their own names
  without collisions.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim">

  <!-- ================================================================
       mu-field-text
       Concatenate the wanted subfields of the current datafield, in
       document order, separated by $glue. $want is a plain string of
       subfield codes, e.g. 'abc'. Call with a marc:datafield as the
       current node.
       ================================================================ -->
  <xsl:template name="mu-field-text">
    <xsl:param name="want" select="'abcdefghijklmnopqrstuvwxyz'"/>
    <xsl:param name="glue" select="' '"/>
    <xsl:for-each select="marc:subfield[string-length(@code) = 1 and contains($want, @code)]">
      <xsl:if test="position() &gt; 1">
        <xsl:value-of select="$glue"/>
      </xsl:if>
      <xsl:value-of select="normalize-space(.)"/>
    </xsl:for-each>
  </xsl:template>

  <!-- ================================================================
       mu-chomp
       Trim ISBD-style trailing punctuation from a string: whitespace
       plus any run of  , ; : / =  and, when $drop-period is true, one
       final period. The period survives when it closes an ellipsis
       ("...") or a single-letter initial ("Tolkien, J. R. R.").
       ================================================================ -->
  <xsl:template name="mu-chomp">
    <xsl:param name="s"/>
    <xsl:param name="drop-period" select="true()"/>
    <xsl:variable name="t" select="normalize-space($s)"/>
    <xsl:variable name="n" select="string-length($t)"/>
    <xsl:variable name="tail" select="substring($t, $n, 1)"/>
    <xsl:choose>
      <xsl:when test="$n = 0"/>
      <xsl:when test="contains(',;:/=', $tail)">
        <xsl:call-template name="mu-chomp">
          <xsl:with-param name="s" select="substring($t, 1, $n - 1)"/>
          <xsl:with-param name="drop-period" select="$drop-period"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:when test="boolean($drop-period)
                      and $tail = '.'
                      and not(substring($t, $n - 1, 1) = '.')
                      and not(substring($t, $n - 2, 1) = ' ')">
        <xsl:value-of select="substring($t, 1, $n - 1)"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:value-of select="$t"/>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- ================================================================
       mu-unbracket
       Remove one pair of enclosing square brackets: "[2020]" -> "2020".
       Leaves anything else untouched.
       ================================================================ -->
  <xsl:template name="mu-unbracket">
    <xsl:param name="s"/>
    <xsl:variable name="t" select="normalize-space($s)"/>
    <xsl:variable name="n" select="string-length($t)"/>
    <xsl:choose>
      <xsl:when test="$n &gt; 1 and starts-with($t, '[') and substring($t, $n, 1) = ']'">
        <xsl:value-of select="substring($t, 2, $n - 2)"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:value-of select="$t"/>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- ================================================================
       mu-leader-at
       One character of the leader, addressed by the 0-based position
       used in the MARC documentation (Leader/06 -> $pos = 6).
       ================================================================ -->
  <xsl:template name="mu-leader-at">
    <xsl:param name="rec" select="ancestor-or-self::marc:record[1]"/>
    <xsl:param name="pos"/>
    <xsl:value-of select="substring($rec/marc:leader, $pos + 1, 1)"/>
  </xsl:template>

  <!-- ================================================================
       mu-cf-slice
       A slice of a control field, 0-based position + length, e.g.
       008/35-37 -> tag '008', pos 35, len 3.
       ================================================================ -->
  <xsl:template name="mu-cf-slice">
    <xsl:param name="rec" select="ancestor-or-self::marc:record[1]"/>
    <xsl:param name="tag" select="'008'"/>
    <xsl:param name="pos"/>
    <xsl:param name="len" select="1"/>
    <xsl:value-of select="substring($rec/marc:controlfield[@tag = $tag][1], $pos + 1, $len)"/>
  </xsl:template>

  <!-- ================================================================
       mu-ind-number
       An indicator interpreted as a digit; anything non-numeric
       (blank included) comes back as 0.
       ================================================================ -->
  <xsl:template name="mu-ind-number">
    <xsl:param name="ind"/>
    <xsl:choose>
      <xsl:when test="string-length($ind) = 1 and contains('0123456789', $ind)">
        <xsl:value-of select="number($ind)"/>
      </xsl:when>
      <xsl:otherwise>0</xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- ================================================================
       mu-subject-scheme
       The thesaurus behind a 6XX heading: second indicator per the
       MARC subject access documentation, falling through to subfield
       $2 when ind2 = 7. Empty result means "unstated".
       ================================================================ -->
  <xsl:template name="mu-subject-scheme">
    <xsl:param name="ind2"/>
    <xsl:param name="sf2"/>
    <xsl:choose>
      <xsl:when test="$ind2 = '0'">lcsh</xsl:when>
      <xsl:when test="$ind2 = '1'">lcshac</xsl:when>
      <xsl:when test="$ind2 = '2'">mesh</xsl:when>
      <xsl:when test="$ind2 = '3'">nal</xsl:when>
      <xsl:when test="$ind2 = '5'">csh</xsl:when>
      <xsl:when test="$ind2 = '6'">rvm</xsl:when>
      <xsl:when test="$ind2 = '7'">
        <xsl:value-of select="normalize-space($sf2)"/>
      </xsl:when>
    </xsl:choose>
  </xsl:template>

  <!-- ================================================================
       mu-linkage-tag
       The paired tag inside a $6 linkage value: '245-01/$1' -> '245'.
       Call with any string; empty input yields empty output.
       ================================================================ -->
  <xsl:template name="mu-linkage-tag">
    <xsl:param name="sf6"/>
    <xsl:variable name="v" select="normalize-space($sf6)"/>
    <xsl:if test="contains($v, '-')">
      <xsl:value-of select="substring-before($v, '-')"/>
    </xsl:if>
  </xsl:template>

  <!-- ================================================================
       mu-occurrence
       The occurrence number inside a $6 linkage value:
       '880-01/$1' -> '01'. Empty when absent.
       ================================================================ -->
  <xsl:template name="mu-occurrence">
    <xsl:param name="sf6"/>
    <xsl:variable name="v" select="normalize-space($sf6)"/>
    <xsl:variable name="after" select="substring-after($v, '-')"/>
    <xsl:choose>
      <xsl:when test="contains($after, '/')">
        <xsl:value-of select="substring-before($after, '/')"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:value-of select="$after"/>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- ================================================================
       mu-digits
       Keep only ASCII digits: 'c2020.' -> '2020'.
       ================================================================ -->
  <xsl:template name="mu-digits">
    <xsl:param name="s"/>
    <xsl:value-of select="translate($s, translate($s, '0123456789', ''), '')"/>
  </xsl:template>

  <!-- ================================================================
       mu-replace-all
       Every occurrence of $find in $s becomes $repl. Plain recursive
       string surgery; $find must be non-empty.
       ================================================================ -->
  <xsl:template name="mu-replace-all">
    <xsl:param name="s"/>
    <xsl:param name="find"/>
    <xsl:param name="repl"/>
    <xsl:choose>
      <xsl:when test="$find != '' and contains($s, $find)">
        <xsl:value-of select="substring-before($s, $find)"/>
        <xsl:value-of select="$repl"/>
        <xsl:call-template name="mu-replace-all">
          <xsl:with-param name="s" select="substring-after($s, $find)"/>
          <xsl:with-param name="find" select="$find"/>
          <xsl:with-param name="repl" select="$repl"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise>
        <xsl:value-of select="$s"/>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- ================================================================
       mu-json-escape
       A string made safe for use inside a double-quoted JSON literal,
       per RFC 8259: backslash and quote get a backslash, and the
       control characters that occur in bibliographic data (LF, CR,
       TAB) become \n \r \t. Order matters: backslashes first.
       ================================================================ -->
  <xsl:template name="mu-json-escape">
    <xsl:param name="s"/>
    <xsl:variable name="p1">
      <xsl:call-template name="mu-replace-all">
        <xsl:with-param name="s" select="$s"/>
        <xsl:with-param name="find" select="'\'"/>
        <xsl:with-param name="repl" select="'\\'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="p2">
      <xsl:call-template name="mu-replace-all">
        <xsl:with-param name="s" select="$p1"/>
        <xsl:with-param name="find" select="'&quot;'"/>
        <xsl:with-param name="repl" select="'\&quot;'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="p3">
      <xsl:call-template name="mu-replace-all">
        <xsl:with-param name="s" select="$p2"/>
        <xsl:with-param name="find" select="'&#10;'"/>
        <xsl:with-param name="repl" select="'\n'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="p4">
      <xsl:call-template name="mu-replace-all">
        <xsl:with-param name="s" select="$p3"/>
        <xsl:with-param name="find" select="'&#13;'"/>
        <xsl:with-param name="repl" select="'\r'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:call-template name="mu-replace-all">
      <xsl:with-param name="s" select="$p4"/>
      <xsl:with-param name="find" select="'&#9;'"/>
      <xsl:with-param name="repl" select="'\t'"/>
    </xsl:call-template>
  </xsl:template>

  <!-- ================================================================
       mu-isbn13
       Normalize an ISBN to its 13-digit form, mirroring the ISO 2108
       conversion rule: strip separators, keep a 13-digit value as-is,
       and turn a 10-character value into 978 + first nine digits +
       recomputed modulus-10 check digit (weights 1 and 3 alternating).
       Anything of another length comes back empty.
       ================================================================ -->
  <xsl:template name="mu-isbn13">
    <xsl:param name="s"/>
    <!-- keep digits, x/X, hyphen and space; then drop the separators
         and uppercase the x -->
    <xsl:variable name="clean"
        select="translate($s, translate($s, '0123456789xX- ', ''), '')"/>
    <xsl:variable name="c" select="translate($clean, 'x- ', 'X')"/>
    <xsl:choose>
      <xsl:when test="string-length($c) = 13
                      and translate($c, '0123456789', '') = ''">
        <xsl:value-of select="$c"/>
      </xsl:when>
      <xsl:when test="string-length($c) = 10
                      and translate(substring($c, 1, 9), '0123456789', '') = ''">
        <xsl:variable name="core" select="concat('978', substring($c, 1, 9))"/>
        <xsl:variable name="sum" select="
              substring($core, 1, 1) + 3 * substring($core, 2, 1)
            + substring($core, 3, 1) + 3 * substring($core, 4, 1)
            + substring($core, 5, 1) + 3 * substring($core, 6, 1)
            + substring($core, 7, 1) + 3 * substring($core, 8, 1)
            + substring($core, 9, 1) + 3 * substring($core, 10, 1)
            + substring($core, 11, 1) + 3 * substring($core, 12, 1)"/>
        <xsl:value-of select="concat($core, ($sum * 9) mod 10)"/>
      </xsl:when>
    </xsl:choose>
  </xsl:template>

  <!-- ================================================================
       mu-first-year
       The first run of four consecutive ASCII digits in $s, e.g.
       '[Paris, c2020]' -> '2020'. Empty when there is none.
       ================================================================ -->
  <xsl:template name="mu-first-year">
    <xsl:param name="s"/>
    <xsl:variable name="t" select="string($s)"/>
    <xsl:choose>
      <xsl:when test="string-length($t) &lt; 4"/>
      <xsl:when test="translate(substring($t, 1, 4), '0123456789', '') = ''">
        <xsl:value-of select="substring($t, 1, 4)"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:call-template name="mu-first-year">
          <xsl:with-param name="s" select="substring($t, 2)"/>
        </xsl:call-template>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

</xsl:stylesheet>
