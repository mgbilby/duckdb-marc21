//! Schema validation (Avram) and record addressing (MARCspec) over the core
//! record model.  Deliberately DuckDB-free like core.hpp so both modules
//! compile and unit-test standalone; the exact subset of each published spec
//! is documented at the top of its implementation file.
#pragma once

#include "marc/core.hpp"

#include <map>

namespace marc {

// ---- avram.cpp -------------------------------------------------------------
struct AvramSubfield {
	bool repeatable = false;
	bool required = false;
};

struct AvramField {
	bool repeatable = false;
	bool required = false;
	// Enumerated indicator codes; std::nullopt means unconstrained.
	std::optional<std::vector<std::string>> ind1_codes, ind2_codes;
	// Subfield codes the schema lists; std::nullopt means any code is fine.
	std::optional<std::map<std::string, AvramSubfield>> subfields;
};

struct AvramSchema {
	std::map<std::string, AvramField> fields; // keyed by tag
};

// Parse an Avram schema (JSON text).  Throws MarcError on malformed JSON or
// on supported keys carrying the wrong type.
AvramSchema ParseAvramSchema(std::string_view json);

// Human-readable violations of `schema` by `rec`; empty = record passes.
std::vector<std::string> AvramValidate(const AvramSchema &schema, const Record &rec);

// ---- marcspec.cpp ----------------------------------------------------------
// Evaluate a MARCspec against one record: the referenced values in record
// order (empty = nothing matched).  Throws MarcError on invalid specs.
std::vector<std::string> MarcSpecEvaluate(const Record &rec, std::string_view spec);

} // namespace marc
