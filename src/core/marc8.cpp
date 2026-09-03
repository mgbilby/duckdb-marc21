//! MARC-8 → Unicode with the full LC code tables (generated header).
//!
//! Implements the MARC-8 G0/G1 designation model: default G0 = Basic Latin,
//! G1 = ANSEL; escape sequences switch either half to any LC set, including
//! the three-byte EACC set.  MARC-8 puts combining marks BEFORE the base
//! character; marks are buffered and re-ordered, then the result is
//! NFC-normalised.  Never fails: unmappable bytes, truncated multibyte
//! sequences and unknown designations become U+FFFD.
//!
//! Must agree with `marc8_to_unicode` in tools/marcref.py.
#include "marc/core.hpp"
#include "marc/marc8_tables.hpp"

namespace marc {

static constexpr char32_t REPLACEMENT = 0xFFFD;
static const Marc8Set *ASCII_SET = Marc8SetFor(0x42);
static const Marc8Set *ANSEL_SET = Marc8SetFor(0x45);

static const Marc8Entry *Lookup(const Marc8Set &set, uint32_t key) {
	unsigned lo = 0, hi = set.count;
	while (lo < hi) {
		unsigned mid = (lo + hi) / 2;
		if (set.entries[mid].marc < key) {
			lo = mid + 1;
		} else {
			hi = mid;
		}
	}
	return (lo < set.count && set.entries[lo].marc == key) ? &set.entries[lo] : nullptr;
}

std::string Marc8Decode(std::string_view data) {
	std::u32string out;
	out.reserve(data.size());
	std::u32string pending; // combining marks waiting for their base
	const Marc8Set *g0 = ASCII_SET;
	const Marc8Set *g1 = ANSEL_SET;

	auto emit = [&](char32_t c, bool combining) {
		if (combining) {
			pending.push_back(c);
		} else {
			out.push_back(c);
			out.append(pending);
			pending.clear();
		}
	};

	size_t i = 0, n = data.size();
	while (i < n) {
		uint8_t b = data[i];

		if (b == 0x1B) {
			// Designation: ESC [I...] F, where the intermediates pick the
			// half (G0/G1) and byte width and F names the set.
			size_t j = i + 1;
			const Marc8Set **half = &g0;
			if (j < n && (data[j] == '(' || data[j] == ',')) {
				j++;
			} else if (j < n && (data[j] == ')' || data[j] == '-')) {
				half = &g1;
				j++;
			} else if (j < n && data[j] == '$') {
				j++;
				if (j < n && (data[j] == ')' || data[j] == '-')) {
					half = &g1;
					j++;
				} else if (j < n && data[j] == ',') {
					j++;
				}
			} else if (j < n && (data[j] == 'g' || data[j] == 'b' || data[j] == 'p' || data[j] == 's')) {
				// Single-character technique-1 escapes select a G0 set.
				g0 = data[j] == 's' ? ASCII_SET : Marc8SetFor(data[j]);
				i = j + 1;
				continue;
			} else {
				emit(REPLACEMENT, false);
				i = j < n ? j + 1 : n;
				continue;
			}
			const Marc8Set *set = j < n ? Marc8SetFor(static_cast<uint8_t>(data[j])) : nullptr;
			if (set) {
				*half = set;
			} else {
				emit(REPLACEMENT, false);
			}
			i = j < n ? j + 1 : n;
			continue;
		}

		if (b < 0x21 || b == 0x7F) {
			emit(b, false); // space and controls pass through
			i++;
			continue;
		}

		const Marc8Set *set = b < 0x80 ? g0 : g1;
		if (b >= 0x80 && (b < 0xA1 || b == 0xFF)) {
			emit(REPLACEMENT, false);
			i++;
			continue;
		}
		if (set->multibyte) {
			// EACC: three bytes per character, each masked to 7 bits.
			if (i + 2 < n) {
				uint32_t key = 0;
				bool valid = true;
				for (size_t k = 0; k < 3; k++) {
					uint8_t mb = data[i + k] & 0x7F;
					valid = valid && mb >= 0x21 && mb <= 0x7E;
					key = (key << 8) | mb;
				}
				auto entry = valid ? Lookup(*set, key) : nullptr;
				if (!entry || entry->ucs != 0) { // ucs 0 = LC "maps to nothing"
					emit(entry ? entry->ucs : REPLACEMENT, entry && entry->combining);
				}
				i += 3;
			} else {
				emit(REPLACEMENT, false);
				i = n;
			}
			continue;
		}
		if (set == ASCII_SET && b < 0x80) {
			emit(b, false); // Basic Latin is identity
			i++;
			continue;
		}
		auto entry = Lookup(*set, b & 0x7F);
		if (!entry || entry->ucs != 0) { // ucs 0 = LC "maps to nothing"
			emit(entry ? entry->ucs : REPLACEMENT, entry && entry->combining);
		}
		i++;
	}
	out.append(pending); // dangling diacritics at end of string are kept
	return Utf8Encode(NfcNormalize(std::move(out)));
}

} // namespace marc
