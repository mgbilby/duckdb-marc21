// Standalone tests for the cataloging helpers module:
//   g++ -std=c++17 -Wall -O2 -Isrc/include src/core/*.cpp test/cpp/catalog_test.cpp -o catalog_test && ./catalog_test
#include "checks.hpp"

#include "marc/catalog.hpp"

#include <string>

using namespace marc;

static Field CF(const std::string &tag, const std::string &value) {
	Field f;
	f.tag = tag;
	f.is_control = true;
	f.control_value = value;
	return f;
}

static Field DF(const std::string &tag, const std::string &ind1, const std::string &ind2,
                std::vector<Subfield> subs) {
	Field f;
	f.tag = tag;
	f.ind1 = ind1;
	f.ind2 = ind2;
	f.subfields = std::move(subs);
	return f;
}

static Record Rec(std::vector<Field> fields) {
	Record r;
	r.leader = "00000nam a2200000 a 4500"; // Leader/17 = ' ' (full)
	r.fields = std::move(fields);
	return r;
}

static const Field *FindTag(const Record &r, const std::string &tag) {
	for (auto &f : r.fields) {
		if (f.tag == tag) {
			return &f;
		}
	}
	return nullptr;
}

// 40-char book 008 with language eng (positions 35-37).
static const char *SAMPLE_008 = "970101s1997    nyu           000 0 eng d";

// ---- RankRecord ------------------------------------------------------------

static void TestEncodingLevelOrder() {
	// Documented ordering, strictly decreasing, all above 0.
	const char order[] = {' ', '4', '1', 'I', '2', '5', '8', '3', 'K', 'M', '7', 'u', 'z'};
	int prev = 101;
	for (char level : order) {
		Record r = Rec({});
		r.leader[17] = level;
		int rank = RankRecord(r).encoding_level_rank;
		CHECK(rank > 0);
		CHECK(rank < prev);
		prev = rank;
	}
	Record r = Rec({});
	r.leader[17] = 'q'; // unlisted value
	CHECK_EQ(RankRecord(r).encoding_level_rank, 0);
	Record no_leader;
	CHECK_EQ(RankRecord(no_leader).encoding_level_rank, 0);
	CHECK_EQ(RankRecord(no_leader).completeness, 0);
	CHECK_EQ(RankRecord(no_leader).total, 0);
}

static Record FullRecord() {
	return Rec({
	    CF("008", SAMPLE_008),
	    DF("020", " ", " ", {{"a", "9780306406157"}}),
	    DF("100", "1", " ", {{"a", "Smith, Jane."}}),
	    DF("245", "1", "0", {{"a", "Cooking basics :"}, {"b", "a primer."}}),
	    DF("264", " ", "1", {{"a", "New York :"}, {"b", "Pub,"}, {"c", "1997."}}),
	    DF("300", " ", " ", {{"a", "347 pages"}}),
	    DF("336", " ", " ", {{"a", "text"}, {"b", "txt"}, {"2", "rdacontent"}}),
	    DF("337", " ", " ", {{"a", "unmediated"}, {"b", "n"}, {"2", "rdamedia"}}),
	    DF("338", " ", " ", {{"a", "volume"}, {"b", "nc"}, {"2", "rdacarrier"}}),
	    DF("500", " ", " ", {{"a", "Includes index."}}),
	    DF("650", " ", "0", {{"a", "Cooking."}}),
	    DF("650", " ", "0", {{"a", "Baking."}}),
	    DF("650", " ", "0", {{"a", "Grilling."}}),
	    DF("650", " ", "0", {{"a", "Roasting."}}),
	    DF("651", " ", "0", {{"a", "France."}}),
	    DF("700", "1", " ", {{"a", "Doe, John."}}),
	});
}

