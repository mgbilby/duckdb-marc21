//! A MARC record as DuckDB's VARIANT type:
//!   marc_variant(leader, fields)   -> VARIANT
//!   marc_variant_record(record)    -> VARIANT   (the STRUCT(leader, fields)
//!                                                marc_parse_json/marc_new_record return)
//!
//! Shape, and why it is this one:
//!
//!   { "leader": "00714cam a2200205 a 4500",
//!     "fields": [ {"tag": "001", "value": "ocm00000001"},
//!                 {"tag": "245", "ind1": "1", "ind2": "0",
//!                  "subfields": [ {"code": "a", "value": "Title /"},
//!                                 {"code": "c", "value": "by Someone."} ]} ] }
//!
//! The nested `fields` column is a LIST(STRUCT(tag, ind1, ind2, value,
//! subfields)) — one rectangle wide enough for every kind of field, so every
//! control field carries three NULL members it can never use and every data
//! field carries a NULL `value`.  VARIANT has no such floor: a control field
//! object simply has no `ind1`/`ind2`/`subfields` keys at all, and absent is
//! not the same as NULL, which is exactly the distinction MARC needs (an
//! indicator that is blank is ' ', an indicator that cannot exist is gone).
//! Shredding then hoists the keys that really are dense — `tag`, and on a
//! homogeneous slice the indicators — into typed columns, while the long tail
//! stays in the blob, which is where the compression win over LIST(STRUCT)
//! comes from.
//!
//! Two shapes were rejected.  Keying fields by tag ({"245": [...], "650":
//! [...]}) shreds even better but loses the record's field order, which is
//! semantic in MARC (880 linkage, repeated 6xx order as supplied).  Keying
//! subfields by code loses subfield order *within* a field, which is worse
//! still — $a$b$c is the title statement's word order.  Ordinality is data
//! here, so both levels stay arrays; only the per-field member set varies,
//! and that is the variation VARIANT is for.
//!
//! Object keys are emitted in lexicographic order at every level, which is
//! what the canonical VARIANT layout expects of an OBJECT's children.
//!
//! Construction is version-split.  v2.0 has VariantBuilder, which accumulates
//! the canonical layout for a whole chunk in one traversal.  v1.5.x predates
//! it and instead materializes a vector<VariantValue> tree per chunk and
//! converts that in one call — slower (an intermediate tree per row) but the
//! same result, so both builds register the same functions.

#include "marc21_extension.hpp"
#include "marc/compat.hpp"
#include "marc/variant.hpp"

#include "duckdb.hpp"
#include "duckdb/main/extension/extension_loader.hpp"

#include "marc/core.hpp"

#if MARC21_DUCKDB_V2
#include "duckdb/common/types/variant/variant_builder.hpp"
#else
#include "duckdb/common/types/variant_value.hpp"
#endif

#include <optional>

namespace duckdb {
namespace {

//! One input row: absent means the row is SQL NULL.
using MaybeRecord = std::optional<marc::Record>;

#if MARC21_DUCKDB_V2

// ---------------------------------------------------------------------------
// v2.0: emit straight into the chunk's VariantBuilder
// ---------------------------------------------------------------------------

static void EmitVarchar(VariantBuilder &builder, const std::string &value) {
	// EmitPrimitive wants the offset the payload will land at, which is
	// wherever the row's blob currently ends.
	builder.EmitPrimitive(Value(value), NumericCast<uint32_t>(builder.blob.size()));
}

static void EmitSubfield(VariantBuilder &builder, const marc::Subfield &subfield) {
	static const char *const keys[] = {"code", "value"};
	builder.EmitObject(
	    2, [](idx_t i) { return string_t(keys[i]); },
	    [&](idx_t i) { EmitVarchar(builder, i == 0 ? subfield.code : subfield.value); });
}

static void EmitField(VariantBuilder &builder, const marc::Field &field) {
	if (field.is_control) {
		static const char *const control_keys[] = {"tag", "value"};
		builder.EmitObject(
		    2, [](idx_t i) { return string_t(control_keys[i]); },
		    [&](idx_t i) { EmitVarchar(builder, i == 0 ? field.tag : field.control_value); });
		return;
	}
	static const char *const data_keys[] = {"ind1", "ind2", "subfields", "tag"};
	builder.EmitObject(
	    4, [](idx_t i) { return string_t(data_keys[i]); },
	    [&](idx_t i) {
		    switch (i) {
		    case 0:
			    EmitVarchar(builder, field.ind1);
			    break;
		    case 1:
			    EmitVarchar(builder, field.ind2);
			    break;
		    case 2:
			    builder.EmitArray(field.subfields.size(), [&](idx_t s) { EmitSubfield(builder, field.subfields[s]); });
			    break;
		    default:
			    EmitVarchar(builder, field.tag);
			    break;
		    }
	    });
}

static void EmitRecord(VariantBuilder &builder, const marc::Record &rec) {
	static const char *const keys[] = {"fields", "leader"};
	builder.EmitObject(
	    2, [](idx_t i) { return string_t(keys[i]); },
	    [&](idx_t i) {
		    if (i == 0) {
			    builder.EmitArray(rec.fields.size(), [&](idx_t f) { EmitField(builder, rec.fields[f]); });
		    } else {
			    EmitVarchar(builder, rec.leader);
		    }
	    });
}

//! BuildVariant's source concept: one Emit() per result row.
struct MarcVariantSource {
	explicit MarcVariantSource(const vector<MaybeRecord> &records) : records(records) {
	}

