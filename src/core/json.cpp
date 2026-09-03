//! The deliberately small JSON parser formerly private to avram.cpp; see
//! json.hpp.  Numbers are validated to the RFC grammar and kept as raw text.
#include "marc/json.hpp"

#include <cstdio>

namespace marc {

namespace {

class JsonParser {
public:
	JsonParser(std::string_view text, std::string_view context, size_t pos)
	    : text_(text), context_(context), pos_(pos) {
	}

	JsonValue ParseComplete() {
		JsonValue v = ParseValue(0);
		SkipWs();
		if (pos_ != text_.size()) {
			Fail("trailing data after value");
		}
		return v;
	}

	JsonValue ParseOne() {
		return ParseValue(0);
	}

	size_t Pos() const {
		return pos_;
	}

private:
	[[noreturn]] void Fail(const std::string &why) {
		throw MarcError(std::string(context_) + ": malformed JSON at byte " + std::to_string(pos_) + ": " + why);
	}

	void SkipWs() {
		while (pos_ < text_.size()) {
			char c = text_[pos_];
			if (c != ' ' && c != '\t' && c != '\n' && c != '\r') {
				break;
			}
			pos_++;
		}
	}

	char Peek() {
		if (pos_ >= text_.size()) {
			Fail("unexpected end of input");
		}
		return text_[pos_];
	}

	void Expect(char c) {
		if (Peek() != c) {
			Fail(std::string("expected '") + c + "'");
		}
		pos_++;
	}

	bool Literal(std::string_view word) {
		if (text_.compare(pos_, word.size(), word) == 0) {
			pos_ += word.size();
			return true;
		}
		return false;
	}

	char32_t ParseHex4() {
		char32_t cp = 0;
		for (int i = 0; i < 4; i++) {
			if (pos_ >= text_.size()) {
				Fail("truncated \\u escape");
			}
			char c = text_[pos_++];
			int d;
			if (c >= '0' && c <= '9') {
				d = c - '0';
			} else if (c >= 'a' && c <= 'f') {
				d = c - 'a' + 10;
			} else if (c >= 'A' && c <= 'F') {
				d = c - 'A' + 10;
			} else {
				Fail("bad hex digit in \\u escape");
			}
			cp = cp * 16 + static_cast<char32_t>(d);
		}
		return cp;
	}

	std::string ParseString() {
		Expect('"');
		std::string out;
		while (true) {
			if (pos_ >= text_.size()) {
				Fail("unterminated string");
			}
			char c = text_[pos_++];
			if (c == '"') {
				return out;
			}
			if (c != '\\') {
				out.push_back(c);
				continue;
			}
			if (pos_ >= text_.size()) {
				Fail("unterminated escape");
			}
			char e = text_[pos_++];
			switch (e) {
			case '"':
			case '\\':
			case '/':
				out.push_back(e);
				break;
			case 'b':
				out.push_back('\b');
				break;
			case 'f':
				out.push_back('\f');
				break;
			case 'n':
				out.push_back('\n');
				break;
			case 'r':
				out.push_back('\r');
				break;
			case 't':
				out.push_back('\t');
				break;
			case 'u': {
				char32_t cp = ParseHex4();
				if (cp >= 0xD800 && cp <= 0xDBFF) {
					if (!Literal("\\u")) {
						Fail("unpaired high surrogate");
					}
					char32_t lo = ParseHex4();
					if (lo < 0xDC00 || lo > 0xDFFF) {
						Fail("invalid low surrogate");
					}
					cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
				} else if (cp >= 0xDC00 && cp <= 0xDFFF) {
					Fail("unpaired low surrogate");
				}
				out += Utf8Encode(std::u32string(1, cp));
				break;
			}
			default:
				Fail("unknown escape");
			}
		}
	}