static void TestCompleteness() {
	Record full = FullRecord();
	RecordRank fr = RankRecord(full);
	CHECK_EQ(fr.completeness, 100);
	CHECK_EQ(fr.encoding_level_rank, 100);
	CHECK_EQ(fr.total, 100);

	// 6XX contribution is capped: five more subjects change nothing.
	Record more = full;
	for (int i = 0; i < 5; i++) {
		more.fields.push_back(DF("650", " ", "0", {{"a", "Extra."}}));
	}
	CHECK_EQ(RankRecord(more).completeness, 100);

	Record sparse = Rec({DF("245", "1", "0", {{"a", "Cooking basics"}})});
	RecordRank sr = RankRecord(sparse);
	CHECK_EQ(sr.completeness, 15);
	CHECK_EQ(sr.total, (6 * 100 + 4 * 15) / 10);

	// An empty $a is not a title.
	Record empty245 = Rec({DF("245", " ", " ", {{"a", ""}})});
	CHECK_EQ(RankRecord(empty245).completeness, 0);

	// Blank and fill-character language codes do not count.
	std::string blank008(40, ' ');
	blank008[6] = 'n';
	Record blank_lang = Rec({CF("008", blank008)});
	CHECK_EQ(RankRecord(blank_lang).completeness, 0);
	std::string fill008 = blank008;
	fill008.replace(35, 3, "|||");
	CHECK_EQ(RankRecord(Rec({CF("008", fill008)})).completeness, 0);
}

static void TestRankingMonotonicity() {
	// Fuller outranks sparser at the same encoding level.
	Record sparse = Rec({DF("245", "1", "0", {{"a", "Title"}})});
	Record fuller = sparse;
	fuller.fields.push_back(CF("008", SAMPLE_008));
	fuller.fields.push_back(DF("100", "1", " ", {{"a", "Smith, Jane."}}));
	fuller.fields.push_back(DF("300", " ", " ", {{"a", "347 pages"}}));
	fuller.fields.push_back(DF("650", " ", "0", {{"a", "Cooking."}}));
	RecordRank sr = RankRecord(sparse), fr = RankRecord(fuller);
	CHECK(fr.completeness > sr.completeness);
	CHECK(fr.total > sr.total);

	// Better encoding level outranks worse at the same completeness.
	Record minimal = fuller;
	minimal.leader[17] = 'K';
	CHECK_EQ(RankRecord(minimal).completeness, fr.completeness);
	CHECK(RankRecord(minimal).total < fr.total);

	// The blend keeps every total in 0-100.
	CHECK(fr.total >= 0 && fr.total <= 100);
	CHECK(RankRecord(minimal).total >= 0 && RankRecord(minimal).total <= 100);
}

// ---- NewRecord -------------------------------------------------------------

static void TestNewRecordTemplates() {
	struct Case {
		const char *material;
		char type, level;
	};
	const Case cases[] = {
	    {"book", 'a', 'm'}, {"serial", 'a', 's'}, {"video", 'g', 'm'},
	    {"map", 'e', 'm'},  {"music", 'c', 'm'},  {"electronic", 'm', 'm'},
	};
	for (auto &c : cases) {
		Record r = NewRecord(c.material);
		CHECK_EQ(r.leader.size(), size_t(24));
		CHECK_EQ(r.leader[5], 'n');
		CHECK_EQ(r.leader[6], c.type);
		CHECK_EQ(r.leader[7], c.level);
		CHECK_EQ(r.leader[9], 'a');
		CHECK_EQ(r.leader[17], '5'); // partial/preliminary
		CHECK_EQ(r.leader.substr(20), std::string("4500"));

		const Field *f008 = FindTag(r, "008");
		CHECK(f008 != nullptr && f008->is_control);
		CHECK_EQ(f008->control_value.size(), size_t(40));
		CHECK_EQ(f008->control_value.substr(0, 6), std::string("      "));
		CHECK_EQ(f008->control_value[6], 'n');
		CHECK_EQ(f008->control_value.substr(15, 3), std::string("xx "));
		CHECK_EQ(f008->control_value.substr(35, 3), std::string("   "));
		CHECK_EQ(f008->control_value[39], 'd');

		const Field *f245 = FindTag(r, "245");
		CHECK(f245 != nullptr && !f245->is_control);
		CHECK_EQ(f245->ind1, std::string(" "));
		CHECK_EQ(f245->ind2, std::string(" "));
		CHECK_EQ(f245->subfields.size(), size_t(1));
		CHECK_EQ(f245->subfields[0].code, std::string("a"));
		CHECK_EQ(f245->subfields[0].value, std::string(""));

		// Round-trip: the template is structurally writable and parses back.
		std::string raw = WriteRecord(r);
		Record back = ParseRecord(raw, Encoding::AUTO);
		CHECK_EQ(back.leader.size(), size_t(24));
		CHECK_EQ(back.leader.substr(5, 5), r.leader.substr(5, 5)); // 05-09 stable
		CHECK_EQ(back.leader[17], r.leader[17]);
		CHECK_EQ(back.fields.size(), r.fields.size());
		CHECK_EQ(back.fields[0].control_value, f008->control_value);
		CHECK_EQ(back.fields[1].tag, std::string("245"));
		CHECK_EQ(back.fields[1].subfields.size(), size_t(1));
		CHECK_EQ(back.fields[1].subfields[0].code, std::string("a"));
	}
}