	bool Emit(idx_t row, VariantBuilder &builder) const {
		if (!records[row].has_value()) {
			return true;
		}
		EmitRecord(builder, *records[row]);
		return false;
	}

	const vector<MaybeRecord> &records;
};

#else

// ---------------------------------------------------------------------------
// v1.5.x: materialize a VariantValue tree, then convert the chunk in one call
// ---------------------------------------------------------------------------
//
// VariantBuilder does not exist here and the canonical layout is not something
// an extension should be hand-rolling, so the one construction path v1.5.x
// exposes is VariantValue + VariantValue::ToVARIANT (the same pair the engine
// itself uses to unshred a VARIANT column).  Object children are a
// map<string, VariantValue>, so the lexicographic key order the layout wants
// falls out of insertion rather than being arranged by hand.

static VariantValue SubfieldValue(const marc::Subfield &subfield) {
	VariantValue object(VariantValueType::OBJECT);
	object.AddChild("code", VariantValue(Value(subfield.code)));
	object.AddChild("value", VariantValue(Value(subfield.value)));
	return object;
}

static VariantValue FieldValue(const marc::Field &field) {
	VariantValue object(VariantValueType::OBJECT);
	object.AddChild("tag", VariantValue(Value(field.tag)));
	if (field.is_control) {
		object.AddChild("value", VariantValue(Value(field.control_value)));
		return object;
	}
	object.AddChild("ind1", VariantValue(Value(field.ind1)));
	object.AddChild("ind2", VariantValue(Value(field.ind2)));
	VariantValue subfields(VariantValueType::ARRAY);
	subfields.ReserveItems(field.subfields.size());
	for (auto &subfield : field.subfields) {
		subfields.AddItem(SubfieldValue(subfield));
	}
	object.AddChild("subfields", std::move(subfields));
	return object;
}

static VariantValue RecordValue(const marc::Record &rec) {
	VariantValue object(VariantValueType::OBJECT);
	VariantValue fields(VariantValueType::ARRAY);
	fields.ReserveItems(rec.fields.size());
	for (auto &field : rec.fields) {
		fields.AddItem(FieldValue(field));
	}
	object.AddChild("fields", std::move(fields));
	object.AddChild("leader", VariantValue(Value(rec.leader)));
	return object;
}

#endif

//! Write one chunk's worth of records into `result`, a flat VARIANT vector.
static void RecordsToVariant(const vector<MaybeRecord> &records, Vector &result) {
#if MARC21_DUCKDB_V2
	MarcVariantSource source(records);
	BuildVariant(source, records.size(), result);
#else
	vector<VariantValue> values;
	values.reserve(records.size());
	for (auto &rec : records) {
		// A default-constructed VariantValue is MISSING, which ToVARIANT
		// turns into a SQL NULL row.
		values.push_back(rec.has_value() ? RecordValue(*rec) : VariantValue());
	}
	VariantValue::ToVARIANT(values, result);
#endif
}

//! STRUCT(leader, fields) — the same shape marc_parse_json and marc_new_record
//! return, so marc_variant_record composes with them directly.
static const LogicalType &ParsedRecordType() {
	static const LogicalType type =
	    LogicalType::STRUCT({{"leader", LogicalType::VARCHAR}, {"fields", LogicalType::LIST(MarcFieldStructType())}});
	return type;
}

//! A NULL `fields` is the record not being there at all, so the row is NULL.
//! A NULL leader that still reaches here is read as an empty leader, which is
//! what MarcValuesToRecord does everywhere else in the extension -- though
//! with the default null handling these functions keep (the idiom the rest of
//! the marc_* scalars follow), a statically NULL argument is folded to NULL
//! before the row ever arrives.
static void VariantExec(DataChunk &args, ExpressionState &, Vector &result) {
	vector<MaybeRecord> records;
	records.reserve(args.size());
	for (idx_t i = 0; i < args.size(); i++) {
		auto fields = args.data[1].GetValue(i);
		if (fields.IsNull()) {
			records.emplace_back();
			continue;
		}
		records.emplace_back(MarcValuesToRecord(args.data[0].GetValue(i), fields));
	}
	RecordsToVariant(records, result);
}

static void VariantRecordExec(DataChunk &args, ExpressionState &, Vector &result) {
	vector<MaybeRecord> records;
	records.reserve(args.size());
	for (idx_t i = 0; i < args.size(); i++) {
		auto record = args.data[0].GetValue(i);
		if (record.IsNull()) {
			records.emplace_back();
			continue;
		}
		// ParsedRecordType fixes the member order, so index beats name lookup.
		auto &members = StructValue::GetChildren(record);
		records.emplace_back(MarcValuesToRecord(members[0], members[1]));
	}
	RecordsToVariant(records, result);
}

} // namespace

void RegisterMarcVariant(ExtensionLoader &loader) {
	auto fields_type = LogicalType::LIST(MarcFieldStructType());
	auto variant = LogicalType::VARIANT();

	MarcRegisterScalar(loader,ScalarFunction("marc_variant", {LogicalType::VARCHAR, fields_type}, variant, VariantExec));
	MarcRegisterScalar(loader,ScalarFunction("marc_variant_record", {ParsedRecordType()}, variant, VariantRecordExec));
}

} // namespace duckdb
