//! Targeted linked-data URI write-back scalars (fields in, fields out —
//! compose in UPDATE/SELECT like the marc_edit_scalars.cpp family):
//!   marc_set_linked_uri(fields, tagpat, heading, uri, code)
//!       -> fields with $0 (code '0') or $1 (code '1') set to uri on every
//!          field matching tagpat whose marc_heading_join heading
//!          NACO-matches heading (in-place replace of an existing link,
//!          otherwise appended at the field's end); no match = no-op.
//!   marc_clear_linked_uris(fields, tagpat, code)
//!       -> fields with every $0 / $1 removed from the tags matching tagpat.
//! Tag patterns use '.' wildcards; an invalid pattern or a code other than
//! '0'/'1' is an error.  Semantics are pinned standalone by
//! test/cpp/authlink_test.cpp; the workflow is documented in docs/LINKING.md.

#include "marc21_extension.hpp"

#include "duckdb.hpp"
#include "duckdb/main/extension/extension_loader.hpp"

#include "marc/authlink.hpp"
#include "marc/core.hpp"

namespace duckdb {
namespace {

// Same shared helpers as marc_edit_scalars.cpp / marc_cluster_scalars.cpp
// (file-local there, so repeated here rather than widening their interface).

static Value FieldsArg(const Vector &v, idx_t i) {
	return const_cast<Vector &>(v).GetValue(i);
}

//! Wrap a fields-in/fields-out operation with shared NULL/error handling.
template <class OP>
static void FieldsOp(DataChunk &args, Vector &result, OP op) {
	for (idx_t i = 0; i < args.size(); i++) {
		auto fields = FieldsArg(args.data[0], i);
		if (fields.IsNull()) {
			result.SetValue(i, Value(result.GetType()));
			continue;
		}
		try {
			auto rec = MarcValuesToRecord(Value(LogicalType::VARCHAR), fields);
			result.SetValue(i, MarcFieldsToValue(op(rec, args, i)));
		} catch (marc::MarcError &e) {
			throw InvalidInputException("marc authlink: %s", e.what());
		}
	}
	if (args.AllConstant()) {
		result.SetVectorType(VectorType::CONSTANT_VECTOR);
	}
}

static string StrArg(DataChunk &args, idx_t col, idx_t row) {
	auto v = args.data[col].GetValue(row);
	return v.IsNull() ? "" : v.ToString();
}

//! The link subfield code argument: exactly one character, '0' or '1'
//! (the core re-validates the value; this catches the shape).
static char CodeArg(DataChunk &args, idx_t col, idx_t row, const char *fn) {
	auto s = StrArg(args, col, row);
	if (s.size() != 1) {
		throw InvalidInputException("%s: code must be '0' or '1'", fn);
	}
	return s[0];
}

static void SetLinkedUriExec(DataChunk &args, ExpressionState &, Vector &result) {
	FieldsOp(args, result, [](marc::Record &rec, DataChunk &a, idx_t i) {
		return marc::SetLinkedUri(rec, StrArg(a, 1, i), StrArg(a, 2, i), StrArg(a, 3, i),
		                          CodeArg(a, 4, i, "marc_set_linked_uri"));
	});
}

static void ClearLinkedUrisExec(DataChunk &args, ExpressionState &, Vector &result) {
	FieldsOp(args, result, [](marc::Record &rec, DataChunk &a, idx_t i) {
		return marc::ClearLinkedUris(rec, StrArg(a, 1, i), CodeArg(a, 2, i, "marc_clear_linked_uris"));
	});
}

} // namespace

void RegisterMarcAuthlinkScalars(ExtensionLoader &loader) {
	auto fields_type = LogicalType::LIST(MarcFieldStructType());
	auto V = LogicalType::VARCHAR;

	loader.RegisterFunction(
	    ScalarFunction("marc_set_linked_uri", {fields_type, V, V, V, V}, fields_type, SetLinkedUriExec));
	loader.RegisterFunction(
	    ScalarFunction("marc_clear_linked_uris", {fields_type, V, V}, fields_type, ClearLinkedUrisExec));
}

} // namespace duckdb
