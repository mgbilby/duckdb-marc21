//! MARCXML slim-schema reader: a deliberately small parser accepting exactly
//! the shapes http://www.loc.gov/MARC21/slim produces (namespace prefixes
//! stripped; the five predefined entities plus numeric character references;
//! comments/PIs/unknown elements skipped).  Values are NFC-normalised.
#include "marc/core.hpp"

namespace marc {

static void AppendCp(std::string &out, char32_t cp) {
	std::u32string one(1, cp);
	out.append(Utf8Encode(one));
}

static std::string DecodeEntities(std::string_view s) {
	if (s.find('&') == std::string_view::npos) {
		return std::string(s);
	}
	std::string out;
	out.reserve(s.size());
	size_t i = 0;
	while (i < s.size()) {
		if (s[i] != '&') {
			out.push_back(s[i++]);
			continue;
		}
		size_t end = s.find(';', i);
		if (end == std::string_view::npos) {
			out.append(s.substr(i));
			return out;
		}
		std::string_view ent = s.substr(i + 1, end - i - 1);
		if (ent == "amp") {
			out.push_back('&');
		} else if (ent == "lt") {
			out.push_back('<');
		} else if (ent == "gt") {
			out.push_back('>');
		} else if (ent == "quot") {
			out.push_back('"');
		} else if (ent == "apos") {
			out.push_back('\'');
		} else if (ent.size() > 1 && ent[0] == '#') {
			bool hex = ent[1] == 'x' || ent[1] == 'X';
			char32_t cp = 0;
			// Length cap prevents char32_t wrap-around on absurd references.
			bool ok = ent.size() > (hex ? 2u : 1u) && ent.size() <= 9;
			for (size_t k = hex ? 2 : 1; ok && k < ent.size(); k++) {
				char c = ent[k];
				int d;
				if (c >= '0' && c <= '9') {
					d = c - '0';
				} else if (hex && c >= 'a' && c <= 'f') {
					d = c - 'a' + 10;
				} else if (hex && c >= 'A' && c <= 'F') {
					d = c - 'A' + 10;
				} else {
					ok = false;
					break;
				}
				cp = cp * (hex ? 16 : 10) + static_cast<char32_t>(d);
			}
			if (ok && cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF)) {
				AppendCp(out, cp);
			} else {
				AppendCp(out, 0xFFFD);
			}
		} else {
			out.append(s.substr(i, end - i + 1)); // unknown entity kept verbatim
		}
		i = end + 1;
	}
	return out;
}

static std::string_view Local(std::string_view name) {
	size_t colon = name.rfind(':');
	return colon == std::string_view::npos ? name : name.substr(colon + 1);
}

