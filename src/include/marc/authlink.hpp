//! Targeted linked-data URI write-back over the core record model: set or
//! clear $0 (authority record control number or standard number) / $1
//! (real-world-object URI) on the specific field occurrences whose heading
//! matched a reconciliation result.  Closes the loop that
//! src/macros/reconcile.sql opens (queue + candidate shapers): the caller
//! fetches candidates however it likes (httpfs/http_client — see
//! docs/LINKING.md) and writes the chosen URI back with these.
//! Deliberately DuckDB-free like core.hpp/edit.hpp; the orchestrator binds
//! these to SQL scalars later.  Inputs are never mutated.
#pragma once

#include "marc/core.hpp"

namespace marc {

// ---- authlink.cpp ----------------------------------------------------------

// Set subfield $0 (code = '0') or $1 (code = '1') to `uri` on every data
// field that (a) matches `tagpat` — exactly 3 characters of [0-9a-zA-Z.],
// '.' a per-position wildcard, validated like the editing tag patterns —
// and (b) whose joined heading NACO-matches `heading`.
//
// The joined heading mirrors the marc_heading_join SQL macro exactly: the
// values of the field's subfields whose code is a single letter a-z other
// than 'w' (so $w tracing controls and all numeric/control subfields $0-$9
// are excluded), joined with single spaces in field order.  Matching is
// NacoNormalize(joined) == NacoNormalize(heading) (idnorm.cpp), so
// diacritics, case, commas and terminal punctuation do not break the match.
// A heading that NACO-normalizes to "" matches nothing — an all-punctuation
// target must not link every all-punctuation field.
//
// On each matching field: when one or more subfields with that code already
// exist, the FIRST keeps its position and gets the new value and the rest
// are removed (a re-link replaces the old link in place); otherwise the new
// subfield is appended after the last existing subfield — the canonical
// spot for $0/$1, which cataloging practice puts at the field's end.  Every
// matching occurrence is set, so a repeated heading (say two identical 650s)
// gets the URI on each.  No match is not an error: the record comes back
// unchanged.  Control fields never match.
//
// Errors (MarcError): invalid tag pattern; `code` not '0' or '1'.
Record SetLinkedUri(const Record &rec, const std::string &tagpat, const std::string &heading,
                    const std::string &uri, char code);

// Remove EVERY $0 (code = '0') or $1 (code = '1') subfield from the data
// fields matching `tagpat` — the undo/rebuild half of SetLinkedUri.  A field
// is otherwise left intact even when the removed link was its only subfield
// content; other tags and control fields are untouched.  Same tag-pattern
// and code validation as SetLinkedUri.
Record ClearLinkedUris(const Record &rec, const std::string &tagpat, char code);

} // namespace marc
