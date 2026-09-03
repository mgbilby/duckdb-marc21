//! MARC-in-JSON, both directions.  Written from the community "MARC in JSON"
//! description (single object with "leader" string + "fields" array of
//! one-member objects; control fields carry a string, data fields an object
//! with "ind1"/"ind2"/"subfields", subfields again one-member objects) and
//! the FOLIO source-record-storage parsedRecord shape, which nests exactly
//! that structure under "content".
//!
//! Reader conventions, precisely:
//!   * Input may be one record object, an array of record objects, or a
//!     whitespace/newline-delimited sequence of values (NDJSON); any value in
//!     the sequence may itself be an array of record objects.
//!   * Envelope unwrapping runs per object, only while the object has no
//!     "fields" key: first {"parsedRecord": {...}} descends into that object,
//!     then {"content": {...}} descends into that one — covering both
//!     {"content": {...}} and {"parsedRecord": {"content": {...}}}.
//!   * A control tag (< "010") must carry a JSON string, a data tag an
//!     object — a mismatch is an error, keeping control-ness tag-derived
//!     exactly as in the record model (and marcref.Field.is_control).
//!     Anything else is an error too, as are field/subfield entries without
//!     exactly one member.
//!   * "leader" (a string, else treated as absent) is padded/truncated to 24
//!     code points; a missing leader becomes 24 spaces.
//!   * Missing/null "ind1"/"ind2" mean blank; indicators and subfield codes
//!     are cut to one Unicode scalar like the MARCXML reader; values are
//!     NFC-normalised.
//! Must agree with parse_marcjson/record_to_marcjson in tools/marcref.py.
#include "marc/formats.hpp"
#include "marc/json.hpp"