static bool IsSpace(char c) {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

static std::string_view Trim(std::string_view s) {
	while (!s.empty() && IsSpace(s.front())) {
		s.remove_prefix(1);
	}
	while (!s.empty() && IsSpace(s.back())) {
		s.remove_suffix(1);
	}
	return s;
}

// Pull a named attribute out of an attribute string.  Quotes may be ' or ".
static bool Attr(std::string_view attrs, std::string_view want, std::string &out) {
	std::string_view rest = attrs;
	while (true) {
		size_t eq = rest.find('=');
		if (eq == std::string_view::npos) {
			return false;
		}
		std::string_view name = Trim(rest.substr(0, eq));
		size_t sp = name.find_last_of(" \t\n\r");
		if (sp != std::string_view::npos) {
			name = name.substr(sp + 1);
		}
		std::string_view after = rest.substr(eq + 1);
		while (!after.empty() && IsSpace(after.front())) {
			after.remove_prefix(1);
		}
		if (after.empty() || (after[0] != '"' && after[0] != '\'')) {
			return false;
		}
		char quote = after[0];
		size_t val_end = after.find(quote, 1);
		if (val_end == std::string_view::npos) {
			return false;
		}
		if (Local(name) == want) {
			// Repair invalid UTF-8 here so tags, indicators and codes are
			// always safe to hand to VARCHAR vectors.
			out = Utf8Encode(Utf8DecodeLossy(DecodeEntities(after.substr(1, val_end - 1))));
			return true;
		}
		rest = after.substr(val_end + 1);
	}
}

// One UTF-8 scalar (a space if empty).
static std::string OneScalar(const std::string &s) {
	if (s.empty()) {
		return " ";
	}
	size_t len = 1;
	uint8_t c = s[0];
	if (c >= 0xF0) {
		len = 4;
	} else if (c >= 0xE0) {
		len = 3;
	} else if (c >= 0xC0) {
		len = 2;
	}
	return s.substr(0, std::min(len, s.size()));
}

std::vector<Record> ParseMarcXml(std::string_view text) {
	std::vector<Record> records;
	Record rec;
	bool in_record = false;
	Field datafield;
	bool in_datafield = false;
	// Element whose text content is being collected + its key attribute.
	std::string collecting_elem, collecting_key, collected;

	size_t pos = 0;
	while (pos < text.size()) {
		if (text[pos] != '<') {
			size_t lt = text.find('<', pos);
			if (lt == std::string_view::npos) {
				lt = text.size();
			}
			if (!collecting_elem.empty()) {
				collected.append(text.substr(pos, lt - pos));
			}
			pos = lt;
			continue;
		}
		if (text.compare(pos, 4, "<!--") == 0) {
			size_t end = text.find("-->", pos);
			if (end == std::string_view::npos) {
				throw MarcError("unterminated comment");
			}
			pos = end + 3;
			continue;
		}
		if (pos + 1 < text.size() && (text[pos + 1] == '!' || text[pos + 1] == '?')) {
			size_t end = text.find('>', pos);
			if (end == std::string_view::npos) {
				throw MarcError("unterminated declaration");
			}
			pos = end + 1;
			continue;
		}
		size_t end = text.find('>', pos);
		if (end == std::string_view::npos) {
			throw MarcError("unterminated tag");
		}
		std::string_view inner = text.substr(pos + 1, end - pos - 1);
		pos = end + 1;

		bool closing = !inner.empty() && inner[0] == '/';
		if (closing) {
			inner.remove_prefix(1);
		}
		bool self_closing = !inner.empty() && inner.back() == '/';
		if (self_closing) {
			inner.remove_suffix(1);
		}
		inner = Trim(inner);
		size_t sp = 0;
		while (sp < inner.size() && !IsSpace(inner[sp])) {
			sp++;
		}
		std::string name(Local(inner.substr(0, sp)));
		std::string_view attrs = Trim(inner.substr(sp));

		if (closing) {
			if (!collecting_elem.empty() && collecting_elem == name) {
				std::string value = NfcNormalizeUtf8(DecodeEntities(collected));
				if (name == "leader") {
					rec.leader = std::move(value);
				} else if (name == "controlfield" && in_record) {
					Field f;
					f.tag = collecting_key;
					f.is_control = true;
					f.control_value = std::move(value);
					rec.fields.push_back(std::move(f));
				} else if (name == "subfield" && in_datafield) {
					Subfield sf;
					sf.code = OneScalar(collecting_key);
					sf.value = std::move(value);
					datafield.subfields.push_back(std::move(sf));
				}
				collecting_elem.clear();
				collecting_key.clear();
				collected.clear();
				continue;
			}
			if (name == "datafield" && in_record && in_datafield) {
				rec.fields.push_back(std::move(datafield));
				datafield = Field();
				in_datafield = false;
			} else if (name == "record" && in_record) {
				std::u32string ldr = Utf8DecodeLossy(rec.leader);
				ldr.resize(24, U' ');
				rec.leader = Utf8Encode(ldr);
				records.push_back(std::move(rec));
				rec = Record();
				in_record = false;
			}
			continue;
		}

		if (name == "record") {
			rec = Record();
			in_record = true;
		} else if (name == "leader" && !self_closing) {
			collecting_elem = "leader";
			collected.clear();
		} else if (name == "controlfield") {
			std::string tag;
			if (!Attr(attrs, "tag", tag)) {
				throw MarcError("controlfield without tag");
			}
			if (self_closing) {
				Field f;
				f.tag = std::move(tag);
				f.is_control = true;
				if (in_record) {
					rec.fields.push_back(std::move(f));
				}
			} else {
				collecting_elem = "controlfield";
				collecting_key = std::move(tag);
				collected.clear();
			}
		} else if (name == "datafield") {
			std::string tag, ind;
			if (!Attr(attrs, "tag", tag)) {
				throw MarcError("datafield without tag");
			}
			datafield = Field();
			datafield.tag = std::move(tag);
			datafield.ind1 = Attr(attrs, "ind1", ind) ? OneScalar(ind) : " ";
			datafield.ind2 = Attr(attrs, "ind2", ind) ? OneScalar(ind) : " ";
			in_datafield = true;
		} else if (name == "subfield") {
			std::string code;
			if (!Attr(attrs, "code", code)) {
				throw MarcError("subfield without code");
			}
			if (self_closing) {
				if (in_datafield) {
					Subfield sf;
					sf.code = OneScalar(code);
					datafield.subfields.push_back(std::move(sf));
				}
			} else {
				collecting_elem = "subfield";
				collecting_key = std::move(code);
				collected.clear();
			}
		}
	}
	return records;
}

} // namespace marc
