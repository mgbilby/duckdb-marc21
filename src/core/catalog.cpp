//! Cataloging workflow helpers (see catalog.hpp for the API).  Written from
//! the published MARC 21 bibliographic format documentation (Leader, 007,
//! 008, 336-338) and the RDA content/media/carrier term lists registered in
//! MARC — no external MARC tooling code consulted.
//!
//! RankRecord — Leader/17 encoding level, higher = better (unlisted → 0):
//!   ' ' full ..............................100
//!   '4' core ............................... 90
//!   '1' full, material not examined ........ 85
//!   'I' OCLC full-level input .............. 80
//!   '2' less-than-full, not examined ....... 70
//!   '5' partial (preliminary) .............. 60
//!   '8' prepublication (CIP) ............... 50
//!   '3' abbreviated ........................ 40
//!   'K' OCLC minimal-level input ........... 35
//!   'M' OCLC added from batch .............. 30
//!   '7' minimal ............................ 25
//!   'u' unknown ............................ 10
//!   'z' not applicable ......................5
//! Completeness weights (sum of maxima = 100):
//!   245 with non-empty $a 15, plus non-empty $b 5
//!   any 1XX 10; any 7XX 5
//!   each 6XX 3, capped at 15
//!   300 present 10; 260 or 264 present 10
//!   008 language coded (35-37 not blank / "|||") 10
//!   020 or 010 present 10; any 5XX 5
//!   336 AND 337 AND 338 all present 5
//! total = (6 * encoding_level_rank + 4 * completeness) / 10.
//!
//! NewRecord — Leader "00000n" + type + level + " a22000005i 4500":
//!   05 'n' new; 06-07 from the material; 08 ' '; 09 'a' (UCS); 17 '5'
//!   partial/preliminary (a template is exactly a preliminary record);
//!   18 'i' ISBD punctuation.  008 all-materials layout, 40 chars:
//!   00-05 "      "  date entered — placeholder for the caller/ILS to fill
//!   06    'n'       date type: dates unknown; 07-14 blank dates
//!   15-17 "xx "     place of publication unknown
//!   18-34 blanks    material-specific positions left uncoded
//!   35-37 "   "     language not yet coded; 38 ' ' not modified
//!   39    'd'       cataloging source: other
//!
//! Generate33X mapping (RDA terms/codes as registered for MARC 336-338):
//!   content (336) from Leader/06, 008/26 splitting computer files:
//!     a,t → text/txt              c,d → notated music/ntm
//!     e,f → cartographic image/cri    g → two-dimensional moving image/tdi
//!     i → spoken word/spw         j → performed music/prm
//!     m → computer program/cop when 008/26 = 'b', else computer dataset/cod
//!   media (337) from the first 007/00:
//!     s → audio/s   v → video/v   c → computer/c
//!     g → projected/g   h → microform/h
//!     no 007 at all: unmediated/n, only for print-shaped Leader/06 (a t c d e f)
//!   carrier (338) from the first 007/00-01:
//!     s → audio disc/sd (the common case; 007/01 not consulted)
//!     v → videodisc/vd
//!     c → online resource/cr when 007/01 = 'r', else computer disc/cd
//!     no 007 and print-shaped Leader/06: volume/nc
//!   Anything else leaves that slot unset — no field is added for it.
//!
//! RdaExpandAbbreviations list (lowercase only, fixed replacements — "1 v."
//! becomes "1 volumes"; grammatical number is deliberately not inferred):
//!   p. → pages          v. → volumes        ill. → illustrations
//!   col. → color        ed. → edition
//!   facsim. → facsimile   facsims. → facsimiles
//!   port. → portrait      ports. → portraits
#include "marc/catalog.hpp"
#include "marc/edit.hpp"

#include <cstring>

