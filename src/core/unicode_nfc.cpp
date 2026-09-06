#include "marc/core.hpp"
#include "marc/unicode_nfc.hpp"
#include "marc/unicode_tables.hpp"

#include <algorithm>

namespace marc {

std::u32string Utf8DecodeLossy(std::string_view b) {
	std::u32string out;
	out.reserve(b.size());
	size_t i = 0, n = b.size();
	auto cont = [&](size_t j) { return j < n && (static_cast<uint8_t>(b[j]) & 0xC0) == 0x80; };
	while (i < n) {
		uint8_t c = b[i];
		if (c < 0x80) {
			out.push_back(c);
			i += 1;
		} else if ((c & 0xE0) == 0xC0 && cont(i + 1)) {
			char32_t cp = ((c & 0x1F) << 6) | (b[i + 1] & 0x3F);
			out.push_back(cp < 0x80 ? 0xFFFD : cp); // reject overlong
			i += 2;
		} else if ((c & 0xF0) == 0xE0 && cont(i + 1) && cont(i + 2)) {
			char32_t cp = ((c & 0x0F) << 12) | ((b[i + 1] & 0x3F) << 6) | (b[i + 2] & 0x3F);
			out.push_back(cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF) ? 0xFFFD : cp);
			i += 3;
		} else if ((c & 0xF8) == 0xF0 && cont(i + 1) && cont(i + 2) && cont(i + 3)) {
			char32_t cp = ((c & 0x07) << 18) | ((b[i + 1] & 0x3F) << 12) | ((b[i + 2] & 0x3F) << 6) | (b[i + 3] & 0x3F);
			out.push_back(cp < 0x10000 || cp > 0x10FFFF ? 0xFFFD : cp);
			i += 4;
		} else {
			out.push_back(0xFFFD);
			i += 1;
		}
	}
	return out;
}

std::string Utf8Encode(const std::u32string &cps) {
	std::string out;
	out.reserve(cps.size());
	for (char32_t cp : cps) {
		if (cp < 0x80) {
			out.push_back(static_cast<char>(cp));
		} else if (cp < 0x800) {
			out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
			out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
		} else if (cp < 0x10000) {
			out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
			out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
			out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
		} else {
			out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
			out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
			out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
			out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
		}
	}
	return out;
}

std::string Latin1ToUtf8(std::string_view bytes) {
	std::u32string cps;
	cps.reserve(bytes.size());
	for (unsigned char b : bytes) {
		cps.push_back(b);
	}
	return Utf8Encode(cps);
}

static uint8_t Ccc(char32_t cp) {
	auto begin = std::begin(CCC_TABLE), end = std::end(CCC_TABLE);
	auto it = std::lower_bound(begin, end, cp, [](const CccEntry &e, char32_t v) { return e.cp < v; });
	return (it != end && it->cp == cp) ? it->ccc : 0;
}

static bool Compose(char32_t a, char32_t b, char32_t &out) {
	auto begin = std::begin(COMP_TABLE), end = std::end(COMP_TABLE);
	auto it = std::lower_bound(begin, end, a, [](const CompEntry &e, char32_t v) { return e.first < v; });
	for (; it != end && it->first == a; ++it) {
		if (it->second == b) {
			out = it->composed;
			return true;
		}
	}
	return false;
}

// Hangul syllable composition constants (UAX #15).
static constexpr char32_t HANGUL_S_BASE = 0xAC00, HANGUL_L_BASE = 0x1100, HANGUL_V_BASE = 0x1161,
                          HANGUL_T_BASE = 0x11A7;
static constexpr int HANGUL_V_COUNT = 21, HANGUL_T_COUNT = 28, HANGUL_N_COUNT = 588, HANGUL_S_COUNT = 11172;