	void SkipDigits() {
		size_t n = 0;
		while (pos_ < text_.size() && text_[pos_] >= '0' && text_[pos_] <= '9') {
			pos_++;
			n++;
		}
		if (n == 0) {
			Fail("bad number");
		}
	}

	void SkipNumber() {
		if (pos_ < text_.size() && text_[pos_] == '-') {
			pos_++;
		}
		SkipDigits();
		if (pos_ < text_.size() && text_[pos_] == '.') {
			pos_++;
			SkipDigits();
		}
		if (pos_ < text_.size() && (text_[pos_] == 'e' || text_[pos_] == 'E')) {
			pos_++;
			if (pos_ < text_.size() && (text_[pos_] == '+' || text_[pos_] == '-')) {
				pos_++;
			}
			SkipDigits();
		}
	}

	JsonValue ParseValue(int depth) {
		if (depth > 100) {
			Fail("nesting too deep");
		}
		SkipWs();
		JsonValue v;
		char c = Peek();
		if (c == '{') {
			pos_++;
			v.type = JsonValue::Type::OBJ;
			SkipWs();
			if (Peek() == '}') {
				pos_++;
				return v;
			}
			while (true) {
				SkipWs();
				std::string key = ParseString();
				SkipWs();
				Expect(':');
				v.obj.emplace_back(std::move(key), ParseValue(depth + 1));
				SkipWs();
				if (Peek() == ',') {
					pos_++;
					continue;
				}
				Expect('}');
				return v;
			}
		}
		if (c == '[') {
			pos_++;
			v.type = JsonValue::Type::ARR;
			SkipWs();
			if (Peek() == ']') {
				pos_++;
				return v;
			}
			while (true) {
				v.arr.push_back(ParseValue(depth + 1));
				SkipWs();
				if (Peek() == ',') {
					pos_++;
					continue;
				}
				Expect(']');
				return v;
			}
		}
		if (c == '"') {
			v.type = JsonValue::Type::STR;
			v.str = ParseString();
			return v;
		}
		if (c == 't' || c == 'f') {
			if (Literal("true")) {
				v.type = JsonValue::Type::BOOL;
				v.boolean = true;
				return v;
			}
			if (Literal("false")) {
				v.type = JsonValue::Type::BOOL;
				return v;
			}
			Fail("bad literal");
		}
		if (c == 'n') {
			if (Literal("null")) {
				return v;
			}
			Fail("bad literal");
		}
		if (c == '-' || (c >= '0' && c <= '9')) {
			v.type = JsonValue::Type::NUM;
			size_t start = pos_;
			SkipNumber();
			v.str = std::string(text_.substr(start, pos_ - start));
			return v;
		}
		Fail("unexpected character");
	}

	std::string_view text_;
	std::string_view context_;
	size_t pos_ = 0;
};

} // namespace

JsonValue ParseJson(std::string_view text, std::string_view context) {
	return JsonParser(text, context, 0).ParseComplete();
}

JsonValue ParseJsonValueAt(std::string_view text, size_t &pos, std::string_view context) {
	JsonParser p(text, context, pos);
	JsonValue v = p.ParseOne();
	pos = p.Pos();
	return v;
}

std::string EscapeJsonString(std::string_view s) {
	std::string out;
	out.reserve(s.size());
	for (char raw : s) {
		unsigned char c = static_cast<unsigned char>(raw);
		switch (c) {
		case '"':
			out += "\\\"";
			break;
		case '\\':
			out += "\\\\";
			break;
		case '\b':
			out += "\\b";
			break;
		case '\f':
			out += "\\f";
			break;
		case '\n':
			out += "\\n";
			break;
		case '\r':
			out += "\\r";
			break;
		case '\t':
			out += "\\t";
			break;
		default:
			if (c < 0x20) {
				char buf[8];
				std::snprintf(buf, sizeof(buf), "\\u%04x", c);
				out += buf;
			} else {
				out.push_back(raw);
			}
		}
	}
	return out;
}

} // namespace marc
