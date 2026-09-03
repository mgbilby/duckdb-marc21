//! ISO 2709 serialisation.  UTF-8 or MARC-8 output; leader/00-04, 09 and
//! 12-16 recomputed from the actual encoded bytes — the same positions
//! marcref.encode_record overwrites.
//!
//! EncodeMarc8 emits Basic Latin + ANSEL (G1) only — no escape-designated
//! sets.  Text is decomposed to NFD, then each combining mark is written
//! BEFORE its base character (MARC-8 convention).  The spanning marks
//! U+0361/U+0360 split into their two ANSEL halves (EB/EC, FA/FB) around
//! the two letters they join.  Anything else becomes an LC-guidelines
//! numeric character reference "&#xHHHH;" (uppercase hex, no padding),
//! which Marc8Decode passes through literally; consumers un-NCR downstream.
//! Must agree with `unicode_to_marc8` in tools/marcref.py byte-for-byte.
#include "marc/core.hpp"
#include "marc/marc8_tables.hpp"
#include "marc/unicode_tables.hpp"

#include <algorithm>
#include <cstdio>
#include <unordered_map>

namespace marc {

static void AppendNum(std::string &out, size_t v, int width) {
	char buf[16];
	std::snprintf(buf, sizeof(buf), "%0*zu", width, v);
	out.append(buf);
}

// ---- NFD (decompose + canonical order, no recomposition) -------------------
// unicode_nfc.cpp keeps its helpers private, so the two small lookups are
// repeated here against the same generated tables.

static uint8_t Ccc(char32_t cp) {
	auto begin = std::begin(CCC_TABLE), end = std::end(CCC_TABLE);
	auto it = std::lower_bound(begin, end, cp, [](const CccEntry &e, char32_t v) { return e.cp < v; });
	return (it != end && it->cp == cp) ? it->ccc : 0;
}

static constexpr char32_t HANGUL_S_BASE = 0xAC00, HANGUL_L_BASE = 0x1100, HANGUL_V_BASE = 0x1161,
                          HANGUL_T_BASE = 0x11A7;
static constexpr int HANGUL_T_COUNT = 28, HANGUL_N_COUNT = 588, HANGUL_S_COUNT = 11172;

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
		out.append(it->seq, it->len);
	} else {
		out.push_back(cp);
	}
}

