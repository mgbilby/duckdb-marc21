<?xml version="1.0" encoding="UTF-8"?>
<!--
  marc21-to-unimarc-skeleton.xsl - MARC 21 MARCXML (slim) to
  UNIMARC-shaped MARCXML: an honest, documented SUBSET.

  Original crosswalk for the duckdb-marc21 project, written from:
    * the IFLA UNIMARC Bibliographic format documentation (record
      label, 001, 100 general processing data, 101, 200, 210, 215,
      606, 700/701),
    * the Library of Congress MARC 21 bibliographic format
      documentation for the sources.

  COVERAGE - exactly these conversions and nothing else:
    record label   : positions 5-7 translated (status kept; type of
                     record m->l computer file, t->b manuscript text,
                     p->m mixed/multimedia, others kept; bibliographic
                     level b->a serial component part, i->s integrating,
                     d->m subunit, others kept); the rest of the label
                     is rebuilt as a placeholder ("00000" length,
                     "22...450 " map).
    001            : copied verbatim.
    100 $a         : 36-character general processing data string built
                     from MARC 21 008: date entered (008/00-05 expanded
                     to YYYYMMDD, century break at 50), type-of-date
                     code translated (s->d, m->g, r->e, t->h, c->a,
                     d->b, q/n/u->f), dates 1 and 2 (008/07-14);
                     target audience, government publication, modified
                     record and language-of-cataloguing positions are
                     left blank (unknowable from the source), followed
                     by 'y' (no transliteration), '50' (character set:
                     UCS/Unicode) and blanks.
    101 0# $a      : language(s) from 008/35-37 and extra 041 $a.
    200 1# / 0#    : from 245 ($a->$a, $b->$e, $c->$f, $n->$h, $p->$i);
                     ind1 = 1 when the title is an access point.
    210 ## $a$c$d  : from 260 / 264 ($a place, $b name, $c date).
    215 $a$c$d     : from 300 ($a extent, $b->$c other details,
                     $c->$d dimensions).
    606            : from 650; subdivisions re-lettered to UNIMARC
                     conventions ($x topical stays $x, MARC 21 $z
                     geographical -> UNIMARC $y, MARC 21 $y
                     chronological -> UNIMARC $z), $2 system code kept.
    700 / 701      : from 100 / 700 personal names; "Surname, Forename"
                     split into UNIMARC $a (entry element) and $b (part
                     of name other than entry element), $d->$f dates,
                     ind2 = 1 (entered under surname).

  OUT OF SCOPE - stated plainly: every other field, coded data beyond
  the label and 100/101 (105, 106, 110...), corporate names (710/711),
  titles other than 245, series, notes, identifiers (010/015/020/022
  have UNIMARC homes at 020/010/011 with different subfielding),
  electronic location, holdings, and all UNIMARC mandatory-field
  completion rules. Full UNIMARC semantics are NOT provided; treat the
  output as a migration starting point that a UNIMARC cataloguer must
  complete.

  Output uses the same slim XML markup (record/leader/controlfield/
  datafield/subfield) in the MARC21 slim namespace, since UNIMARC has
  no distinct slim schema of its own; tags and subfields follow
  UNIMARC. XSLT 1.0, xsltproc-friendly.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim">

  <xsl:include href="marc-utils.xsl"/>

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:template match="/marc:collection">
    <marc:collection>
      <xsl:apply-templates select="marc:record"/>
    </marc:collection>
  </xsl:template>

  <xsl:template match="/marc:record | marc:record">
    <marc:record>
      <marc:leader>
        <xsl:call-template name="uni-label"/>
      </marc:leader>

      <xsl:for-each select="marc:controlfield[@tag='001']">
        <marc:controlfield tag="001">
          <xsl:value-of select="normalize-space(.)"/>
        </marc:controlfield>
      </xsl:for-each>

      <!-- 100: general processing data -->
      <marc:datafield tag="100" ind1=" " ind2=" ">
        <marc:subfield code="a">
          <xsl:call-template name="uni-100a"/>
        </marc:subfield>
      </marc:datafield>

      <!-- 101: language of the item -->
      <xsl:variable name="lg8">
        <xsl:call-template name="mu-cf-slice">
          <xsl:with-param name="pos" select="35"/>
          <xsl:with-param name="len" select="3"/>
        </xsl:call-template>
      </xsl:variable>
      <xsl:if test="translate($lg8, ' |', '') != ''
                    or marc:datafield[@tag='041']/marc:subfield[@code='a']">
        <marc:datafield tag="101" ind1="0" ind2=" ">
          <xsl:if test="translate($lg8, ' |', '') != ''">
            <marc:subfield code="a"><xsl:value-of select="$lg8"/></marc:subfield>
          </xsl:if>
          <xsl:for-each select="marc:datafield[@tag='041']/marc:subfield[@code='a']">
            <xsl:if test="normalize-space(.) != string($lg8)">
              <marc:subfield code="a">
                <xsl:value-of select="normalize-space(.)"/>
              </marc:subfield>
            </xsl:if>
          </xsl:for-each>
        </marc:datafield>
      </xsl:if>

      <!-- 200: title and statement of responsibility, from 245 -->
      <xsl:for-each select="marc:datafield[@tag='245'][1]">
        <marc:datafield tag="200" ind1="1" ind2=" ">
          <xsl:for-each select="marc:subfield[contains('abcfnp', @code)]">
            <xsl:variable name="v">
              <xsl:call-template name="mu-chomp">
                <xsl:with-param name="s" select="."/>
              </xsl:call-template>
            </xsl:variable>
            <xsl:if test="string($v) != ''">
              <marc:subfield>
                <xsl:attribute name="code">
                  <xsl:choose>
                    <xsl:when test="@code = 'a'">a</xsl:when>
                    <xsl:when test="@code = 'b'">e</xsl:when>
                    <xsl:when test="@code = 'c'">f</xsl:when>
                    <xsl:when test="@code = 'n'">h</xsl:when>
                    <xsl:when test="@code = 'p'">i</xsl:when>
                    <xsl:otherwise>a</xsl:otherwise>
                  </xsl:choose>
                </xsl:attribute>
                <xsl:value-of select="$v"/>
              </marc:subfield>
            </xsl:if>
          </xsl:for-each>
        </marc:datafield>
      </xsl:for-each>

      <!-- 210: publication, distribution, from 260/264 -->
      <xsl:for-each select="marc:datafield[@tag='260'
                            or (@tag='264' and (@ind2='1' or @ind2=' ' or @ind2=''))][1]">
        <marc:datafield tag="210" ind1=" " ind2=" ">
          <xsl:for-each select="marc:subfield[@code='a']">
            <marc:subfield code="a">
              <xsl:call-template name="mu-chomp">
                <xsl:with-param name="s" select="."/>
              </xsl:call-template>
            </marc:subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='b']">
            <marc:subfield code="c">
              <xsl:call-template name="mu-chomp">
                <xsl:with-param name="s" select="."/>
              </xsl:call-template>
            </marc:subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='c']">
            <marc:subfield code="d">
              <xsl:call-template name="mu-chomp">
                <xsl:with-param name="s" select="."/>
              </xsl:call-template>
            </marc:subfield>
          </xsl:for-each>
        </marc:datafield>
      </xsl:for-each>

      <!-- 215: physical description, from 300 -->
      <xsl:for-each select="marc:datafield[@tag='300']">
        <marc:datafield tag="215" ind1=" " ind2=" ">
          <xsl:for-each select="marc:subfield[@code='a']">
            <marc:subfield code="a">
              <xsl:call-template name="mu-chomp">
                <xsl:with-param name="s" select="."/>
              </xsl:call-template>
            </marc:subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='b']">
            <marc:subfield code="c">
              <xsl:call-template name="mu-chomp">
                <xsl:with-param name="s" select="."/>
              </xsl:call-template>
            </marc:subfield>
          </xsl:for-each>
          <xsl:for-each select="marc:subfield[@code='c']">
            <marc:subfield code="d">
              <xsl:call-template name="mu-chomp">
                <xsl:with-param name="s" select="."/>
              </xsl:call-template>
            </marc:subfield>
          </xsl:for-each>
        </marc:datafield>
      </xsl:for-each>

      <!-- 606: topical subject, from 650, subdivisions re-lettered -->
      <xsl:for-each select="marc:datafield[@tag='650']">
        <marc:datafield tag="606" ind1=" " ind2=" ">
          <xsl:for-each select="marc:subfield[contains('axyz2', @code)]">
            <xsl:variable name="v">
              <xsl:choose>
                <xsl:when test="@code = '2'">
                  <xsl:value-of select="normalize-space(.)"/>
                </xsl:when>
                <xsl:otherwise>
                  <xsl:call-template name="mu-chomp">
                    <xsl:with-param name="s" select="."/>
                  </xsl:call-template>
                </xsl:otherwise>
              </xsl:choose>
            </xsl:variable>
            <xsl:if test="string($v) != ''">
              <marc:subfield>
                <xsl:attribute name="code">
                  <xsl:choose>
                    <xsl:when test="@code = 'a'">a</xsl:when>
                    <xsl:when test="@code = 'x'">x</xsl:when>
                    <!-- MARC 21 $y chronological -> UNIMARC $z -->
                    <xsl:when test="@code = 'y'">z</xsl:when>
                    <!-- MARC 21 $z geographical -> UNIMARC $y -->
                    <xsl:when test="@code = 'z'">y</xsl:when>
                    <xsl:otherwise>2</xsl:otherwise>
                  </xsl:choose>
                </xsl:attribute>
                <xsl:value-of select="$v"/>
              </marc:subfield>
            </xsl:if>
          </xsl:for-each>
          <!-- LC vocabulary implied by ind2 = 0 -->
          <xsl:if test="@ind2 = '0' and not(marc:subfield[@code='2'])">
            <marc:subfield code="2">lc</marc:subfield>
          </xsl:if>
        </marc:datafield>
      </xsl:for-each>

      <!-- 700 (first personal name) / 701 (others), from 100/700 -->
      <xsl:for-each select="marc:datafield[@tag='100'][1]">
        <xsl:call-template name="uni-person">
          <xsl:with-param name="tag" select="'700'"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:for-each select="marc:datafield[@tag='700']">
        <xsl:call-template name="uni-person">
          <xsl:with-param name="tag" select="'701'"/>
        </xsl:call-template>
      </xsl:for-each>
    </marc:record>
  </xsl:template>

  <!-- ================================================================
       UNIMARC record label: 00000 + status + translated type/level +
       "  22" + 00000 + three blanks + "450 ".
       ================================================================ -->
  <xsl:template name="uni-label">
    <xsl:variable name="l5">
      <xsl:call-template name="mu-leader-at">
        <xsl:with-param name="pos" select="5"/>
      </xsl:call-template>
    </xsl:variable>
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
    <xsl:text>00000</xsl:text>
    <xsl:choose>
      <xsl:when test="$l5 != ''"><xsl:value-of select="$l5"/></xsl:when>
      <xsl:otherwise>n</xsl:otherwise>
    </xsl:choose>
    <xsl:choose>
      <!-- type of record -->
      <xsl:when test="$l6 = 'm'">l</xsl:when>
      <xsl:when test="$l6 = 't'">b</xsl:when>
      <xsl:when test="$l6 = 'p'">m</xsl:when>
      <xsl:when test="$l6 != ''"><xsl:value-of select="$l6"/></xsl:when>
      <xsl:otherwise>a</xsl:otherwise>
    </xsl:choose>
    <xsl:choose>
      <!-- bibliographic level -->
      <xsl:when test="$l7 = 'b'">a</xsl:when>
      <xsl:when test="$l7 = 'i'">s</xsl:when>
      <xsl:when test="$l7 = 'd'">m</xsl:when>
      <xsl:when test="$l7 != ''"><xsl:value-of select="$l7"/></xsl:when>
      <xsl:otherwise>m</xsl:otherwise>
    </xsl:choose>
    <xsl:text>  2200000   450 </xsl:text>
  </xsl:template>

  <!-- ================================================================
       UNIMARC 100 $a: 36 characters of general processing data.
       ================================================================ -->
  <xsl:template name="uni-100a">
    <xsl:variable name="f8" select="marc:controlfield[@tag='008'][1]"/>
    <!-- 0-7 date entered on file, YYYYMMDD -->
    <xsl:variable name="yy" select="substring($f8, 1, 2)"/>
    <xsl:choose>
      <xsl:when test="string-length(translate(substring($f8, 1, 6),
                          '0123456789', '')) = 0
                      and string-length(substring($f8, 1, 6)) = 6">
        <xsl:choose>
          <xsl:when test="number($yy) &gt;= 50">19</xsl:when>
          <xsl:otherwise>20</xsl:otherwise>
        </xsl:choose>
        <xsl:value-of select="substring($f8, 1, 6)"/>
      </xsl:when>
      <xsl:otherwise>00000000</xsl:otherwise>
    </xsl:choose>
    <!-- 8 type of publication date -->
    <xsl:variable name="dt" select="substring($f8, 7, 1)"/>
    <xsl:choose>
      <xsl:when test="$dt = 's'">d</xsl:when>
      <xsl:when test="$dt = 'm'">g</xsl:when>
      <xsl:when test="$dt = 'r'">e</xsl:when>
      <xsl:when test="$dt = 't'">h</xsl:when>
      <xsl:when test="$dt = 'c'">a</xsl:when>
      <xsl:when test="$dt = 'd'">b</xsl:when>
      <xsl:otherwise>f</xsl:otherwise>
    </xsl:choose>
    <!-- 9-12 date 1, 13-16 date 2 (blank-padded) -->
    <xsl:value-of select="substring(concat(substring($f8, 8, 4),
                                           '    '), 1, 4)"/>
    <xsl:value-of select="substring(concat(substring($f8, 12, 4),
                                           '    '), 1, 4)"/>
    <!-- 17-19 target audience, 20 government publication,
         21 modified record, 22-24 language of cataloguing:
         unknowable from MARC 21 008, left blank -->
    <xsl:text>        </xsl:text>
    <!-- 25 transliteration code: y = no transliteration -->
    <xsl:text>y</xsl:text>
    <!-- 26-29 character sets: 50 = ISO 10646 (UCS/Unicode) -->
    <xsl:text>50  </xsl:text>
    <!-- 30-33 additional character sets, 34-35 script of title -->
    <xsl:text>      </xsl:text>
  </xsl:template>

  <!-- ================================================================
       Personal name field: "Surname, Forename" split across $a/$b.
       ================================================================ -->
  <xsl:template name="uni-person">
    <xsl:param name="tag"/>
    <xsl:variable name="full">
      <xsl:call-template name="mu-chomp">
        <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:if test="string($full) != ''">
      <marc:datafield tag="{$tag}" ind1=" " ind2="1">
        <xsl:choose>
          <xsl:when test="contains($full, ',')">
            <marc:subfield code="a">
              <xsl:value-of select="normalize-space(substring-before($full, ','))"/>
            </marc:subfield>
            <marc:subfield code="b">
              <xsl:value-of select="normalize-space(substring-after($full, ','))"/>
            </marc:subfield>
          </xsl:when>
          <xsl:otherwise>
            <marc:subfield code="a"><xsl:value-of select="$full"/></marc:subfield>
          </xsl:otherwise>
        </xsl:choose>
        <xsl:for-each select="marc:subfield[@code='d'][1]">
          <marc:subfield code="f">
            <xsl:call-template name="mu-chomp">
              <xsl:with-param name="s" select="."/>
            </xsl:call-template>
          </marc:subfield>
        </xsl:for-each>
      </marc:datafield>
    </xsl:if>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