static void TestNewRecordAuthority() {
	Record r = NewRecord("authority");
	CHECK_EQ(r.leader.size(), size_t(24));
	CHECK_EQ(r.leader[5], 'n');
	CHECK_EQ(r.leader[6], 'z');
	CHECK_EQ(r.leader[7], ' '); // 07-08 undefined in the authority format
	CHECK_EQ(r.leader[8], ' ');
	CHECK_EQ(r.leader[9], 'a');
	CHECK_EQ(r.leader[17], 'o'); // incomplete authority record
	CHECK_EQ(r.leader.substr(20), std::string("4500"));

	const Field *f008 = FindTag(r, "008");
	CHECK(f008 != nullptr && f008->is_control);
	CHECK_EQ(f008->control_value.size(), size_t(40));
	CHECK_EQ(f008->control_value.substr(0, 6), std::string("      "));
	CHECK_EQ(f008->control_value[6], 'n');  // geographic subdivision: n/a
	CHECK_EQ(f008->control_value[9], 'a');  // established heading
	CHECK_EQ(f008->control_value[10], 'z'); // cataloging rules: other
	CHECK_EQ(f008->control_value[11], 'n'); // thesaurus: n/a
	CHECK_EQ(f008->control_value[14], 'a'); // main/added entry use: yes
	CHECK_EQ(f008->control_value[15], 'a'); // subject use: yes
	CHECK_EQ(f008->control_value[16], 'b'); // series use: no
	CHECK_EQ(f008->control_value[33], 'd'); // level of establishment: preliminary
	CHECK_EQ(f008->control_value[39], 'd'); // cataloging source: other

	// Placeholder heading is a 100, not a 245.
	CHECK(FindTag(r, "245") == nullptr);
	const Field *f100 = FindTag(r, "100");
	CHECK(f100 != nullptr && !f100->is_control);
	CHECK_EQ(f100->ind1, std::string(" "));
	CHECK_EQ(f100->ind2, std::string(" "));
	CHECK_EQ(f100->subfields.size(), size_t(1));
	CHECK_EQ(f100->subfields[0].code, std::string("a"));
	CHECK_EQ(f100->subfields[0].value, std::string(""));

	// Round-trips like the bibliographic templates.
	std::string raw = WriteRecord(r);
	Record back = ParseRecord(raw, Encoding::AUTO);
	CHECK_EQ(back.leader[6], 'z');
	CHECK_EQ(back.leader[17], 'o');
	CHECK_EQ(back.fields.size(), r.fields.size());
	CHECK_EQ(back.fields[0].control_value, f008->control_value);
	CHECK_EQ(back.fields[1].tag, std::string("100"));
}

static void TestNewRecordUnknown() {
	bool threw = false;
	try {
		NewRecord("cd-rom");
	} catch (const MarcError &e) {
		threw = true;
		std::string msg = e.what();
		CHECK(msg.find("cd-rom") != std::string::npos);
		CHECK(msg.find("book") != std::string::npos);
		CHECK(msg.find("electronic") != std::string::npos);
		CHECK(msg.find("authority") != std::string::npos);
	}
	CHECK(threw);
}

