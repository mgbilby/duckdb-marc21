//! Companion header for src/core/unicode_nfc.cpp: the NFD entry points.
//! (The NFC surface stays declared in marc/core.hpp, where every reader
//! already finds it; NFD is opt-in — nothing in the readers calls it.)
//!
//! NFD = canonical decomposition + canonical ordering, i.e. the NFC pipeline
//! without the recomposition pass, over the same generated UCD tables —
//! equivalent to unicodedata.normalize("NFD", s) for the sequences we
//! produce.  Intended for writers targeting ILSes that historically prefer
//! decomposed records (see docs/deltas/nfd-binding.md).
#pragma once

#include "marc/core.hpp"

namespace marc {

// Canonical decomposition (table sequences pre-expanded to full NFD, Hangul
// algorithmic per UAX #15) followed by canonical ordering of non-starters.
std::u32string NfdNormalize(std::u32string s);

// UTF-8 convenience, lossy-decoding invalid sequences to U+FFFD like
// NfcNormalizeUtf8.
inline std::string NfdNormalizeUtf8(std::string_view s) {
	return Utf8Encode(NfdNormalize(Utf8DecodeLossy(s)));
}

} // namespace marc