namespace marc {

namespace {

bool NonEmptySubfield(const Field &f, const char *code) {
	for (auto &sf : f.subfields) {
		if (sf.code == code && !sf.value.empty()) {
			return true;
		}
	}
	return false;
}

int EncodingLevelRank(char level) {
	switch (level) {
	case ' ':
		return 100;
	case '4':
		return 90;
	case '1':
		return 85;
	case 'I':
		return 80;
	case '2':
		return 70;
	case '5':
		return 60;
	case '8':
		return 50;
	case '3':
		return 40;
	case 'K':
		return 35;
	case 'M':
		return 30;
	case '7':
		return 25;
	case 'u':
		return 10;
	case 'z':
		return 5;
	default:
		return 0;
	}
}

} // namespace

RecordRank RankRecord(const Record &rec) {
	RecordRank rank;
	rank.encoding_level_rank = EncodingLevelRank(rec.leader.size() > 17 ? rec.leader[17] : '\0');

	bool has_245a = false, has_245b = false, has_1xx = false, has_7xx = false;
	bool has_300 = false, has_pub = false, has_lang = false, has_id = false, has_5xx = false;
	bool has_336 = false, has_337 = false, has_338 = false;
	int subjects = 0;
	for (auto &f : rec.fields) {
		if (f.tag.size() != 3) {
			continue;
		}
		if (f.is_control) {
			if (f.tag == "008" && f.control_value.size() >= 38) {
				std::string lang = f.control_value.substr(35, 3);
				has_lang = has_lang || (lang != "   " && lang != "|||");
			}
			continue;
		}
		if (f.tag == "245") {
			has_245a = has_245a || NonEmptySubfield(f, "a");
			has_245b = has_245b || NonEmptySubfield(f, "b");
		} else if (f.tag[0] == '1') {
			has_1xx = true;
		} else if (f.tag[0] == '7') {
			has_7xx = true;
		} else if (f.tag[0] == '6') {
			subjects++;
		} else if (f.tag[0] == '5') {
			has_5xx = true;
		} else if (f.tag == "300") {
			has_300 = true;
		} else if (f.tag == "260" || f.tag == "264") {
			has_pub = true;
		} else if (f.tag == "020" || f.tag == "010") {
			has_id = true;
		} else if (f.tag == "336") {
			has_336 = true;
		} else if (f.tag == "337") {
			has_337 = true;
		} else if (f.tag == "338") {
			has_338 = true;
		}
	}

	int score = 0;
	score += has_245a ? 15 : 0;
	score += has_245b ? 5 : 0;
	score += has_1xx ? 10 : 0;
	score += has_7xx ? 5 : 0;
	score += subjects > 5 ? 15 : subjects * 3;
	score += has_300 ? 10 : 0;
	score += has_pub ? 10 : 0;
	score += has_lang ? 10 : 0;
	score += has_id ? 10 : 0;
	score += has_5xx ? 5 : 0;
	score += (has_336 && has_337 && has_338) ? 5 : 0;
	rank.completeness = score;

	rank.total = (6 * rank.encoding_level_rank + 4 * rank.completeness) / 10;
	return rank;
}

Record NewRecord(std::string_view material) {
	char type, level;
	if (material == "book") {
		type = 'a', level = 'm';
	} else if (material == "serial") {
		type = 'a', level = 's';
	} else if (material == "video") {
		type = 'g', level = 'm';
	} else if (material == "map") {
		type = 'e', level = 'm';
	} else if (material == "music") {
		type = 'c', level = 'm';
	} else if (material == "electronic") {
		type = 'm', level = 'm';
	} else {
		throw MarcError("unknown material \"" + std::string(material) +
		                "\"; valid: book, serial, video, map, music, electronic");
	}

	Record rec;
	rec.leader = "00000n";
	rec.leader += type;
	rec.leader += level;
	rec.leader += " a22000005i 4500";

	Field f008;
	f008.tag = "008";
	f008.is_control = true;
	f008.control_value.assign(40, ' ');
	f008.control_value[6] = 'n';
	f008.control_value[15] = 'x';
	f008.control_value[16] = 'x';
	f008.control_value[39] = 'd';

	Field f245;
	f245.tag = "245";
	f245.subfields.push_back({"a", ""});

	rec.fields.push_back(std::move(f008));
	rec.fields.push_back(std::move(f245));
	return rec;
}

namespace {

struct RdaAbbrev {
	const char *abbr;
	const char *full;
};

// Plural forms before their singular prefix so the longest match wins.
const RdaAbbrev RDA_ABBREVS[] = {
    {"facsims.", "facsimiles"}, {"facsim.", "facsimile"}, {"ports.", "portraits"},
    {"port.", "portrait"},      {"ill.", "illustrations"}, {"col.", "color"},
    {"ed.", "edition"},         {"v.", "volumes"},         {"p.", "pages"},
};

bool IsWordChar(char c) {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

std::string ExpandAbbrevs(const std::string &s) {
	std::string out;
	out.reserve(s.size());
	size_t i = 0;
	while (i < s.size()) {
		if (i == 0 || !IsWordChar(s[i - 1])) {
			bool replaced = false;
			for (auto &a : RDA_ABBREVS) {
				size_t len = std::strlen(a.abbr);
				if (s.compare(i, len, a.abbr) == 0 && (i + len == s.size() || !IsWordChar(s[i + len]))) {
					out.append(a.full);
					i += len;
					replaced = true;
					break;
				}
			}
			if (replaced) {
				continue;
			}
		}
		out.push_back(s[i++]);
	}
	return out;
}

} // namespace

Record RdaExpandAbbreviations(const Record &rec) {
	Record out = rec;
	for (auto &f : out.fields) {
		if (f.is_control) {
			continue;
		}
		if (f.tag == "250") {
			for (auto &sf : f.subfields) {
				if (sf.code == "a") {
					sf.value = ExpandAbbrevs(sf.value);
				}
			}
		} else if (f.tag == "300") {
			for (auto &sf : f.subfields) {
				sf.value = ExpandAbbrevs(sf.value);
			}
		}
	}
	return out;
}

Record Generate33X(const Record &rec) {
	char type = rec.leader.size() > 6 ? rec.leader[6] : '\0';
	std::string f007, f008;
	bool have336 = false, have337 = false, have338 = false;
	for (auto &f : rec.fields) {
		if (f.is_control && f.tag == "007" && f007.empty()) {
			f007 = f.control_value;
		} else if (f.is_control && f.tag == "008" && f008.empty()) {
			f008 = f.control_value;
		} else if (f.tag == "336") {
			have336 = true;
		} else if (f.tag == "337") {
			have337 = true;
		} else if (f.tag == "338") {
			have338 = true;
		}
	}

	struct Term {
		const char *term = nullptr;
		const char *code = nullptr;
	};
	Term content, media, carrier;
	switch (type) {
	case 'a':
	case 't':
		content = {"text", "txt"};
		break;
	case 'c':
	case 'd':
		content = {"notated music", "ntm"};
		break;
	case 'e':
	case 'f':
		content = {"cartographic image", "cri"};
		break;
	case 'g':
		content = {"two-dimensional moving image", "tdi"};
		break;
	case 'i':
		content = {"spoken word", "spw"};
		break;
	case 'j':
		content = {"performed music", "prm"};
		break;
	case 'm':
		if (f008.size() > 26 && f008[26] == 'b') {
			content = {"computer program", "cop"};
		} else {
			content = {"computer dataset", "cod"};
		}
		break;
	default:
		break;
	}

	bool printish =
	    type == 'a' || type == 't' || type == 'c' || type == 'd' || type == 'e' || type == 'f';
	switch (f007.empty() ? '\0' : f007[0]) {
	case 's':
		media = {"audio", "s"};
		carrier = {"audio disc", "sd"};
		break;
	case 'v':
		media = {"video", "v"};
		carrier = {"videodisc", "vd"};
		break;
	case 'c':
		media = {"computer", "c"};
		if (f007.size() > 1 && f007[1] == 'r') {
			carrier = {"online resource", "cr"};
		} else {
			carrier = {"computer disc", "cd"};
		}
		break;
	case 'g':
		media = {"projected", "g"};
		break;
	case 'h':
		media = {"microform", "h"};
		break;
	case '\0':
		if (printish) {
			media = {"unmediated", "n"};
			carrier = {"volume", "nc"};
		}
		break;
	default:
		break;
	}

	Record out = rec;
	auto add = [&](const char *tag, const Term &t, const char *source) {
		if (!t.term) {
			return;
		}
		Field f;
		f.tag = tag;
		f.subfields = {{"a", t.term}, {"b", t.code}, {"2", source}};
		out = AddField(out, std::move(f));
	};
	if (!have336) {
		add("336", content, "rdacontent");
	}
	if (!have337) {
		add("337", media, "rdamedia");
	}
	if (!have338) {
		add("338", carrier, "rdacarrier");
	}
	return out;
}

} // namespace marc