// ---- RdaExpandAbbreviations ------------------------------------------------

static void TestRdaExpand() {
	Record r = Rec({
	    DF("250", " ", " ", {{"a", "2nd ed."}, {"b", "rev. by X. / 3rd ed."}}),
	    DF("300", " ", " ",
	       {{"a", "xii, 347 p. :"},
	        {"b", "ill. (some col.), ports., facsims. ;"},
	        {"c", "24 cm"}}),
	    DF("500", " ", " ", {{"a", "Rev. ed. of: Basics. 2 v. p. 5."}}),
	});
	Record out = RdaExpandAbbreviations(r);
	CHECK_EQ(out.fields[0].subfields[0].value, std::string("2nd edition"));
	// 250 $b is not in scope.
	CHECK_EQ(out.fields[0].subfields[1].value, std::string("rev. by X. / 3rd ed."));
	CHECK_EQ(out.fields[1].subfields[0].value, std::string("xii, 347 pages :"));
	CHECK_EQ(out.fields[1].subfields[1].value,
	         std::string("illustrations (some color), portraits, facsimiles ;"));
	CHECK_EQ(out.fields[1].subfields[2].value, std::string("24 cm")); // cm stays
	// Other fields never touched.
	CHECK_EQ(out.fields[2].subfields[0].value, r.fields[2].subfields[0].value);
	// Input untouched.
	CHECK_EQ(r.fields[0].subfields[0].value, std::string("2nd ed."));
}

static void TestRdaExpandBoundaries() {
	Record r = Rec({
	    DF("300", " ", " ", {{"a", "3 v. ; still. sped. v.2 p.m. 1 facsim., 1 port."}}),
	    DF("300", " ", " ", {{"a", "1 sound disc ; 12 cm"}}),
	});
	Record out = RdaExpandAbbreviations(r);
	// "still."/"sped." contain but do not end-start ill./ed.; "v.2" and
	// "p.m." have a word character after the period.
	CHECK_EQ(out.fields[0].subfields[0].value,
	         std::string("3 volumes ; still. sped. v.2 p.m. 1 facsimile, 1 portrait"));
	CHECK_EQ(out.fields[1].subfields[0].value, std::string("1 sound disc ; 12 cm"));
}

// ---- Generate33X -----------------------------------------------------------

static void Check33X(const Record &r, const char *tag, const char *term, const char *code,
                     const char *source) {
	const Field *f = FindTag(r, tag);
	CHECK(f != nullptr);
	if (!f) {
		return;
	}
	CHECK(!f->is_control);
	CHECK_EQ(f->ind1, std::string(" "));
	CHECK_EQ(f->ind2, std::string(" "));
	CHECK_EQ(f->subfields.size(), size_t(3));
	CHECK_EQ(f->subfields[0].code, std::string("a"));
	CHECK_EQ(f->subfields[0].value, std::string(term));
	CHECK_EQ(f->subfields[1].code, std::string("b"));
	CHECK_EQ(f->subfields[1].value, std::string(code));
	CHECK_EQ(f->subfields[2].code, std::string("2"));
	CHECK_EQ(f->subfields[2].value, std::string(source));
}

static void TestGenerate33XBook() {
	Record r = Rec({DF("245", "0", "0", {{"a", "T"}}), DF("500", " ", " ", {{"a", "Note."}})});
	Record out = Generate33X(r);
	CHECK_EQ(out.fields.size(), size_t(5));
	Check33X(out, "336", "text", "txt", "rdacontent");
	Check33X(out, "337", "unmediated", "n", "rdamedia");
	Check33X(out, "338", "volume", "nc", "rdacarrier");
	// Inserted in tag order, between 245 and 500.
	CHECK_EQ(out.fields[1].tag, std::string("336"));
	CHECK_EQ(out.fields[2].tag, std::string("337"));
	CHECK_EQ(out.fields[3].tag, std::string("338"));
	CHECK_EQ(out.fields[4].tag, std::string("500"));
	CHECK_EQ(r.fields.size(), size_t(2)); // input untouched
}

