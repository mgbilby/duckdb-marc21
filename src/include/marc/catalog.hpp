//! Cataloging workflow helpers over the core record model: best-record
//! ranking for copy cataloging, material-type templates, and RDA cleanup
//! (abbreviation expansion, 336/337/338 generation).  Deliberately
//! DuckDB-free like core.hpp/edit.hpp; the orchestrator binds these to SQL
//! later.  Everything is implemented from the published MARC 21
//! bibliographic documentation and the RDA/MARC term-and-code lists — no
//! external MARC tooling code consulted.  Inputs are never mutated.
#pragma once

#include "marc/core.hpp"

namespace marc {

// ---- catalog.cpp -----------------------------------------------------------

// Copy-cataloging "pick the best master" score.  `encoding_level_rank`
// reflects Leader/17 alone and `completeness` weighted field presence (both
// 0-100; the two tables are documented at the top of catalog.cpp).
//   total = (6 * encoding_level_rank + 4 * completeness) / 10
// — a 60/40 blend in integer arithmetic, so total is also 0-100 and a record
// only outranks another by being better coded, fuller, or both.
struct RecordRank {
	int encoding_level_rank;
	int completeness;
	int total;
};

RecordRank RankRecord(const Record &rec);

// Skeleton record for a material type: "book", "serial", "video", "map",
// "music" (a notated-music score), "electronic" or "authority".  The
// bibliographic materials set Leader/06-07 for the material, an
// all-materials-layout 008 (dates unknown, place "xx ", language uncoded —
// layout documented in catalog.cpp) and an empty 245 with blank indicators
// and an empty $a; "authority" sets Leader/06 'z' with the authority-format
// 008 layout (kind-of-record 'a', level of establishment 'd' preliminary —
// full layout at NewAuthorityRecord in catalog.cpp) and an empty 100 $a
// placeholder heading instead of the 245.  Every skeleton round-trips
// through WriteRecord/ParseRecord before the caller fills it in.  An
// unknown name throws MarcError listing the valid ones.
Record NewRecord(std::string_view material);

// Expand the classic AACR2 physical-description abbreviations to their RDA
// spelled-out forms in 250 $a and every 300 subfield ONLY (documented list
// in catalog.cpp: p., v., ill., col., facsim(s)., port(s)., ed.).
// Word-boundary aware and conservative: lowercase forms only, never inside
// a word, never when a letter or digit follows the period, and no other
// field is touched ("cm" is a metric symbol and stays; carrier terms like
// "sound disc" are not abbreviations and stay).
Record RdaExpandAbbreviations(const Record &rec);

// Add the RDA content/media/carrier fields the record lacks — 336/337/338
// with blank indicators, $a term, $b code, $2 rdacontent/rdamedia/
// rdacarrier — derived from Leader/06, the first 007/00-01, 008/26 for
// computer files, and the 006 fields when the leader alone is ambiguous
// (mapping tables at the top of catalog.cpp).  006/00 supplies the content
// term when Leader/06 maps to nothing; 007/00 'f' (tactile) and 'g'
// (projected graphic) refine text and moving-image leaders to tactile
// text and still image; 007/01 picks the specific carrier (videocassette
// vs videodisc, audiocassette vs audio disc, ...).  A tag already present
// is left untouched, and a slot the mapping cannot determine is skipped
// rather than guessed.  New fields are inserted in tag order.
Record Generate33X(const Record &rec);

} // namespace marc
