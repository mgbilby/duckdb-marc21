<?xml version="1.0" encoding="UTF-8"?>
<!--
  marcxml-to-onix3.xsl - MARCXML (slim) bibliographic records to ONIX for
  Books 3.x Product records (reference tag names).

  Original crosswalk for the duckdb-marc21 project, written against
  EDItEUR's freely published "ONIX for Books Product Information Format
  Specification" (release 3.x) and the ONIX code lists
  (https://www.editeur.org/93/Release-3.0-Downloads/) - referenced, not
  copied. ONIX is a trade metadata format; a library bib record fills only
  part of a real Product message, and this stylesheet is an HONEST SUBSET:

    RecordReference        001 (falls back to a generated value)
    NotificationType       03 (confirmed)
    ProductIdentifier      ISBN-13 (ProductIDType 15) from 020 $a - an
                           ISBN-10 is upconverted with a computed check
                           digit; records with no usable ISBN carry their
                           001 as a proprietary id (ProductIDType 01)
    DescriptiveDetail
      ProductComposition   00 (single-component product)
      ProductForm          basics from leader/06 + 007/00-01 (List 150):
                           text BA (EA when 007 says electronic), audio AA
                           (AC for CD), video VA, cartographic CA,
                           digital EA, else ZZ
      TitleDetail          TitleType 01; TitleText from 245 $a, Subtitle
                           from $b (ISBD punctuation trimmed)
      Contributor          1XX/7XX personal and corporate names;
                           ContributorRole from $4 (marcrelator) or $e
                           text: aut A01, cmp A06, ill A12, pht A13,
                           edt B01, trl B06, com C01, nrt E07; otherwise
                           A01 for 1XX and Z99 for 7XX
      Language             LanguageRole 01 from 041 $a (else 008/35-37)
      Extent               ExtentType 00 / ExtentUnit 03 (pages) when
                           300 $a carries a leading page count
      Subject              650 ind2=0 -> SubjectSchemeIdentifier 04 (LCSH,
                           heading text with double-dash subdivisions);
                           082 -> 01 (Dewey, SchemeVersion from $2);
                           050 -> 03 (LC classification). NOTE: List 27
                           gives 03 to LC classification and 02 to the
                           ABRIDGED Dewey - 082 ind1=1 therefore maps
                           to 02, full Dewey to 01.
    PublishingDetail
      Publisher            PublishingRole 01, name from 264 ind2=1 $b
                           (else 260 $b); CityOfPublication from $a
      PublishingDate       PublishingDateRole 01, dateformat 05 (YYYY)
                           from 008/07-10

  NOT produced (out of scope for bib data): supply chain blocks
  (ProductSupply, SupplyDetail, prices), sales rights, collection/series
  as Collection composites, related products, marketing collateral.
  Parameters: sender-name (Header/Sender), sent-datetime (YYYYMMDD).
  XSLT 1.0 (xsltproc-friendly).
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:marc="http://www.loc.gov/MARC21/slim"
    xmlns="http://ns.editeur.org/onix/3.0/reference"
    exclude-result-prefixes="marc">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
  <xsl:strip-space elements="*"/>

  <xsl:param name="sender-name" select="'duckdb-marc21 ONIX crosswalk'"/>
  <xsl:param name="sent-datetime" select="'20240101'"/>

  <xsl:template match="/">
    <ONIXMessage release="3.0">
      <Header>
        <Sender>
          <SenderName><xsl:value-of select="$sender-name"/></SenderName>
        </Sender>
        <SentDateTime><xsl:value-of select="$sent-datetime"/></SentDateTime>
      </Header>
      <xsl:apply-templates select="//marc:record"/>
    </ONIXMessage>
  </xsl:template>

  <xsl:template name="ox-chomp">
    <xsl:param name="s"/>
    <xsl:variable name="t" select="normalize-space($s)"/>
    <xsl:variable name="n" select="string-length($t)"/>
    <xsl:choose>
      <xsl:when test="$n = 0"/>
      <xsl:when test="contains(',;:/=', substring($t, $n, 1))
                      or (substring($t, $n, 1) = '.'
                          and not(substring($t, $n - 1, 1) = '.'))">
        <xsl:call-template name="ox-chomp">
          <xsl:with-param name="s" select="substring($t, 1, $n - 1)"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$t"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- normalized ISBN-13 from an 020 $a transcription; empty if unusable -->
  <xsl:template name="ox-isbn13">
    <xsl:param name="raw"/>
    <!-- keep digits and X only -->
    <xsl:variable name="up" select="translate($raw, 'x', 'X')"/>
    <xsl:variable name="d"
        select="translate($up, translate($up, '0123456789X', ''), '')"/>
    <xsl:choose>
      <xsl:when test="string-length($d) = 13 and
                      (starts-with($d, '978') or starts-with($d, '979')) and
                      not(contains($d, 'X'))">
        <xsl:value-of select="$d"/>
      </xsl:when>
      <xsl:when test="string-length($d) = 10">
        <!-- upconvert: 978 + first nine digits + EAN check digit -->
        <xsl:variable name="p" select="concat('978', substring($d, 1, 9))"/>
        <xsl:variable name="sum"
            select="number(substring($p,1,1)) + 3*number(substring($p,2,1))
                  + number(substring($p,3,1)) + 3*number(substring($p,4,1))
                  + number(substring($p,5,1)) + 3*number(substring($p,6,1))
                  + number(substring($p,7,1)) + 3*number(substring($p,8,1))
                  + number(substring($p,9,1)) + 3*number(substring($p,10,1))
                  + number(substring($p,11,1)) + 3*number(substring($p,12,1))"/>
        <xsl:value-of select="concat($p, (10 - ($sum mod 10)) mod 10)"/>
      </xsl:when>
    </xsl:choose>
  </xsl:template>

  <!-- List 17 contributor role from $4 (marcrelator) or $e text -->
  <xsl:template name="ox-role">
    <xsl:param name="sf4"/>
    <xsl:param name="sfe"/>
    <xsl:param name="fallback" select="'Z99'"/>
    <xsl:variable name="r" select="normalize-space($sf4)"/>
    <xsl:variable name="e">
      <xsl:call-template name="ox-chomp"><xsl:with-param name="s" select="$sfe"/></xsl:call-template>
    </xsl:variable>
    <xsl:choose>
      <xsl:when test="$r = 'aut' or $e = 'author'">A01</xsl:when>
      <xsl:when test="$r = 'cmp' or $e = 'composer'">A06</xsl:when>
      <xsl:when test="$r = 'ill' or $e = 'illustrator'">A12</xsl:when>
      <xsl:when test="$r = 'pht' or $e = 'photographer'">A13</xsl:when>
      <xsl:when test="$r = 'edt' or $e = 'editor'">B01</xsl:when>
      <xsl:when test="$r = 'trl' or $e = 'translator'">B06</xsl:when>
      <xsl:when test="$r = 'com' or $e = 'compiler'">C01</xsl:when>
      <xsl:when test="$r = 'nrt' or $e = 'narrator'">E07</xsl:when>
      <xsl:otherwise><xsl:value-of select="$fallback"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template match="marc:record">
    <xsl:variable name="l6" select="substring(marc:leader, 7, 1)"/>
    <xsl:variable name="f007" select="marc:controlfield[@tag='007'][1]"/>
    <xsl:variable name="f008" select="marc:controlfield[@tag='008'][1]"/>
    <xsl:variable name="isbn13">
      <xsl:call-template name="ox-isbn13">
        <xsl:with-param name="raw"
            select="marc:datafield[@tag='020']/marc:subfield[@code='a'][1]"/>
      </xsl:call-template>
    </xsl:variable>
    <Product>
      <RecordReference>
        <xsl:choose>
          <xsl:when test="marc:controlfield[@tag='001']">
            <xsl:value-of select="normalize-space(marc:controlfield[@tag='001'][1])"/>
          </xsl:when>
          <xsl:otherwise>rec-<xsl:value-of select="position()"/></xsl:otherwise>
        </xsl:choose>
      </RecordReference>
      <NotificationType>03</NotificationType>
      <xsl:choose>
        <xsl:when test="$isbn13 != ''">
          <ProductIdentifier>
            <ProductIDType>15</ProductIDType>
            <IDValue><xsl:value-of select="$isbn13"/></IDValue>
          </ProductIdentifier>
        </xsl:when>
        <xsl:otherwise>
          <ProductIdentifier>
            <ProductIDType>01</ProductIDType>
            <IDTypeName>control number</IDTypeName>
            <IDValue><xsl:value-of select="normalize-space(marc:controlfield[@tag='001'][1])"/></IDValue>
          </ProductIdentifier>
        </xsl:otherwise>
      </xsl:choose>

      <DescriptiveDetail>
        <ProductComposition>00</ProductComposition>
        <ProductForm>
          <xsl:choose>
            <xsl:when test="substring($f007, 1, 1) = 'c'">EA</xsl:when>
            <xsl:when test="$l6 = 'i' or $l6 = 'j'">
              <xsl:choose>
                <xsl:when test="substring($f007, 1, 2) = 'sd'">AC</xsl:when>
                <xsl:otherwise>AA</xsl:otherwise>
              </xsl:choose>
            </xsl:when>
            <xsl:when test="$l6 = 'g'">VA</xsl:when>
            <xsl:when test="$l6 = 'e' or $l6 = 'f'">CA</xsl:when>
            <xsl:when test="$l6 = 'm'">EA</xsl:when>
            <xsl:when test="$l6 = 'a' or $l6 = 't' or $l6 = 'c' or $l6 = 'd'">BA</xsl:when>
            <xsl:otherwise>ZZ</xsl:otherwise>
          </xsl:choose>
        </ProductForm>
        <TitleDetail>
          <TitleType>01</TitleType>
          <TitleElement>
            <TitleElementLevel>01</TitleElementLevel>
            <TitleText>
              <xsl:call-template name="ox-chomp">
                <xsl:with-param name="s"
                    select="marc:datafield[@tag='245'][1]/marc:subfield[@code='a'][1]"/>
              </xsl:call-template>
            </TitleText>
            <xsl:for-each select="marc:datafield[@tag='245'][1]/marc:subfield[@code='b'][1]">
              <Subtitle>
                <xsl:call-template name="ox-chomp">
                  <xsl:with-param name="s" select="."/>
                </xsl:call-template>
              </Subtitle>
            </xsl:for-each>
          </TitleElement>
        </TitleDetail>
        <xsl:for-each select="marc:datafield[@tag='100' or @tag='110' or @tag='111'
                              or @tag='700' or @tag='710' or @tag='711']">
          <Contributor>
            <SequenceNumber><xsl:value-of select="position()"/></SequenceNumber>
            <ContributorRole>
              <xsl:call-template name="ox-role">
                <xsl:with-param name="sf4" select="marc:subfield[@code='4'][1]"/>
                <xsl:with-param name="sfe" select="marc:subfield[@code='e'][1]"/>
                <xsl:with-param name="fallback">
                  <xsl:choose>
                    <xsl:when test="starts-with(@tag, '1')">A01</xsl:when>
                    <xsl:otherwise>Z99</xsl:otherwise>
                  </xsl:choose>
                </xsl:with-param>
              </xsl:call-template>
            </ContributorRole>
            <xsl:variable name="nm">
              <xsl:call-template name="ox-chomp">
                <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
              </xsl:call-template>
            </xsl:variable>
            <xsl:choose>
              <xsl:when test="@tag = '100' or @tag = '700'">
                <PersonNameInverted><xsl:value-of select="$nm"/></PersonNameInverted>
              </xsl:when>
              <xsl:otherwise>
                <CorporateName><xsl:value-of select="$nm"/></CorporateName>
              </xsl:otherwise>
            </xsl:choose>
          </Contributor>
        </xsl:for-each>
        <xsl:choose>
          <xsl:when test="marc:datafield[@tag='041']/marc:subfield[@code='a']">
            <xsl:for-each select="marc:datafield[@tag='041']/marc:subfield[@code='a']">
              <Language>
                <LanguageRole>01</LanguageRole>
                <LanguageCode><xsl:value-of select="normalize-space(.)"/></LanguageCode>
              </Language>
            </xsl:for-each>
          </xsl:when>
          <xsl:when test="string-length(normalize-space(substring($f008, 36, 3))) = 3
                          and substring($f008, 36, 3) != '|||'">
            <Language>
              <LanguageRole>01</LanguageRole>
              <LanguageCode><xsl:value-of select="substring($f008, 36, 3)"/></LanguageCode>
            </Language>
          </xsl:when>
        </xsl:choose>
        <!-- Extent: leading page count of 300 $a -->
        <xsl:variable name="ext"
            select="normalize-space(marc:datafield[@tag='300'][1]/marc:subfield[@code='a'][1])"/>
        <xsl:variable name="tok" select="substring-before(concat($ext, ' '), ' ')"/>
        <xsl:if test="$tok != '' and
                      string-length(translate($tok, '0123456789', '')) = 0 and
                      (contains($ext, 'page') or contains($ext, ' p.') or contains($ext, ' p'))">
          <Extent>
            <ExtentType>00</ExtentType>
            <ExtentValue><xsl:value-of select="$tok"/></ExtentValue>
            <ExtentUnit>03</ExtentUnit>
          </Extent>
        </xsl:if>
        <!-- Subjects -->
        <xsl:for-each select="marc:datafield[@tag='650'][@ind2='0']">
          <Subject>
            <SubjectSchemeIdentifier>04</SubjectSchemeIdentifier>
            <SubjectHeadingText>
              <xsl:for-each select="marc:subfield[contains('abxyzv', @code)]">
                <xsl:if test="position() &gt; 1">--</xsl:if>
                <xsl:call-template name="ox-chomp">
                  <xsl:with-param name="s" select="."/>
                </xsl:call-template>
              </xsl:for-each>
            </SubjectHeadingText>
          </Subject>
        </xsl:for-each>
        <xsl:for-each select="marc:datafield[@tag='082']">
          <Subject>
            <SubjectSchemeIdentifier>
              <xsl:choose>
                <xsl:when test="@ind1 = '1'">02</xsl:when>
                <xsl:otherwise>01</xsl:otherwise>
              </xsl:choose>
            </SubjectSchemeIdentifier>
            <xsl:for-each select="marc:subfield[@code='2'][1]">
              <SubjectSchemeVersion><xsl:value-of select="normalize-space(.)"/></SubjectSchemeVersion>
            </xsl:for-each>
            <SubjectCode>
              <xsl:call-template name="ox-chomp">
                <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
              </xsl:call-template>
            </SubjectCode>
          </Subject>
        </xsl:for-each>
        <xsl:for-each select="marc:datafield[@tag='050']">
          <Subject>
            <SubjectSchemeIdentifier>03</SubjectSchemeIdentifier>
            <SubjectCode>
              <xsl:call-template name="ox-chomp">
                <xsl:with-param name="s" select="marc:subfield[@code='a'][1]"/>
              </xsl:call-template>
            </SubjectCode>
          </Subject>
        </xsl:for-each>
      </DescriptiveDetail>

      <PublishingDetail>
        <xsl:variable name="imprint"
            select="(marc:datafield[@tag='264'][@ind2='1']
                     | marc:datafield[@tag='260'])[1]"/>
        <xsl:if test="$imprint/marc:subfield[@code='b']">
          <Publisher>
            <PublishingRole>01</PublishingRole>
            <PublisherName>
              <xsl:call-template name="ox-chomp">
                <xsl:with-param name="s" select="$imprint/marc:subfield[@code='b'][1]"/>
              </xsl:call-template>
            </PublisherName>
          </Publisher>
        </xsl:if>
        <xsl:for-each select="$imprint/marc:subfield[@code='a'][1]">
          <CityOfPublication>
            <xsl:call-template name="ox-chomp">
              <xsl:with-param name="s" select="."/>
            </xsl:call-template>
          </CityOfPublication>
        </xsl:for-each>
        <xsl:variable name="yr" select="substring($f008, 8, 4)"/>
        <xsl:if test="string-length(translate($yr, '0123456789', '')) = 0
                      and string-length($yr) = 4">
          <PublishingDate>
            <PublishingDateRole>01</PublishingDateRole>
            <Date dateformat="05"><xsl:value-of select="$yr"/></Date>
          </PublishingDate>
        </xsl:if>
      </PublishingDetail>
    </Product>
  </xsl:template>

  <xsl:template match="text()"/>

</xsl:stylesheet>