static void TestGenerate33XVideo() {
	Record r = Rec({CF("007", "vd cvaizu"), DF("245", "0", "0", {{"a", "T"}})});
	r.leader[6] = 'g';
	Record out = Generate33X(r);
	Check33X(out, "336", "two-dimensional moving image", "tdi", "rdacontent");
	Check33X(out, "337", "video", "v", "rdamedia");
	Check33X(out, "338", "videodisc", "vd", "rdacarrier");
}

static void TestGenerate33XAudio() {
	Record spoken = Rec({CF("007", "sd fsngnnmmned"), DF("245", "0", "0", {{"a", "T"}})});
	spoken.leader[6] = 'i';
	Record out = Generate33X(spoken);
	Check33X(out, "336", "spoken word", "spw", "rdacontent");
	Check33X(out, "337", "audio", "s", "rdamedia");
	Check33X(out, "338", "audio disc", "sd", "rdacarrier");

	Record performed = spoken;
	performed.leader[6] = 'j';
	out = Generate33X(performed);
	Check33X(out, "336", "performed music", "prm", "rdacontent");
}

static void TestGenerate33XComputer() {
	Record online = Rec({CF("007", "cr cn"), DF("245", "0", "0", {{"a", "T"}})});
	online.leader[6] = 'm';
	Record out = Generate33X(online);
	Check33X(out, "336", "computer dataset", "cod", "rdacontent");
	Check33X(out, "337", "computer", "c", "rdamedia");
	Check33X(out, "338", "online resource", "cr", "rdacarrier");

	Record disc = Rec({CF("007", "co cg"), DF("245", "0", "0", {{"a", "T"}})});
	disc.leader[6] = 'm';
	out = Generate33X(disc);
	Check33X(out, "338", "computer disc", "cd", "rdacarrier");

	// 008/26 'b' marks a computer program.
	std::string f008(40, ' ');
	f008[26] = 'b';
	Record program = Rec({CF("007", "cr cn"), CF("008", f008), DF("245", "0", "0", {{"a", "T"}})});
	program.leader[6] = 'm';
	out = Generate33X(program);
	Check33X(out, "336", "computer program", "cop", "rdacontent");
}

static void TestGenerate33XNotatedMusicAndMap() {
	Record score = Rec({DF("245", "0", "0", {{"a", "T"}})});
	score.leader[6] = 'c';
	Record out = Generate33X(score);
	Check33X(out, "336", "notated music", "ntm", "rdacontent");
	Check33X(out, "337", "unmediated", "n", "rdamedia");
	Check33X(out, "338", "volume", "nc", "rdacarrier");

	Record map = score;
	map.leader[6] = 'e';
	out = Generate33X(map);
	Check33X(out, "336", "cartographic image", "cri", "rdacontent");
}