namespace marc {

namespace {

// One UTF-8 scalar (a space if empty), invalid bytes repaired.
std::string OneScalar(const std::string &s) {
	std::string fixed = Utf8Encode(Utf8DecodeLossy(s));
	if (fixed.empty()) {
		return " ";
	}
	size_t len = 1;
	uint8_t c = fixed[0];
	if (c >= 0xF0) {
		len = 4;
	} else if (c >= 0xE0) {
		len = 3;
	} else if (c >= 0xC0) {
		len = 2;
	}
	return fixed.substr(0, std::min(len, fixed.size()));
}

std::string Indicator(const JsonValue &field, std::string_view key, const std::string &tag) {
	const JsonValue *v = field.Get(key);
	if (!v || v->type == JsonValue::Type::NUL) {
		return " ";
	}
	if (v->type != JsonValue::Type::STR) {
		throw MarcError("marcjson: " + tag + "." + std::string(key) + " is not a string");
	}
	return OneScalar(v->str);
}

Record RecordFromObject(const JsonValue &outer) {
	const JsonValue *o = &outer;
	if (!o->Get("fields")) {
		const JsonValue *pr = o->Get("parsedRecord");
		if (pr && pr->type == JsonValue::Type::OBJ) {
			o = pr;
		}
	}
	if (!o->Get("fields")) {
		const JsonValue *content = o->Get("content");
		if (content && content->type == JsonValue::Type::OBJ) {
			o = content;
		}
	}

	Record rec;
	const JsonValue *leader = o->Get("leader");
	std::u32string ldr;
	if (leader && leader->type == JsonValue::Type::STR) {
		ldr = Utf8DecodeLossy(leader->str);
	}
	ldr.resize(24, U' ');
	rec.leader = Utf8Encode(ldr);

	const JsonValue *fields = o->Get("fields");
	if (!fields || fields->type != JsonValue::Type::ARR) {
		throw MarcError("marcjson: record has no \"fields\" array");
	}
	for (auto &entry : fields->arr) {
		if (entry.type != JsonValue::Type::OBJ || entry.obj.size() != 1) {
			throw MarcError("marcjson: field entry is not a one-member object");
		}
		const std::string &tag = entry.obj[0].first;
		const JsonValue &fv = entry.obj[0].second;
		Field f;
		f.tag = Utf8Encode(Utf8DecodeLossy(tag));
		if (fv.type == JsonValue::Type::STR) {
			if (!(f.tag < "010")) {
				throw MarcError("marcjson: field " + f.tag + " carries a string but is not a control tag");
			}
			f.is_control = true;
			f.control_value = NfcNormalizeUtf8(fv.str);
		} else if (fv.type == JsonValue::Type::OBJ) {
			if (f.tag < "010") {
				throw MarcError("marcjson: control field " + f.tag + " carries an object, not a string");
			}
			f.ind1 = Indicator(fv, "ind1", f.tag);
			f.ind2 = Indicator(fv, "ind2", f.tag);
			const JsonValue *subs = fv.Get("subfields");
			if (subs && subs->type != JsonValue::Type::NUL) {
				if (subs->type != JsonValue::Type::ARR) {
					throw MarcError("marcjson: " + f.tag + ".subfields is not an array");
				}
				for (auto &sub : subs->arr) {
					if (sub.type != JsonValue::Type::OBJ || sub.obj.size() != 1) {
						throw MarcError("marcjson: subfield entry in " + f.tag + " is not a one-member object");
					}
					if (sub.obj[0].second.type != JsonValue::Type::STR) {
						throw MarcError("marcjson: subfield value in " + f.tag + " is not a string");
					}
					Subfield sf;
					sf.code = OneScalar(sub.obj[0].first);
					sf.value = NfcNormalizeUtf8(sub.obj[0].second.str);
					f.subfields.push_back(std::move(sf));
				}
			}
		} else {
			throw MarcError("marcjson: field " + f.tag + " is neither a string nor an object");
		}
		rec.fields.push_back(std::move(f));
	}
	return rec;
}

void RecordsFromValue(const JsonValue &v, std::vector<Record> &out) {
	if (v.type == JsonValue::Type::ARR) {
		for (auto &item : v.arr) {
			if (item.type != JsonValue::Type::OBJ) {
				throw MarcError("marcjson: array element is not an object");
			}
			out.push_back(RecordFromObject(item));
		}
	} else if (v.type == JsonValue::Type::OBJ) {
		out.push_back(RecordFromObject(v));
	} else {
		throw MarcError("marcjson: top-level value is neither an object nor an array");
	}
}

bool IsWs(char c) {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

} // namespace

std::vector<Record> ParseMarcJson(std::string_view text) {
	std::vector<Record> records;
	size_t pos = 0;
	bool any = false;
	// A single leading value may be followed by more values (NDJSON); the
	// shared parser throws on any non-JSON trailing content.
	while (true) {
		while (pos < text.size() && IsWs(text[pos])) {
			pos++;
		}
		if (pos >= text.size()) {
			break;
		}
		JsonValue v = ParseJsonValueAt(text, pos, "marcjson");
		RecordsFromValue(v, records);
		any = true;
	}
	if (!any) {
		throw MarcError("marcjson: empty input");
	}
	return records;
}

std::string WriteMarcJson(const Record &rec) {
	std::string out = "{\"leader\":\"";
	out += EscapeJsonString(rec.leader);
	out += "\",\"fields\":[";
	bool first = true;
	for (auto &f : rec.fields) {
		if (!first) {
			out += ",";
		}
		first = false;
		out += "{\"";
		out += EscapeJsonString(f.tag);
		out += "\":";
		if (f.is_control) {
			out += "\"";
			out += EscapeJsonString(f.control_value);
			out += "\"";
		} else {
			out += "{\"ind1\":\"";
			out += EscapeJsonString(f.ind1);
			out += "\",\"ind2\":\"";
			out += EscapeJsonString(f.ind2);
			out += "\",\"subfields\":[";
			bool sf_first = true;
			for (auto &sf : f.subfields) {
				if (!sf_first) {
					out += ",";
				}
				sf_first = false;
				out += "{\"";
				out += EscapeJsonString(sf.code);
				out += "\":\"";
				out += EscapeJsonString(sf.value);
				out += "\"}";
			}
			out += "]}";
		}
		out += "}";
	}
	out += "]}";
	return out;
}

} // namespace marc
