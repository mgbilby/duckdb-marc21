//! Identifier and heading normalization (see idnorm.hpp for the API).
//! Everything here is written from published descriptions of the rules —
//! the ISBN/ISSN check-digit definitions, LC's LCCN normalization write-up,
//! and the NACO Authority File Comparison Rule — with no external MARC
//! tooling code consulted.
//!
//! NacoNormalize implements this documented subset of the NACO rule:
//!   * canonical decomposition (full NFD via the generated UCD tables), then
//!     every code point with a nonzero canonical combining class is dropped
//!     — this strips all Latin/Greek/Cyrillic diacritics;
//!   * ASCII letters uppercase; the Latin specials that do not decompose
//!     fold as Æ/æ→AE, Œ/œ→OE, Ø/ø→O, Þ/þ→TH, Ð/ð/Đ/đ→D, Ł/ł→L, ß→SS,
//!     ı→I; modifier letters for ayn/alif (U+02BB/U+02BC/U+02BD) delete;
//!   * comma → space (the rule's famous special case); all other
//!     whitespace also → space;
//!   * ampersand and the musical sharp/flat (U+266F/U+266D) are retained;
//!     other punctuation and symbols delete — all non-alphanumeric ASCII,
//!     the Latin-1 punctuation/sign range, ×/÷, the General Punctuation
//!     block, and the arrow/math/miscellaneous-symbol blocks;
//!   * digits are kept; spaces collapse to single blanks and are trimmed.
//! Deliberate simplifications, chosen for determinism over exhaustiveness:
//! no superscript/subscript-to-digit conversion, no case folding outside
//! ASCII plus the listed specials (Greek/Cyrillic letters pass through
//! unchanged), and no subfield-delimiter handling (input is plain text).
#include "marc/idnorm.hpp"
#include "marc/unicode_tables.hpp"

#include <algorithm>