static void Decompose(char32_t cp, std::u32string &out) {
	if (cp >= HANGUL_S_BASE && cp < HANGUL_S_BASE + HANGUL_S_COUNT) {
		char32_t index = cp - HANGUL_S_BASE;
		out.push_back(HANGUL_L_BASE + index / HANGUL_N_COUNT);
		out.push_back(HANGUL_V_BASE + (index % HANGUL_N_COUNT) / HANGUL_T_COUNT);
		if (index % HANGUL_T_COUNT) {
			out.push_back(HANGUL_T_BASE + index % HANGUL_T_COUNT);
		}
		return;
	}
	auto begin = std::begin(DECOMP_TABLE), end = std::end(DECOMP_TABLE);
	auto it = std::lower_bound(begin, end, cp, [](const DecompEntry &e, char32_t v) { return e.cp < v; });
	if (it != end && it->cp == cp) {
		out.append(it->seq, it->len); // pre-expanded to full NFD at generation
	} else {
		out.push_back(cp);
	}
}

static bool HangulCompose(char32_t a, char32_t b, char32_t &out) {
	if (a >= HANGUL_L_BASE && a < HANGUL_L_BASE + 19 && b >= HANGUL_V_BASE && b < HANGUL_V_BASE + HANGUL_V_COUNT) {
		out = HANGUL_S_BASE + ((a - HANGUL_L_BASE) * HANGUL_V_COUNT + (b - HANGUL_V_BASE)) * HANGUL_T_COUNT;
		return true;
	}
	if (a >= HANGUL_S_BASE && a < HANGUL_S_BASE + HANGUL_S_COUNT && (a - HANGUL_S_BASE) % HANGUL_T_COUNT == 0 &&
	    b > HANGUL_T_BASE && b < HANGUL_T_BASE + HANGUL_T_COUNT) {
		out = a + (b - HANGUL_T_BASE);
		return true;
	}
	return false;
}

// Canonical ordering: stable-sort each run of non-starters by ccc.
static void CanonicalOrder(std::u32string &s) {
	size_t n = s.size();
	for (size_t i = 1; i < n; i++) {
		uint8_t cc = Ccc(s[i]);
		if (cc == 0) {
			continue;
		}
		size_t j = i;
		while (j > 0 && Ccc(s[j - 1]) > cc) {
			std::swap(s[j - 1], s[j]);
			j--;
		}
	}
}

// NFD is the first two NFC steps with no recomposition: full canonical
// decomposition (table sequences are pre-expanded, Hangul is algorithmic)
// followed by canonical ordering.
std::u32string NfdNormalize(std::u32string input) {
	std::u32string s;
	s.reserve(input.size());
	for (char32_t cp : input) {
		Decompose(cp, s);
	}
	CanonicalOrder(s);
	return s;
}

std::u32string NfcNormalize(std::u32string input) {
	// Canonical decomposition first: MARC-8 tables map to precomposed
	// characters, which must decompose before reordering can interleave
	// them correctly with marks decoded from separate bytes.
	std::u32string s = NfdNormalize(std::move(input));
	size_t n = s.size();
	// Canonical composition (UAX #15 algorithm).
	std::u32string out;
	out.reserve(n);
	size_t last_starter = std::u32string::npos;
	int last_cc = -1; // ccc of the last char appended after the starter
	for (char32_t cp : s) {
		uint8_t cc = Ccc(cp);
		if (last_starter != std::u32string::npos && last_cc < static_cast<int>(cc)) {
			char32_t composed;
			if (Compose(out[last_starter], cp, composed)) {
				out[last_starter] = composed;
				continue;
			}
		}
		if (cc == 0) {
			// Starter directly after a starter: table pairs and algorithmic
			// Hangul (L+V, LV+T) both compose.
			if (last_starter != std::u32string::npos && last_cc == -1) {
				char32_t composed;
				if (Compose(out[last_starter], cp, composed) || HangulCompose(out[last_starter], cp, composed)) {
					out[last_starter] = composed;
					continue;
				}
			}
			out.push_back(cp);
			last_starter = out.size() - 1;
			last_cc = -1;
		} else {
			out.push_back(cp);
			last_cc = cc;
		}
	}
	return out;
}

} // namespace marc