static void TestGenerate33XCarriersFrom007Smd() {
	// Video carriers by 007/01: cassette, cartridge, reel; disc stays default.
	Record vhs = Rec({CF("007", "vf cbahou"), DF("245", "0", "0", {{"a", "T"}})});
	vhs.leader[6] = 'g';
	Record out = Generate33X(vhs);
	Check33X(out, "336", "two-dimensional moving image", "tdi", "rdacontent");
	Check33X(out, "337", "video", "v", "rdamedia");
	Check33X(out, "338", "videocassette", "vf", "rdacarrier");

	Record vreel = Rec({CF("007", "vr cbahou"), DF("245", "0", "0", {{"a", "T"}})});
	vreel.leader[6] = 'g';
	out = Generate33X(vreel);
	Check33X(out, "338", "videotape reel", "vr", "rdacarrier");

	// Sound carriers: 007/01 's' cassette, 't' tape reel; unknown SMD → disc.
	Record cassette = Rec({CF("007", "ss lsnjlc"), DF("245", "0", "0", {{"a", "T"}})});
	cassette.leader[6] = 'i';
	out = Generate33X(cassette);
	Check33X(out, "337", "audio", "s", "rdamedia");
	Check33X(out, "338", "audiocassette", "ss", "rdacarrier");

	Record reel = Rec({CF("007", "st lsnjlc"), DF("245", "0", "0", {{"a", "T"}})});
	reel.leader[6] = 'j';
	out = Generate33X(reel);
	Check33X(out, "338", "audiotape reel", "st", "rdacarrier");

	Record unknown_smd = Rec({CF("007", "sz"), DF("245", "0", "0", {{"a", "T"}})});
	unknown_smd.leader[6] = 'i';
	out = Generate33X(unknown_smd);
	Check33X(out, "338", "audio disc", "sd", "rdacarrier");

	// Electronic carriers beyond cr/cd: tape reel and card.
	Record tape = Rec({CF("007", "ch cga"), DF("245", "0", "0", {{"a", "T"}})});
	tape.leader[6] = 'm';
	out = Generate33X(tape);
	Check33X(out, "338", "computer tape reel", "ca", "rdacarrier");

	Record card = Rec({CF("007", "ck cga"), DF("245", "0", "0", {{"a", "T"}})});
	card.leader[6] = 'm';
	out = Generate33X(card);
	Check33X(out, "338", "computer card", "ck", "rdacarrier");

	// Microform: microfiche vs microfilm reel; media as before.
	Record fiche = Rec({CF("007", "he bmb024"), DF("245", "0", "0", {{"a", "T"}})});
	out = Generate33X(fiche);
	Check33X(out, "336", "text", "txt", "rdacontent");
	Check33X(out, "337", "microform", "h", "rdamedia");
	Check33X(out, "338", "microfiche", "he", "rdacarrier");

	Record film = Rec({CF("007", "hd afu"), DF("245", "0", "0", {{"a", "T"}})});
	out = Generate33X(film);
	Check33X(out, "338", "microfilm reel", "hd", "rdacarrier");
}

static void TestGenerate33XTactileAndProjected() {
	// Text leader + tactile 007: braille volume — content refines to
	// tactile text, media unmediated, carrier volume.
	Record braille = Rec({CF("007", "fb"), DF("245", "0", "0", {{"a", "T"}})});
	Record out = Generate33X(braille);
	Check33X(out, "336", "tactile text", "tct", "rdacontent");
	Check33X(out, "337", "unmediated", "n", "rdamedia");
	Check33X(out, "338", "volume", "nc", "rdacarrier");

	// Non-text leader + tactile 007: media/carrier only, content unrefined.
	Record tmap = Rec({CF("007", "fb"), DF("245", "0", "0", {{"a", "T"}})});
	tmap.leader[6] = 'e';
	out = Generate33X(tmap);
	Check33X(out, "336", "cartographic image", "cri", "rdacontent");
	Check33X(out, "337", "unmediated", "n", "rdamedia");

	// Leader g + projected-graphic 007 (slide): still image, not moving.
	Record slide = Rec({CF("007", "gs cbcjf"), DF("245", "0", "0", {{"a", "T"}})});
	slide.leader[6] = 'g';
	out = Generate33X(slide);
	Check33X(out, "336", "still image", "sti", "rdacontent");
	Check33X(out, "337", "projected", "g", "rdamedia");
	Check33X(out, "338", "slide", "gs", "rdacarrier");

	Record transparency = Rec({CF("007", "gt cbcjf"), DF("245", "0", "0", {{"a", "T"}})});
	transparency.leader[6] = 'g';
	out = Generate33X(transparency);
	Check33X(out, "338", "overhead transparency", "gt", "rdacarrier");

	// Motion-picture 007 keeps the moving-image content; carrier film reel.
	Record movie = Rec({CF("007", "mr baaa"), DF("245", "0", "0", {{"a", "T"}})});
	movie.leader[6] = 'g';
	out = Generate33X(movie);
	Check33X(out, "336", "two-dimensional moving image", "tdi", "rdacontent");
	Check33X(out, "337", "projected", "g", "rdamedia");
	Check33X(out, "338", "film reel", "mr", "rdacarrier");
}