namespace marc {

namespace {

bool IsDigit(char c) {
	return c >= '0' && c <= '9';
}

char Lower(char c) {
	return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
}

std::string_view Trim(std::string_view s) {
	while (!s.empty() && (s.front() == ' ' || s.front() == '\t')) {
		s.remove_prefix(1);
	}
	while (!s.empty() && (s.back() == ' ' || s.back() == '\t')) {
		s.remove_suffix(1);
	}
	return s;
}

bool SkipPrefixCi(std::string_view &s, std::string_view prefix) {
	if (s.size() < prefix.size()) {
		return false;
	}
	for (size_t i = 0; i < prefix.size(); i++) {
		if (Lower(s[i]) != Lower(prefix[i])) {
			return false;
		}
	}
	s.remove_prefix(prefix.size());
	return true;
}

// Digits (and 'X' as 10) up to the first character that is neither a digit,
// x/X, hyphen nor space — trailing qualifiers like "(pbk.)" fall off here.
std::string CollectIsbnIssnChars(std::string_view s) {
	std::string out;
	for (char c : s) {
		if (IsDigit(c)) {
			out.push_back(c);
		} else if (c == 'x' || c == 'X') {
			out.push_back('X');
		} else if (c != '-' && c != ' ') {
			break;
		}
	}
	return out;
}

// ISBN-10: sum of digit[i] * (10 - i) divisible by 11, 'X' = 10 last only.
bool Isbn10Valid(const std::string &d) {
	int sum = 0;
	for (int i = 0; i < 10; i++) {
		int v;
		if (d[i] == 'X') {
			if (i != 9) {
				return false;
			}
			v = 10;
		} else {
			v = d[i] - '0';
		}
		sum += v * (10 - i);
	}
	return sum % 11 == 0;
}

// EAN-13: weights alternate 1,3 over the first 12 digits.
int Isbn13CheckDigit(const std::string &d12) {
	int sum = 0;
	for (int i = 0; i < 12; i++) {
		sum += (d12[i] - '0') * (i % 2 == 0 ? 1 : 3);
	}
	return (10 - sum % 10) % 10;
}

} // namespace

std::string NormalizeIsbn(std::string_view s) {
	s = Trim(s);
	if (SkipPrefixCi(s, "isbn")) {
		if (!SkipPrefixCi(s, "-13")) {
			SkipPrefixCi(s, "-10");
		}
		SkipPrefixCi(s, ":");
		s = Trim(s);
	}
	std::string d = CollectIsbnIssnChars(s);
	if (d.size() == 10) {
		if (!Isbn10Valid(d)) {
			return "";
		}
		std::string d12 = "978" + d.substr(0, 9);
		return d12 + static_cast<char>('0' + Isbn13CheckDigit(d12));
	}
	if (d.size() == 13) {
		if (d.find('X') != std::string::npos) {
			return "";
		}
		if (Isbn13CheckDigit(d.substr(0, 12)) != d[12] - '0') {
			return "";
		}
		return d;
	}
	return "";
}

bool IsbnIsValid(std::string_view s) {
	return !NormalizeIsbn(s).empty();
}

std::string NormalizeIssn(std::string_view s) {
	s = Trim(s);
	if (SkipPrefixCi(s, "issn")) {
		SkipPrefixCi(s, ":");
		s = Trim(s);
	}
	std::string d = CollectIsbnIssnChars(s);
	if (d.size() != 8) {
		return "";
	}
	// Weights 8..2 over the first seven digits; check = (11 - sum mod 11)
	// mod 11, 'X' meaning 10.  Equivalently the full weighted sum is 0.
	int sum = 0;
	for (int i = 0; i < 8; i++) {
		int v;
		if (d[i] == 'X') {
			if (i != 7) {
				return "";
			}
			v = 10;
		} else {
			v = d[i] - '0';
		}
		sum += v * (8 - i);
	}
	if (sum % 11 != 0) {
		return "";
	}
	return d.substr(0, 4) + "-" + d.substr(4);
}

std::string NormalizeLccn(std::string_view s) {
	std::string t;
	for (char c : s) {
		if (c != ' ' && c != '\t') {
			t.push_back(Lower(c));
		}
	}
	size_t slash = t.find('/');
	if (slash != std::string::npos) {
		t.resize(slash);
	}
	size_t hyphen = t.find('-');
	if (hyphen != std::string::npos) {
		std::string left = t.substr(0, hyphen);
		std::string right = t.substr(hyphen + 1);
		while (right.size() < 6) {
			right.insert(right.begin(), '0');
		}
		t = left + right;
	}
	if (t.empty()) {
		return "";
	}
	for (char c : t) {
		if (!IsDigit(c) && !(c >= 'a' && c <= 'z')) {
			return "";
		}
	}
	return t;
}

std::string NormalizeOclc(std::string_view s) {
	s = Trim(s);
	SkipPrefixCi(s, "(ocolc)");
	s = Trim(s);
	if (!SkipPrefixCi(s, "ocm") && !SkipPrefixCi(s, "ocn")) {
		SkipPrefixCi(s, "on");
	}
	s = Trim(s);
	while (!s.empty() && s.front() == '0') {
		s.remove_prefix(1);
	}
	if (s.empty()) {
		return "";
	}
	for (char c : s) {
		if (!IsDigit(c)) {
			return "";
		}
	}
	return std::string(s);
}

namespace {

uint8_t CccOf(char32_t cp) {
	auto begin = std::begin(CCC_TABLE), end = std::end(CCC_TABLE);
	auto it = std::lower_bound(begin, end, cp, [](const CccEntry &e, char32_t v) { return e.cp < v; });
	return (it != end && it->cp == cp) ? it->ccc : 0;
}

void DecomposeNfd(char32_t cp, std::u32string &out) {
	// Hangul is left composed: NACO keys never depend on jamo, and the
	// filter below only needs combining marks separated from Latin bases.
	auto begin = std::begin(DECOMP_TABLE), end = std::end(DECOMP_TABLE);
	auto it = std::lower_bound(begin, end, cp, [](const DecompEntry &e, char32_t v) { return e.cp < v; });
	if (it != end && it->cp == cp) {
		out.append(it->seq, it->len); // pre-expanded to full NFD at generation
	} else {
		out.push_back(cp);
	}
}

// The Latin specials the NACO rule folds and NFD cannot decompose.
const char *FoldSpecial(char32_t cp) {
	switch (cp) {
	case 0x00C6: // Æ
	case 0x00E6: // æ
		return "AE";
	case 0x0152: // Œ
	case 0x0153: // œ
		return "OE";
	case 0x00D8: // Ø
	case 0x00F8: // ø
		return "O";
	case 0x00DE: // Þ
	case 0x00FE: // þ
		return "TH";
	case 0x00D0: // Ð
	case 0x00F0: // ð
	case 0x0110: // Đ
	case 0x0111: // đ
		return "D";
	case 0x0141: // Ł
	case 0x0142: // ł
		return "L";
	case 0x00DF: // ß
		return "SS";
	case 0x0131: // ı
		return "I";
	default:
		return nullptr;
	}
}

bool IsNacoDeletedModifier(char32_t cp) {
	return cp == 0x02BB || cp == 0x02BC || cp == 0x02BD; // ʻ ʼ ʽ (ayn/alif)
}

bool IsUnicodeSpace(char32_t cp) {
	return cp == U' ' || cp == U'\t' || cp == U'\n' || cp == U'\r' || cp == 0x0C || cp == 0x0B || cp == 0x00A0 ||
	       (cp >= 0x2000 && cp <= 0x200B) || cp == 0x3000;
}

// Punctuation and symbol blocks that delete; kept exceptions (& ♭ ♯) are
// handled by the caller before this test.
bool IsDeletedPunct(char32_t cp) {
	if (cp < 0x80) {
		bool alnum = (cp >= U'0' && cp <= U'9') || (cp >= U'A' && cp <= U'Z') || (cp >= U'a' && cp <= U'z');
		return !alnum;
	}
	return (cp >= 0x00A0 && cp <= 0x00BF) || cp == 0x00D7 || cp == 0x00F7 || (cp >= 0x2010 && cp <= 0x205E) ||
	       (cp >= 0x2190 && cp <= 0x2BFF);
}

} // namespace

std::string NacoNormalize(std::string_view s) {
	std::u32string nfd;
	for (char32_t cp : Utf8DecodeLossy(s)) {
		DecomposeNfd(cp, nfd);
	}
	std::u32string out;
	out.reserve(nfd.size());
	bool pending_space = false;
	auto put = [&](char32_t cp) {
		if (pending_space && !out.empty()) {
			out.push_back(U' ');
		}
		pending_space = false;
		out.push_back(cp);
	};
	for (char32_t cp : nfd) {
		if (CccOf(cp) != 0) {
			continue; // diacritic stripped
		}
		if (cp == U',' || IsUnicodeSpace(cp)) {
			pending_space = true;
			continue;
		}
		if (cp >= U'a' && cp <= U'z') {
			put(cp - U'a' + U'A');
			continue;
		}
		if (const char *fold = FoldSpecial(cp)) {
			for (const char *p = fold; *p; p++) {
				put(static_cast<char32_t>(*p));
			}
			continue;
		}
		if (cp == U'&' || cp == 0x266D || cp == 0x266F) {
			put(cp);
			continue;
		}
		if (IsNacoDeletedModifier(cp) || IsDeletedPunct(cp)) {
			continue;
		}
		put(cp); // digits, ASCII uppercase, other scripts' letters
	}
	return Utf8Encode(out);
}

std::string MatchKey(const Record &rec) {
	std::string title;
	for (auto &f : rec.fields) {
		if (f.tag != "245" || f.is_control) {
			continue;
		}
		for (auto &sf : f.subfields) {
			if (sf.code == "a" || sf.code == "b") {
				if (!title.empty()) {
					title += " ";
				}
				title += sf.value;
			}
		}
		break;
	}
	std::u32string tkey = Utf8DecodeLossy(NacoNormalize(title));
	if (tkey.size() > 40) {
		tkey.resize(40);
	}

	std::string isbn;
	for (auto &f : rec.fields) {
		if (f.tag != "020" || f.is_control) {
			continue;
		}
		for (auto &sf : f.subfields) {
			if (sf.code == "a") {
				isbn = NormalizeIsbn(sf.value);
				if (!isbn.empty()) {
					break;
				}
			}
		}
		if (!isbn.empty()) {
			break;
		}
	}

	std::string year;
	for (auto &f : rec.fields) {
		if ((f.tag != "260" && f.tag != "264") || f.is_control) {
			continue;
		}
		for (auto &sf : f.subfields) {
			if (sf.code != "c") {
				continue;
			}
			size_t run = 0;
			for (size_t i = 0; i <= sf.value.size(); i++) {
				if (i < sf.value.size() && IsDigit(sf.value[i])) {
					run++;
					if (run == 4) {
						year = sf.value.substr(i - 3, 4);
						break;
					}
				} else {
					run = 0;
				}
			}
			if (!year.empty()) {
				break;
			}
		}
		if (!year.empty()) {
			break;
		}
	}

	std::string tpart = Utf8Encode(tkey);
	if (tpart.empty() && isbn.empty() && year.empty()) {
		return "";
	}
	return tpart + "|" + isbn + "|" + year;
}

} // namespace marc