static std::u32string NfdNormalize(const std::u32string &input) {
	std::u32string s;
	s.reserve(input.size());
	for (char32_t cp : input) {
		Decompose(cp, s);
	}
	for (size_t i = 1; i < s.size(); i++) {
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
	return s;
}

// ---- UTF-8 → MARC-8 --------------------------------------------------------

struct Marc8Reverse {
	std::unordered_map<char32_t, uint8_t> spacing;   // ANSEL (G1)
	std::unordered_map<char32_t, uint8_t> combining; // ANSEL (G1)
	// Characters carried by a G0-designated set: (set designation, key).
	std::unordered_map<char32_t, std::pair<uint8_t, uint32_t>> alt;
	std::unordered_map<char32_t, std::pair<uint8_t, uint32_t>> alt_combining;
};

// G0 sets in lookup priority order; EACC last since it duplicates many
// characters the dedicated sets carry.  Must match _SET_ORDER in marcref.py.
static constexpr uint8_t SET_ORDER[] = {0x4E, 0x51, 0x32, 0x33, 0x34, 0x53, 0x62, 0x70, 0x67, 0x31};

static const Marc8Reverse &Reverse() {
	static const Marc8Reverse rev = [] {
		Marc8Reverse r;
		const Marc8Set *ansel = Marc8SetFor(0x45);
		for (unsigned i = 0; i < ansel->count; i++) {
			auto &e = ansel->entries[i];
			// Keys outside 21-7E would decode as invalid G1 bytes; skip.
			if (e.ucs == 0 || e.marc < 0x21 || e.marc > 0x7E) {
				continue;
			}
			auto &m = e.combining ? r.combining : r.spacing;
			m.emplace(e.ucs, static_cast<uint8_t>(e.marc | 0x80));
		}
		for (uint8_t iso : SET_ORDER) {
			const Marc8Set *set = Marc8SetFor(iso);
			for (unsigned i = 0; i < set->count; i++) {
				auto &e = set->entries[i];
				if (e.ucs == 0 || (!set->multibyte && (e.marc < 0x21 || e.marc > 0x7E))) {
					continue;
				}
				auto &m = e.combining ? r.alt_combining : r.alt;
				m.emplace(e.ucs, std::make_pair(iso, e.marc));
			}
		}
		return r;
	}();
	return rev;
}

// First half is in the combining table; the second half maps to nothing on
// decode, so only the encoder knows it.
static uint8_t SpanningSecondHalf(char32_t cp) {
	return cp == 0x0361 ? 0xEC : cp == 0x0360 ? 0xFB : 0;
}

std::string EncodeMarc8(std::string_view utf8) {
	const Marc8Reverse &rev = Reverse();
	std::u32string s = NfdNormalize(Utf8DecodeLossy(utf8));
	std::string out;
	out.reserve(s.size());
	uint8_t g0 = 0x42; // current G0 designation; ASCII by default

	auto designate = [&](uint8_t iso) {
		if (g0 == iso) {
			return;
		}
		if (iso == 0x31) {
			out.append("\x1b$1");
		} else {
			out.push_back(0x1B);
			out.push_back(0x28);
			out.push_back(static_cast<char>(iso));
		}
		g0 = iso;
	};
	auto emit_alt = [&](uint8_t iso, uint32_t key) {
		designate(iso);
		if (iso == 0x31) {
			out.push_back(static_cast<char>((key >> 16) & 0xFF));
			out.push_back(static_cast<char>((key >> 8) & 0xFF));
			out.push_back(static_cast<char>(key & 0xFF));
		} else {
			out.push_back(static_cast<char>(key));
		}
	};
	auto ncr = [&](char32_t cp) {
		designate(0x42);
		char buf[16];
		std::snprintf(buf, sizeof(buf), "&#x%X;", static_cast<unsigned>(cp));
		out.append(buf);
	};
	// 0 = ascii, 1 = ansel, 2 = alt, -1 = unrepresentable
	auto base_kind = [&](char32_t cp) -> int {
		if (cp < 0x80) {
			return 0;
		}
		if (rev.spacing.count(cp)) {
			return 1;
		}
		if (rev.alt.count(cp)) {
			return 2;
		}
		return -1;
	};
	// NFD splits Hangul syllables into L(+V)(+T) jamo, but EACC carries
	// precomposed syllables: recompose algorithmically for the lookup.
	auto hangul = [&](size_t i, char32_t &cp, size_t &consumed) {
		if (i + 1 >= s.size()) {
			return false;
		}
		char32_t L = s[i] - 0x1100, V = s[i + 1] - 0x1161;
		if (L >= 19 || V >= 21) {
			return false;
		}
		cp = 0xAC00 + (L * 21 + V) * 28;
		consumed = 2;
		if (i + 2 < s.size()) {
			char32_t T = s[i + 2] - 0x11A7;
			if (T > 0 && T < 28) {
				cp += T;
				consumed = 3;
			}
		}
		return true;
	};

	size_t i = 0, n = s.size();
	while (i < n && Ccc(s[i]) != 0) {
		ncr(s[i]); // mark with no base to precede: NCR keeps it in place
		i++;
	}
	uint8_t pending_second = 0; // EC/FB owed immediately before the next base's marks
	while (i < n) {
		char32_t syl;
		size_t consumed;
		if (hangul(i, syl, consumed) && rev.alt.count(syl)) {
			if (pending_second) {
				out.push_back(static_cast<char>(pending_second));
				pending_second = 0;
			}
			auto &hit = rev.alt.at(syl);
			emit_alt(hit.first, hit.second);
			i += consumed;
			continue;
		}
		size_t j = i + 1;
		while (j < n && Ccc(s[j]) != 0) {
			j++;
		}
		int kind = base_kind(s[i]);
		if (kind < 0) {
			// Unrepresentable base: NCR the whole cluster in NFD order so
			// no combining byte is left to attach to the '&' on decode.
			for (size_t k = i; k < j; k++) {
				ncr(s[k]);
			}
			i = j;
			continue;
		}
		if (pending_second) {
			out.push_back(static_cast<char>(pending_second));
			pending_second = 0;
		}
		bool next_base_ok = j < n && base_kind(s[j]) >= 0;
		std::u32string deferred;
		for (size_t k = i + 1; k < j; k++) {
			char32_t m = s[k];
			uint8_t second = SpanningSecondHalf(m);
			auto it = rev.combining.find(m);
			if (second) {
				if (next_base_ok) {
					out.push_back(static_cast<char>(it->second));
					pending_second = second;
				} else {
					deferred.push_back(m); // half a ligature is worse than an NCR
				}
			} else if (it != rev.combining.end()) {
				out.push_back(static_cast<char>(it->second));
			} else if (rev.alt_combining.count(m)) {
				auto &hit = rev.alt_combining.at(m);
				emit_alt(hit.first, hit.second);
			} else {
				deferred.push_back(m); // no byte form: NCR after the base
			}
		}
		if (kind == 0) {
			if (s[i] >= 0x21 && s[i] != 0x7F) {
				designate(0x42);
			}
			out.push_back(static_cast<char>(s[i]));
		} else if (kind == 1) {
			out.push_back(static_cast<char>(rev.spacing.at(s[i])));
		} else {
			auto &hit = rev.alt.at(s[i]);
			emit_alt(hit.first, hit.second);
		}
		for (char32_t m : deferred) {
			ncr(m);
		}
		i = j;
	}
	designate(0x42);
	if (out.size() == 3 && out.compare(0, 3, "\x1b(B") == 0) {
		return ""; // pure designation noise on empty input
	}
	return out;
}

// ---- ISO 2709 --------------------------------------------------------------

static std::string WriteRecordImpl(const Record &rec, bool marc8) {
	if (rec.leader.size() != 24) {
		throw MarcError("leader must be 24 characters");
	}
	auto enc = [&](const std::string &s) { return marc8 ? EncodeMarc8(s) : s; };
	std::string dir, body;
	for (auto &f : rec.fields) {
		if (f.tag.size() != 3) {
			throw MarcError("bad tag \"" + f.tag + "\"");
		}
		size_t start = body.size();
		if (f.is_control) {
			body.append(enc(f.control_value));
		} else {
			body.append(enc(f.ind1)).append(enc(f.ind2));
			for (auto &sf : f.subfields) {
				body.push_back(static_cast<char>(SF));
				body.append(enc(sf.code)).append(enc(sf.value));
			}
		}
		body.push_back(static_cast<char>(FT));
		size_t length = body.size() - start;
		if (length > 9999 || start > 99999) {
			throw MarcError("field " + f.tag + " too long for an ISO 2709 directory entry");
		}
		dir.append(f.tag);
		AppendNum(dir, length, 4);
		AppendNum(dir, start, 5);
	}
	dir.push_back(static_cast<char>(FT));

	size_t base = 24 + dir.size();
	size_t total = base + body.size() + 1;
	if (total > 99999) {
		throw MarcError("record longer than 99999 bytes");
	}

	std::string leader = rec.leader;
	std::string num;
	AppendNum(num, total, 5);
	leader.replace(0, 5, num);
	leader[9] = marc8 ? ' ' : 'a';
	num.clear();
	AppendNum(num, base, 5);
	leader.replace(12, 5, num);

	std::string out;
	out.reserve(total);
	out.append(leader).append(dir).append(body);
	out.push_back(static_cast<char>(RT));
	return out;
}

std::string WriteRecord(const Record &rec) {
	return WriteRecordImpl(rec, false);
}

std::string WriteRecordMarc8(const Record &rec) {
	return WriteRecordImpl(rec, true);
}

} // namespace marc