static void TestGenerate33XContentFrom006() {
	// Mixed-material leader ('p' maps to nothing) with a computer-file 006:
	// content from 006/00, program vs dataset from 006/09.
	std::string comp006 = "m        b        ";
	Record kit = Rec({CF("006", comp006), DF("245", "0", "0", {{"a", "T"}})});
	kit.leader[6] = 'p';
	Record out = Generate33X(kit);
	Check33X(out, "336", "computer program", "cop", "rdacontent");

	std::string data006 = "m                 ";
	Record datakit = Rec({CF("006", data006), DF("245", "0", "0", {{"a", "T"}})});
	datakit.leader[6] = 'p';
	out = Generate33X(datakit);
	Check33X(out, "336", "computer dataset", "cod", "rdacontent");

	// First mapped 006 wins: an unmapped 006 ('k') is skipped for a mapped one.
	Record two006 = Rec({
	    CF("006", "k                 "),
	    CF("006", "jmusic            "),
	    DF("245", "0", "0", {{"a", "T"}}),
	});
	two006.leader[6] = 'p';
	out = Generate33X(two006);
	Check33X(out, "336", "performed music", "prm", "rdacontent");

	// A mapped leader never defers to 006: text stays text.
	Record book = Rec({CF("006", comp006), DF("245", "0", "0", {{"a", "T"}})});
	out = Generate33X(book);
	Check33X(out, "336", "text", "txt", "rdacontent");

	// Unmapped leader and only unmapped 006s: still no 336.
	Record still = Rec({CF("006", "k                 "), DF("245", "0", "0", {{"a", "T"}})});
	still.leader[6] = 'p';
	out = Generate33X(still);
	CHECK(FindTag(out, "336") == nullptr);
}

static void TestGenerate33XExistingAndUndetermined() {
	// An existing 336 is never replaced or duplicated; 337/338 still added.
	Record r = Rec({
	    DF("245", "0", "0", {{"a", "T"}}),
	    DF("336", " ", " ", {{"a", "tactile text"}, {"b", "tct"}, {"2", "rdacontent"}}),
	});
	Record out = Generate33X(r);
	int n336 = 0;
	for (auto &f : out.fields) {
		if (f.tag == "336") {
			n336++;
		}
	}
	CHECK_EQ(n336, 1);
	CHECK_EQ(FindTag(out, "336")->subfields[0].value, std::string("tactile text"));
	Check33X(out, "337", "unmediated", "n", "rdamedia");
	Check33X(out, "338", "volume", "nc", "rdacarrier");

	// Video with no 007: content only — media/carrier are not guessed.
	Record vid = Rec({DF("245", "0", "0", {{"a", "T"}})});
	vid.leader[6] = 'g';
	out = Generate33X(vid);
	CHECK(FindTag(out, "336") != nullptr);
	CHECK(FindTag(out, "337") == nullptr);
	CHECK(FindTag(out, "338") == nullptr);

	// An undetermined Leader/06 ('k' still image is unmapped) adds no 336.
	Record still = Rec({DF("245", "0", "0", {{"a", "T"}})});
	still.leader[6] = 'k';
	out = Generate33X(still);
	CHECK(FindTag(out, "336") == nullptr);
}

int main() {
	TestEncodingLevelOrder();
	TestCompleteness();
	TestRankingMonotonicity();
	TestNewRecordTemplates();
	TestNewRecordAuthority();
	TestNewRecordUnknown();
	TestRdaExpand();
	TestRdaExpandBoundaries();
	TestGenerate33XBook();
	TestGenerate33XVideo();
	TestGenerate33XAudio();
	TestGenerate33XComputer();
	TestGenerate33XNotatedMusicAndMap();
	TestGenerate33XCarriersFrom007Smd();
	TestGenerate33XTactileAndProjected();
	TestGenerate33XContentFrom006();
	TestGenerate33XExistingAndUndetermined();
	return CHECKS_MAIN_RESULT();
}
