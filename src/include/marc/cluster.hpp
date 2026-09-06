//! OpenRefine-style key-collision clustering keys, implemented from the
//! algorithm's published description (the "Clustering In Depth" write-up);
//! no external clustering code was consulted.  Deliberately DuckDB-free like
//! core.hpp; the orchestrator binds these to SQL scalars later.  Values that
//! produce the same key belong to the same cluster — the grouping itself is
//! a SQL GROUP BY (see src/macros/editing.sql: marc_cluster_headings).
#pragma once

#include "marc/core.hpp"

namespace marc {

// ---- cluster.cpp -----------------------------------------------------------

// Fingerprint key: trim, lowercase, strip punctuation and control
// characters, fold diacritics/specials to ASCII (via the NACO fold in
// idnorm.cpp), split into whitespace-separated tokens, sort and de-dupe the
// tokens, re-join with single spaces.  "" for an all-punctuation input.
// Documented deviations from OpenRefine's exact code are listed atop
// cluster.cpp.
std::string Fingerprint(std::string_view s);

// N-gram fingerprint key: the same normalization with ALL whitespace
// removed, then every n-gram of the remaining code points, sorted, de-duped
// and concatenated.  A cleaned string shorter than n is returned whole
// (deviation: OpenRefine yields "" there, colliding every short value).
// n must be >= 1 (MarcError otherwise); n = 2 is the usual choice.
std::string NgramFingerprint(std::string_view s, size_t n);

} // namespace marc
