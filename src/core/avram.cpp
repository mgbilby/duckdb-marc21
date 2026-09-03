//! Avram schema support (format.gbv.de/schema/avram/specification), written
//! from the published spec.  The subset implemented:
//!
//!   * top-level "fields" object keyed by tag, matched literally against
//!     record tags (no tag wildcards or ranges);
//!   * per field: "repeatable" (bool, default false), "required" (bool,
//!     default false), "indicator1"/"indicator2" as null or an object whose
//!     "codes" object keys enumerate the allowed values, and "subfields"
//!     keyed by code with per-subfield "repeatable"/"required";
//!   * every other key is ignored — Avram is extensible by design.
//!
//! Validation reports: required field missing, non-repeatable field repeated,
//! indicator value outside the enumerated codes, required subfield missing,
//! non-repeatable subfield repeated, and a subfield code absent from a field's
//! "subfields" object.  Tags absent from "fields" are NOT reported: Avram
//! schemas are typically non-closed, describing known fields without claiming
//! to be exhaustive.  Indicator and subfield checks apply to data fields only.
//!
//! JSON parsing lives in the shared reader (json.hpp), which keeps the exact
//! strictness this file originally had: full RFC 8259 value syntax (escapes
//! and surrogate pairs included), rejecting malformed input with MarcError;
//! numeric values are validated but never read by this subset.
#include "marc/json.hpp"
#include "marc/query.hpp"

namespace marc {

namespace {

bool GetBool(const JsonValue &obj, std::string_view key, const std::string &where) {
	const JsonValue *v = obj.Get(key);
	if (!v || v->type == JsonValue::Type::NUL) {
		return false;
	}
	if (v->type != JsonValue::Type::BOOL) {
		throw MarcError("avram: " + where + "." + std::string(key) + " is not a boolean");
	}
	return v->boolean;
}

std::optional<std::vector<std::string>> IndicatorCodes(const JsonValue &field, std::string_view key,
                                                       const std::string &tag) {
	const JsonValue *ind = field.Get(key);
	if (!ind || ind->type == JsonValue::Type::NUL) {
		return std::nullopt;
	}
	if (ind->type != JsonValue::Type::OBJ) {
		throw MarcError("avram: " + tag + "." + std::string(key) + " is not an object or null");
	}
	const JsonValue *codes = ind->Get("codes");
	if (!codes || codes->type == JsonValue::Type::NUL) {
		return std::nullopt;
	}
	if (codes->type != JsonValue::Type::OBJ) {
		throw MarcError("avram: " + tag + "." + std::string(key) + ".codes is not an object");
	}
	std::vector<std::string> out;
	for (auto &kv : codes->obj) {
		out.push_back(kv.first);
	}
	return out;
}

std::string JoinCodes(const std::vector<std::string> &codes) {
	std::string out = "[";
	for (size_t i = 0; i < codes.size(); i++) {
		if (i > 0) {
			out += ",";
		}
		out += codes[i];
	}
	out += "]";
	return out;
}

void CheckIndicator(const std::string &tag, const char *name, const std::string &value,
                    const std::optional<std::vector<std::string>> &codes, std::vector<std::string> &out) {
	if (!codes) {
		return;
	}
	for (auto &code : *codes) {
		if (code == value) {
			return;
		}
	}
	out.push_back(tag + " " + name + ": '" + value + "' not one of " + JoinCodes(*codes));
}

} // namespace

AvramSchema ParseAvramSchema(std::string_view json) {
	JsonValue root = ParseJson(json, "avram");
	if (root.type != JsonValue::Type::OBJ) {
		throw MarcError("avram: top-level value is not an object");
	}
	const JsonValue *fields = root.Get("fields");
	if (!fields || fields->type != JsonValue::Type::OBJ) {
		throw MarcError("avram: schema has no \"fields\" object");
	}
	AvramSchema schema;
	for (auto &[tag, fv] : fields->obj) {
		if (fv.type != JsonValue::Type::OBJ) {
			throw MarcError("avram: field \"" + tag + "\" is not an object");
		}
		AvramField def;
		def.repeatable = GetBool(fv, "repeatable", tag);
		def.required = GetBool(fv, "required", tag);
		def.ind1_codes = IndicatorCodes(fv, "indicator1", tag);
		def.ind2_codes = IndicatorCodes(fv, "indicator2", tag);
		const JsonValue *subs = fv.Get("subfields");
		if (subs && subs->type != JsonValue::Type::NUL) {
			if (subs->type != JsonValue::Type::OBJ) {
				throw MarcError("avram: " + tag + ".subfields is not an object");
			}
			def.subfields.emplace();
			for (auto &[code, sv] : subs->obj) {
				if (sv.type != JsonValue::Type::OBJ) {
					throw MarcError("avram: subfield \"" + tag + "$" + code + "\" is not an object");
				}
				AvramSubfield sub;
				sub.repeatable = GetBool(sv, "repeatable", tag + "$" + code);
				sub.required = GetBool(sv, "required", tag + "$" + code);
				(*def.subfields)[code] = sub;
			}
		}
		schema.fields[tag] = std::move(def);
	}
	return schema;
}

std::vector<std::string> AvramValidate(const AvramSchema &schema, const Record &rec) {
	std::vector<std::string> out;

	std::map<std::string, size_t> counts;
	for (auto &f : rec.fields) {
		counts[f.tag]++;
	}
	for (auto &[tag, def] : schema.fields) {
		auto it = counts.find(tag);
		size_t n = it == counts.end() ? 0 : it->second;
		if (def.required && n == 0) {
			out.push_back(tag + ": required field missing");
		}
		if (!def.repeatable && n > 1) {
			out.push_back(tag + ": non-repeatable field occurs " + std::to_string(n) + " times");
		}
	}

	for (auto &f : rec.fields) {
		auto it = schema.fields.find(f.tag);
		if (it == schema.fields.end() || f.is_control) {
			continue;
		}
		const AvramField &def = it->second;
		CheckIndicator(f.tag, "ind1", f.ind1, def.ind1_codes, out);
		CheckIndicator(f.tag, "ind2", f.ind2, def.ind2_codes, out);
		if (!def.subfields) {
			continue;
		}
		std::map<std::string, size_t> sub_counts;
		for (auto &sf : f.subfields) {
			sub_counts[sf.code]++;
		}
		for (auto &[code, n] : sub_counts) {
			auto sit = def.subfields->find(code);
			if (sit == def.subfields->end()) {
				out.push_back(f.tag + "$" + code + ": not in schema");
			} else if (!sit->second.repeatable && n > 1) {
				out.push_back(f.tag + "$" + code + ": non-repeatable subfield occurs " + std::to_string(n) +
				              " times");
			}
		}
		for (auto &[code, sub] : *def.subfields) {
			if (sub.required && sub_counts.find(code) == sub_counts.end()) {
				out.push_back(f.tag + "$" + code + ": required subfield missing");
			}
		}
	}
	return out;
}

} // namespace marc
