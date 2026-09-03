//! ISO 2709 / MARC 21 binary parsing.  Deliberate choices: records split on
//! RT, base address taken from the directory terminator (leader lengths lie
//! in real data), decoding chosen per record from leader/09 unless
//! overridden.
#include "marc/core.hpp"

namespace marc {

Encoding ParseEncoding(const std::string &s) {
	std::string l;
	l.reserve(s.size());
	for (char c : s) {
		l.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
	}
	if (l == "auto") {
		return Encoding::AUTO;
	}
	if (l == "utf8" || l == "utf-8") {
		return Encoding::UTF8;
	}
	if (l == "marc8" || l == "marc-8") {
		return Encoding::MARC8;
	}
	throw MarcError("unknown encoding \"" + s + "\"; expected auto, utf8 or marc8");
}

bool RecordSplitter::Next(std::string_view &out) {
	size_t n = data_.size();
	while (pos_ < n && (data_[pos_] == 0x0A || data_[pos_] == 0x0D || data_[pos_] == 0x20)) {
		pos_++;
	}
	if (pos_ >= n) {
		return false;
	}
	size_t start = pos_;
	size_t rt = data_.find(static_cast<char>(RT), start);
	if (rt == std::string_view::npos) {
		out = data_.substr(start);
		pos_ = n;
	} else {
		out = data_.substr(start, rt + 1 - start);
		pos_ = rt + 1;
	}
	return true;
}

static bool ParseAsciiNum(std::string_view s, size_t &v) {
	v = 0;
	for (char c : s) {
		if (c < '0' || c > '9') {
			return false;
		}
		v = v * 10 + static_cast<size_t>(c - '0');
	}
	return true;
}

static std::string DecodeBytes(std::string_view bytes, Encoding enc) {
	if (enc == Encoding::MARC8) {
		return Marc8Decode(bytes);
	}
	// UTF-8 with U+FFFD repair, NFC-normalised like the MARC-8 path so both
	// encodings yield canonically identical values.
	return NfcNormalizeUtf8(bytes);
}

Record ParseRecord(std::string_view raw, Encoding encoding, DecodeMode mode) {
	if (raw.size() < 24) {
		throw MarcError("record shorter than leader");
	}
	Record rec;
	rec.leader = Latin1ToUtf8(raw.substr(0, 24));
	Encoding enc = encoding;
	if (enc == Encoding::AUTO) {
		enc = raw[9] == 'a' ? Encoding::UTF8 : Encoding::MARC8;
	}

	size_t dir_end = raw.find(static_cast<char>(FT), 24);
	if (dir_end == std::string_view::npos) {
		throw MarcError("no directory terminator");
	}
	std::string_view directory = raw.substr(24, dir_end - 24);
	if (directory.size() % 12 != 0) {
		throw MarcError("directory length " + std::to_string(directory.size()) + " not multiple of 12");
	}
	// Trust the directory terminator over leader/12-16.
	size_t base = dir_end + 1;

	rec.fields.reserve(directory.size() / 12);
	for (size_t k = 0; k < directory.size(); k += 12) {
		std::string tag = Latin1ToUtf8(directory.substr(k, 3));
		size_t length, start;
		if (!ParseAsciiNum(directory.substr(k + 3, 4), length) || !ParseAsciiNum(directory.substr(k + 7, 5), start)) {
			throw MarcError("non-numeric directory entry for tag " + tag);
		}
		size_t fstart = base + start;
		if (fstart + length > raw.size()) {
			throw MarcError("field " + tag + " extends past end of record");
		}
		std::string_view chunk = raw.substr(fstart, length);
		if (!chunk.empty() && static_cast<uint8_t>(chunk.back()) == FT) {
			chunk.remove_suffix(1);
		}

		Field field;
		field.tag = std::move(tag);
		if (field.tag < "010") {
			field.is_control = true;
			if (mode != DecodeMode::NONE) {
				field.control_value = DecodeBytes(chunk, enc);
			}
		} else {
			if (chunk.size() < 2) {
				throw MarcError("data field " + field.tag + " shorter than indicators");
			}
			field.ind1 = Latin1ToUtf8(chunk.substr(0, 1));
			field.ind2 = Latin1ToUtf8(chunk.substr(1, 1));
			// Everything before the first SF is (should be) empty; skip it.
			size_t p = chunk.find(static_cast<char>(SF), 2);
			while (p != std::string_view::npos) {
				size_t next = chunk.find(static_cast<char>(SF), p + 1);
				std::string_view part =
				    chunk.substr(p + 1, next == std::string_view::npos ? std::string_view::npos : next - p - 1);
				if (!part.empty()) {
					Subfield sf;
					sf.code = Latin1ToUtf8(part.substr(0, 1));
					if (mode == DecodeMode::ALL) {
						sf.value = DecodeBytes(part.substr(1), enc);
					}
					field.subfields.push_back(std::move(sf));
				}
				p = next;
			}
		}
		rec.fields.push_back(std::move(field));
	}
	return rec;
}

} // namespace marc
