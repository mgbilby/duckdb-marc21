//! Text writers: MARCXML (slim layout) and MARC breaker (.mrk), each the
//! exact inverse of its reader for NFC input — ParseMarcXml(WriteMarcXml(r))
//! and ParseBreaker(WriteBreaker(r)) reproduce the record.
//!
//! Breaker caveat, inherent to the format: a value containing the literal
//! text "{dollar}" cannot round-trip, since the reader unescapes it and the
//! format defines no escape for the braces themselves.
#include "marc/formats.hpp"

namespace marc {

namespace {

std::string XmlEscapeText(std::string_view s) {
	std::string out;
	out.reserve(s.size());
	for (char c : s) {
		if (c == '&') {
			out += "&amp;";
		} else if (c == '<') {
			out += "&lt;";
		} else if (c == '>') {
			out += "&gt;";
		} else {
			out.push_back(c);
		}
	}
	return out;
}

std::string XmlEscapeAttr(std::string_view s) {
	std::string out;
	out.reserve(s.size());
	for (char c : s) {
		if (c == '&') {
			out += "&amp;";
		} else if (c == '<') {
			out += "&lt;";
		} else if (c == '>') {
			out += "&gt;";
		} else if (c == '"') {
			out += "&quot;";
		} else {
			out.push_back(c);
		}
	}
	return out;
}

std::string BreakerEscape(std::string_view s) {
	std::string out;
	out.reserve(s.size());
	for (char c : s) {
		if (c == '$') {
			out += "{dollar}";
		} else {
			out.push_back(c);
		}
	}
	return out;
}

} // namespace

std::string WriteMarcXml(const Record &rec) {
	std::string out = "<record>\n  <leader>";
	out += XmlEscapeText(rec.leader);
	out += "</leader>\n";
	for (auto &f : rec.fields) {
		if (f.is_control) {
			out += "  <controlfield tag=\"";
			out += XmlEscapeAttr(f.tag);
			out += "\">";
			out += XmlEscapeText(f.control_value);
			out += "</controlfield>\n";
		} else {
			out += "  <datafield tag=\"";
			out += XmlEscapeAttr(f.tag);
			out += "\" ind1=\"";
			out += XmlEscapeAttr(f.ind1);
			out += "\" ind2=\"";
			out += XmlEscapeAttr(f.ind2);
			out += "\">\n";
			for (auto &sf : f.subfields) {
				out += "    <subfield code=\"";
				out += XmlEscapeAttr(sf.code);
				out += "\">";
				out += XmlEscapeText(sf.value);
				out += "</subfield>\n";
			}
			out += "  </datafield>\n";
		}
	}
	out += "</record>";
	return out;
}

std::string WriteMarcXmlCollection(const std::vector<Record> &records) {
	std::string out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
	                  "<collection xmlns=\"http://www.loc.gov/MARC21/slim\">\n";
	for (auto &rec : records) {
		out += WriteMarcXml(rec);
		out += "\n";
	}
	out += "</collection>\n";
	return out;
}

std::string WriteBreaker(const Record &rec) {
	std::string out = "=LDR  ";
	out += rec.leader;
	out += "\n";
	for (auto &f : rec.fields) {
		out += "=";
		out += f.tag;
		out += "  ";
		if (f.is_control) {
			out += BreakerEscape(f.control_value);
		} else {
			out += f.ind1 == " " ? "\\" : f.ind1;
			out += f.ind2 == " " ? "\\" : f.ind2;
			for (auto &sf : f.subfields) {
				out += "$";
				out += sf.code;
				out += BreakerEscape(sf.value);
			}
		}
		out += "\n";
	}
	return out;
}

} // namespace marc
