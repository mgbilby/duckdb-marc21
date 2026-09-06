// Standalone tests for the record editing / merge / diff module:
//   g++ -std=c++17 -Wall -O2 -Isrc/include src/core/*.cpp test/cpp/edit_test.cpp -o edit_test && ./edit_test
#include "checks.hpp"

#include "marc/edit.hpp"

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
	r.leader = "00000nam a2200000 a 4500";
	r.fields = std::move(fields);
	return r;
}

static Record Sample() {
	return Rec({
	    CF("001", "abc123"),
	    CF("008", "970101s1997    nyu           000 0 eng d"),
	    DF("245", "1", "0", {{"a", "Cooking basics :"}, {"b", "a primer."}}),
	    DF("650", " ", "0", {{"a", "Cooking."}, {"x", "History."}}),
	    DF("650", " ", "7", {{"a", "Cookery."}, {"2", "fast"}}),
	    DF("651", " ", "0", {{"a", "France."}}),
	    DF("700", "1", " ", {{"a", "Smith, Jane."}}),
	});
}

template <class F>
static bool ThrowsMarc(F fn) {
	try {
		fn();
	} catch (const MarcError &) {
		return true;
	}
	return false;
}

static void TestAddField() {
	Record r = Sample();
	Record out = AddField(r, DF("100", "1", " ", {{"a", "Doe, John."}}));
	CHECK_EQ(out.fields.size(), size_t(8));
	CHECK_EQ(out.fields[2].tag, std::string("100")); // between 008 and 245
	CHECK_EQ(r.fields.size(), size_t(7));            // input untouched

	// A repeated tag's new occurrence lands after the existing group.
	out = AddField(r, DF("650", " ", "0", {{"a", "Baking."}}));
	CHECK_EQ(out.fields[5].tag, std::string("650"));
	CHECK_EQ(out.fields[5].subfields[0].value, std::string("Baking."));
	CHECK_EQ(out.fields[6].tag, std::string("651"));

	out = AddField(r, DF("100", "1", " ", {{"a", "Doe."}}), InsertPosition::END);
	CHECK_EQ(out.fields.back().tag, std::string("100"));

	CHECK(ThrowsMarc([&] { AddField(r, DF("65", " ", " ", {})); }));
	CHECK(ThrowsMarc([&] { AddField(r, DF("6.0", " ", " ", {})); }));
}

static void TestRemoveFields() {
	Record r = Sample();

	FieldSelector wild;
	wild.tag = "6..";
	Record out = RemoveFields(r, wild);
	CHECK_EQ(out.fields.size(), size_t(4));
	CHECK_EQ(out.fields[3].tag, std::string("700"));

	FieldSelector ind;
	ind.tag = "650";
	ind.ind2 = "0";
	out = RemoveFields(r, ind);
	CHECK_EQ(out.fields.size(), size_t(6));
	CHECK_EQ(out.fields[3].ind2, std::string("7")); // the $2 fast one stays

	// Case-insensitive value regex on a named subfield.
	FieldSelector re;
	re.tag = "650";
	re.subfield_code = "a";
	re.value_regex = "^cook";
	re.value_regex_icase = true;
	out = RemoveFields(r, re);
	CHECK_EQ(out.fields.size(), size_t(5));
	re.value_regex_icase = false;
	out = RemoveFields(r, re);
	CHECK_EQ(out.fields.size(), size_t(7)); // "Cooking." !~ "^cook" case-sensitively

	FieldSelector occ;
	occ.tag = "650";
	occ.occurrence = 1;
	out = RemoveFields(r, occ);
	CHECK_EQ(out.fields.size(), size_t(6));
	CHECK_EQ(out.fields[3].subfields[0].value, std::string("Cooking."));
	occ.occurrence = 5; // out of range selects nothing
	out = RemoveFields(r, occ);
	CHECK_EQ(out.fields.size(), size_t(7));

	// Subfield-only removal; a field losing its last subfield is dropped.
	FieldSelector subx;
	subx.tag = "650";
	subx.subfield_code = "x";
	out = RemoveFields(r, subx, true);
	CHECK_EQ(out.fields.size(), size_t(7));
	CHECK_EQ(out.fields[3].subfields.size(), size_t(1));
	CHECK_EQ(out.fields[3].subfields[0].code, std::string("a"));

	Record lone = Rec({DF("650", " ", "0", {{"x", "History."}})});
	FieldSelector onlyx;
	onlyx.tag = "650";
	onlyx.subfield_code = "x";
	out = RemoveFields(lone, onlyx, true);
	CHECK_EQ(out.fields.size(), size_t(0));

	FieldSelector nocode;
	nocode.tag = "650";
	CHECK(ThrowsMarc([&] { RemoveFields(r, nocode, true); }));
	FieldSelector badtag;
	badtag.tag = "65";
	CHECK(ThrowsMarc([&] { RemoveFields(r, badtag); }));
	badtag.tag = "6$0";
	CHECK(ThrowsMarc([&] { RemoveFields(r, badtag); }));
	FieldSelector badre;
	badre.tag = "650";
	badre.subfield_code = "a";
	badre.value_regex = "(unclosed";
	CHECK(ThrowsMarc([&] { RemoveFields(r, badre); }));
	FieldSelector orphan;
	orphan.tag = "650";
	orphan.value_regex = "x";
	CHECK(ThrowsMarc([&] { RemoveFields(r, orphan); }));
}

static void TestSetSubfield() {
	Record r = Sample();
	FieldSelector all650;
	all650.tag = "650";

	Record out = SetSubfield(r, all650, "a", "Food.", false);
	CHECK_EQ(out.fields[3].subfields[0].value, std::string("Food."));
	CHECK_EQ(out.fields[4].subfields[0].value, std::string("Food."));
	CHECK_EQ(r.fields[3].subfields[0].value, std::string("Cooking.")); // input untouched

	out = SetSubfield(r, all650, "0", "(uri)x1", true);
	CHECK_EQ(out.fields[3].subfields.back().code, std::string("0"));
	CHECK_EQ(out.fields[3].subfields.back().value, std::string("(uri)x1"));
	out = SetSubfield(r, all650, "0", "(uri)x1", false);
	CHECK_EQ(out.fields[3].subfields.size(), size_t(2)); // nothing appended

	// Every occurrence of the code in one field is replaced.
	Record multi = Rec({DF("650", " ", "0", {{"a", "One."}, {"a", "Two."}})});
	out = SetSubfield(multi, all650, "a", "X.", false);
	CHECK_EQ(out.fields[0].subfields[0].value, std::string("X."));
	CHECK_EQ(out.fields[0].subfields[1].value, std::string("X."));

	// Control fields the selector matches are left untouched.
	FieldSelector any;
	any.tag = "...";
	out = SetSubfield(r, any, "a", "zap", true);
	CHECK(out.fields[0].is_control);
	CHECK_EQ(out.fields[0].control_value, std::string("abc123"));

	CHECK(ThrowsMarc([&] { SetSubfield(r, all650, "ab", "v", true); }));
}

static void TestReplaceInValues() {
	Record r = Sample();
	FieldSelector all;
	all.tag = "...";

	Record out = ReplaceInValues(r, all, "\\.$", "", ValueDomain::DATA);
	CHECK_EQ(out.fields[3].subfields[0].value, std::string("Cooking"));
	CHECK_EQ(out.fields[2].subfields[1].value, std::string("a primer"));
	CHECK_EQ(out.fields[0].control_value, std::string("abc123")); // control untouched

	FieldSelector f008;
	f008.tag = "008";
	out = ReplaceInValues(r, f008, "^970101", "220505", ValueDomain::CONTROL);
	CHECK_EQ(out.fields[1].control_value.substr(0, 6), std::string("220505"));

	// Capture-group backreference, restricted to the selector's subfield code.
	FieldSelector sub2;
	sub2.tag = "650";
	sub2.subfield_code = "2";
	out = ReplaceInValues(r, sub2, "^(f)ast$", "$1lash", ValueDomain::BOTH);
	CHECK_EQ(out.fields[4].subfields[1].value, std::string("flash"));
	CHECK_EQ(out.fields[4].subfields[0].value, std::string("Cookery.")); // other codes untouched

	out = ReplaceInValues(r, all, "COOK", "Bak", ValueDomain::BOTH, true);
	CHECK_EQ(out.fields[3].subfields[0].value, std::string("Baking."));

	CHECK(ThrowsMarc([&] { ReplaceInValues(r, all, "(", "x", ValueDomain::BOTH); }));
}

static void TestSetIndicators() {
	Record r = Sample();
	FieldSelector f245;
	f245.tag = "245";
	Record out = SetIndicators(r, f245, std::nullopt, "4");
	CHECK_EQ(out.fields[2].ind1, std::string("1"));
	CHECK_EQ(out.fields[2].ind2, std::string("4"));

	FieldSelector any;
	any.tag = "...";
	out = SetIndicators(r, any, "0", std::nullopt);
	CHECK(out.fields[0].is_control); // control fields skipped
	CHECK_EQ(out.fields[6].ind1, std::string("0"));

	CHECK(ThrowsMarc([&] { SetIndicators(r, f245, std::string("ab"), std::nullopt); }));
	CHECK(ThrowsMarc([&] { SetIndicators(r, f245, std::nullopt, std::string("")); }));
}

static void TestMerge() {
	Record base = Rec({
	    CF("001", "base1"),
	    DF("035", " ", " ", {{"a", "(X)1"}}),
	    DF("245", "1", "0", {{"a", "Base title."}}),
	    DF("650", " ", "0", {{"a", "Old subject."}}),
	    DF("700", "1", " ", {{"a", "Base, Author."}}),
	});
	Record incoming = Rec({
	    CF("001", "inc1"),
	    DF("035", " ", " ", {{"a", "(Y)2"}}),
	    DF("245", "1", "4", {{"a", "Incoming title."}}),
	    DF("260", " ", " ", {{"c", "2020."}}),
	    DF("650", " ", "0", {{"a", "New subject A."}}),
	    DF("650", " ", "7", {{"a", "New subject B."}}),
	});
	incoming.leader = "00000cam a2200000 a 4500";

	MergeProfile p;
	p.protected_tags = {"245", "0.."};
	p.replace_tags = {"6.."};
	p.add_tags = {"035"};
	p.default_action = MergeAction::KEEP;
	// 001 and 035 both match "0.." — protected wins over add by precedence.
	p.protected_tags.push_back("001");

	Record out = MergeRecords(base, incoming, p);
	CHECK_EQ(out.leader, base.leader);
	CHECK_EQ(out.fields.size(), size_t(7)); // 035 protected by "0..", not added
	CHECK_EQ(out.fields[0].control_value, std::string("base1"));
	CHECK_EQ(out.fields[1].subfields[0].value, std::string("(X)1"));
	CHECK_EQ(out.fields[2].subfields[0].value, std::string("Base title."));
	CHECK_EQ(out.fields[3].subfields[0].value, std::string("2020.")); // KEEP fills the gap
	CHECK_EQ(out.fields[4].subfields[0].value, std::string("New subject A."));
	CHECK_EQ(out.fields[5].subfields[0].value, std::string("New subject B."));
	CHECK_EQ(out.fields[6].tag, std::string("700")); // 650s replaced in place, 700 after

	// Same merge without the "0.." protection: 035 is add-listed.
	MergeProfile p2;
	p2.protected_tags = {"245"};
	p2.replace_tags = {"650"};
	p2.add_tags = {"035"};
	out = MergeRecords(base, incoming, p2);
	CHECK_EQ(out.fields.size(), size_t(8));
	CHECK_EQ(out.fields[1].subfields[0].value, std::string("(X)1"));
	CHECK_EQ(out.fields[2].subfields[0].value, std::string("(Y)2")); // appended after base 035
	CHECK_EQ(out.fields[5].subfields[0].value, std::string("New subject A."));
	CHECK_EQ(out.fields[6].subfields[0].value, std::string("New subject B."));

	// default REPLACE overwrites unlisted tags; KEEP would have ignored them.
	MergeProfile p3;
	p3.default_action = MergeAction::REPLACE;
	out = MergeRecords(base, incoming, p3);
	CHECK_EQ(out.fields[0].control_value, std::string("inc1"));
	CHECK_EQ(out.fields[2].subfields[0].value, std::string("Incoming title."));
	CHECK_EQ(out.fields[6].tag, std::string("700")); // base-only tag always kept

	MergeProfile p4;
	p4.default_action = MergeAction::KEEP;
	out = MergeRecords(base, incoming, p4);
	CHECK_EQ(out.fields.size(), size_t(6)); // only 260 fills a gap
	CHECK_EQ(out.fields[3].tag, std::string("260"));

	Record bare;
	out = MergeRecords(bare, incoming, p4);
	CHECK_EQ(out.leader, incoming.leader); // empty base leader falls back
	CHECK_EQ(out.fields.size(), incoming.fields.size());

	MergeProfile bad;
	bad.replace_tags = {"65"};
	CHECK(ThrowsMarc([&] { MergeRecords(base, incoming, bad); }));
}

static void TestRenderAndDiff() {
	Field data = DF("245", "1", " ", {{"a", "Costs $5."}});
	CHECK_EQ(RenderFieldBreaker(data), std::string("=245  1\\$aCosts {dollar}5."));
	CHECK_EQ(RenderFieldBreaker(CF("001", "abc123")), std::string("=001  abc123"));

	Record a = Sample();
	CHECK(DiffRecords(a, a).empty());

	Record b = Sample();
	b.fields[2].subfields[0].value = "Cooking mastery :";     // 245 changed
	b.fields.erase(b.fields.begin() + 4);                     // second 650 removed
	b.fields.push_back(DF("710", "2", " ", {{"a", "Acme."}})); // 710 added

	auto diff = DiffRecords(a, b);
	CHECK_EQ(diff.size(), size_t(3));
	CHECK(diff[0].kind == DiffKind::CHANGED);
	CHECK_EQ(diff[0].tag, std::string("245"));
	CHECK_EQ(diff[0].rendered_a, std::string("=245  10$aCooking basics :$ba primer."));
	CHECK_EQ(diff[0].rendered_b, std::string("=245  10$aCooking mastery :$ba primer."));
	CHECK(diff[0].field_no_a && *diff[0].field_no_a == 2);

	CHECK(diff[1].kind == DiffKind::REMOVED);
	CHECK_EQ(diff[1].tag, std::string("650"));
	CHECK(diff[1].field_no_a && *diff[1].field_no_a == 4); // pairs by (tag, occurrence)
	CHECK(!diff[1].field_no_b);
	CHECK_EQ(diff[1].rendered_b, std::string(""));

	CHECK(diff[2].kind == DiffKind::ADDED);
	CHECK_EQ(diff[2].tag, std::string("710"));
	CHECK(!diff[2].field_no_a);
	CHECK_EQ(diff[2].rendered_b, std::string("=710  2\\$aAcme."));

	Record c = Sample();
	c.leader = "00000cam a2200000 a 4500";
	diff = DiffRecords(a, c);
	CHECK_EQ(diff.size(), size_t(1));
	CHECK(diff[0].kind == DiffKind::CHANGED);
	CHECK_EQ(diff[0].tag, std::string("LDR"));
	CHECK(!diff[0].field_no_a && !diff[0].field_no_b);
	CHECK_EQ(diff[0].rendered_b, std::string("=LDR  00000cam a2200000 a 4500"));
}

static void TestMoveField() {
	Record r = Sample();
	Record out = MoveField(r, "650", "690");
	CHECK_EQ(out.fields.size(), size_t(7));
	CHECK_EQ(out.fields[3].tag, std::string("690")); // renumbered in place
	CHECK_EQ(out.fields[4].tag, std::string("690"));
	CHECK_EQ(out.fields[3].subfields[0].value, std::string("Cooking."));
	CHECK_EQ(out.fields[3].ind2, std::string("0")); // indicators kept
	CHECK_EQ(out.fields[5].tag, std::string("651")); // order kept, not re-sorted
	CHECK_EQ(r.fields[3].tag, std::string("650"));   // input untouched

	// Wildcard source: every 6XX renumbers.
	out = MoveField(r, "6..", "690");
	CHECK_EQ(out.fields[3].tag, std::string("690"));
	CHECK_EQ(out.fields[4].tag, std::string("690"));
	CHECK_EQ(out.fields[5].tag, std::string("690"));

	// Control-to-control moves work; no match is a no-op.
	out = MoveField(r, "001", "003");
	CHECK(out.fields[0].is_control);
	CHECK_EQ(out.fields[0].tag, std::string("003"));
	CHECK_EQ(out.fields[0].control_value, std::string("abc123"));
	out = MoveField(r, "999", "998");
	CHECK_EQ(DiffRecords(r, out).size(), size_t(0));

	CHECK(ThrowsMarc([&] { MoveField(r, "245", "007"); })); // data → control
	CHECK(ThrowsMarc([&] { MoveField(r, "001", "901"); })); // control → data
	CHECK(ThrowsMarc([&] { MoveField(r, "65", "690"); }));
	CHECK(ThrowsMarc([&] { MoveField(r, "650", "6.0"); })); // wildcard target
	CHECK(ThrowsMarc([&] { MoveField(r, "650", "69"); }));
}

static void TestCopyField() {
	Record r = Sample();
	Record out = CopyField(r, "245", "246");
	CHECK_EQ(out.fields.size(), size_t(8));
	CHECK_EQ(out.fields[2].tag, std::string("245")); // original stays
	CHECK_EQ(out.fields[3].tag, std::string("246")); // copy in tag order
	CHECK_EQ(out.fields[3].subfields[1].value, std::string("a primer."));
	CHECK_EQ(out.fields[3].ind1, std::string("1"));
	CHECK_EQ(r.fields.size(), size_t(7)); // input untouched

	// Two 650s copy as two 690s, source order preserved, after the 651.
	out = CopyField(r, "650", "690");
	CHECK_EQ(out.fields.size(), size_t(9));
	CHECK_EQ(out.fields[6].tag, std::string("690"));
	CHECK_EQ(out.fields[6].subfields[0].value, std::string("Cooking."));
	CHECK_EQ(out.fields[7].subfields[0].value, std::string("Cookery."));
	CHECK_EQ(out.fields[8].tag, std::string("700"));

	// Control copies allowed within the boundary; no match is a no-op.
	out = CopyField(r, "001", "003");
	CHECK_EQ(out.fields[1].tag, std::string("003"));
	CHECK_EQ(out.fields[1].control_value, std::string("abc123"));
	out = CopyField(r, "999", "998");
	CHECK_EQ(out.fields.size(), size_t(7));

	CHECK(ThrowsMarc([&] { CopyField(r, "245", "008"); }));
	CHECK(ThrowsMarc([&] { CopyField(r, "008", "500"); }));
	CHECK(ThrowsMarc([&] { CopyField(r, "245", "2.6"); }));
}

static void TestSwapFields() {
	Record r = Sample();

	// Every 650 becomes 651 and vice versa, order and indicators preserved.
	Record out = SwapFields(r, "650", "651");
	CHECK_EQ(out.fields.size(), size_t(7));
	CHECK_EQ(out.fields[3].tag, std::string("651"));
	CHECK_EQ(out.fields[3].ind2, std::string("0")); // indicators kept
	CHECK_EQ(out.fields[3].subfields[0].value, std::string("Cooking."));
	CHECK_EQ(out.fields[4].tag, std::string("651"));
	CHECK_EQ(out.fields[5].tag, std::string("650")); // the old 651, in place
	CHECK_EQ(out.fields[5].subfields[0].value, std::string("France."));
	CHECK_EQ(r.fields[3].tag, std::string("650")); // input untouched

	// Swapping back restores the record exactly.
	CHECK_EQ(DiffRecords(r, SwapFields(out, "650", "651")).size(), size_t(0));

	// One side absent = plain retag of the other; both absent = no-op;
	// swapping a tag with itself = no-op.
	out = SwapFields(r, "245", "246");
	CHECK_EQ(out.fields[2].tag, std::string("246"));
	CHECK_EQ(DiffRecords(r, SwapFields(r, "946", "947")).size(), size_t(0));
	CHECK_EQ(DiffRecords(r, SwapFields(r, "650", "650")).size(), size_t(0));

	// Control-control swaps work (001 ↔ 008, values travel with the tags).
	out = SwapFields(r, "001", "008");
	CHECK(out.fields[0].is_control);
	CHECK_EQ(out.fields[0].tag, std::string("008"));
	CHECK_EQ(out.fields[0].control_value, std::string("abc123"));
	CHECK_EQ(out.fields[1].tag, std::string("001"));

	// Control/data boundary and tag validation errors.
	CHECK(ThrowsMarc([&] { SwapFields(r, "001", "650"); })); // boundary
	CHECK(ThrowsMarc([&] { SwapFields(r, "245", "008"); })); // boundary
	CHECK(ThrowsMarc([&] { SwapFields(r, "6..", "651"); })); // wildcard
	CHECK(ThrowsMarc([&] { SwapFields(r, "650", "65"); }));  // short tag
}

static void TestSortFields() {
	Record r = Rec({
	    CF("008", "970101s1997"),
	    DF("650", " ", "0", {{"a", "First 650."}}),
	    DF("245", "1", "0", {{"a", "A title."}}),
	    CF("001", "abc123"),
	    DF("650", " ", "7", {{"a", "Second 650."}}),
	    DF("100", "1", " ", {{"a", "Smith, Jane."}}),
	});
	Record out = SortFields(r);
	CHECK_EQ(out.fields.size(), size_t(6));
	CHECK_EQ(out.fields[0].tag, std::string("001"));
	CHECK_EQ(out.fields[1].tag, std::string("008"));
	CHECK_EQ(out.fields[2].tag, std::string("100"));
	CHECK_EQ(out.fields[3].tag, std::string("245"));
	// Stable: the two 650s keep their occurrence order and indicators.
	CHECK_EQ(out.fields[4].subfields[0].value, std::string("First 650."));
	CHECK_EQ(out.fields[4].ind2, std::string("0"));
	CHECK_EQ(out.fields[5].subfields[0].value, std::string("Second 650."));
	CHECK_EQ(r.fields[0].tag, std::string("008")); // input untouched

	// Already-sorted input round-trips unchanged.
	CHECK_EQ(DiffRecords(SortFields(out), out).size(), size_t(0));
}

static void TestRenameSubfield() {
	Record r = Sample();
	Record out = RenameSubfield(r, "650", "x", "z");
	CHECK_EQ(out.fields[3].subfields[1].code, std::string("z"));
	CHECK_EQ(out.fields[3].subfields[1].value, std::string("History."));
	CHECK_EQ(out.fields[3].subfields.size(), size_t(2)); // order/count kept
	CHECK_EQ(r.fields[3].subfields[1].code, std::string("x")); // input untouched

	// Wildcard tag pattern; codes absent from a matching field are a no-op.
	out = RenameSubfield(r, "6..", "2", "5");
	CHECK_EQ(out.fields[4].subfields[1].code, std::string("5"));
	CHECK_EQ(out.fields[5].subfields[0].code, std::string("a")); // 651 untouched

	// Control fields never match, even under "...".
	out = RenameSubfield(r, "...", "a", "b");
	CHECK_EQ(out.fields[0].control_value, std::string("abc123"));
	CHECK_EQ(out.fields[2].subfields[0].code, std::string("b"));

	CHECK(ThrowsMarc([&] { RenameSubfield(r, "65", "x", "z"); }));
	CHECK(ThrowsMarc([&] { RenameSubfield(r, "650", "xy", "z"); }));
	CHECK(ThrowsMarc([&] { RenameSubfield(r, "650", "x", ""); }));
}

static void TestApplyReplaceRules() {
	Record r = Sample();

	// Rules apply in order; the second rule sees the first one's output.
	std::vector<ReplaceRule> rules;
	rules.push_back({"650", std::string("a"), "^Cookery", "Cooking"});
	rules.push_back({"650", std::string("a"), "Cooking", "Baking"});
	Record out = ApplyReplaceRules(r, rules);
	CHECK_EQ(out.fields[3].subfields[0].value, std::string("Baking."));
	CHECK_EQ(out.fields[4].subfields[0].value, std::string("Baking."));
	CHECK_EQ(r.fields[3].subfields[0].value, std::string("Cooking.")); // input untouched

	// A NULL code hits every subfield; control values are in scope too.
	rules.clear();
	rules.push_back({"650", std::nullopt, "\\.$", "!"});
	rules.push_back({"008", std::nullopt, "eng", "fre"});
	out = ApplyReplaceRules(r, rules);
	CHECK_EQ(out.fields[3].subfields[1].value, std::string("History!"));
	CHECK(out.fields[1].control_value.find("fre") != std::string::npos);

	// Empty rule list is the identity.
	CHECK_EQ(DiffRecords(r, ApplyReplaceRules(r, {})).size(), size_t(0));

	// Errors name the offending rule.
	rules.clear();
	rules.push_back({"650", std::nullopt, "fine", "ok"});
	rules.push_back({"650", std::nullopt, "(unclosed", "x"});
	try {
		ApplyReplaceRules(r, rules);
		CHECK(false);
	} catch (const MarcError &e) {
		CHECK(std::string(e.what()).find("rule 2") != std::string::npos);
	}
	rules.clear();
	rules.push_back({"65", std::nullopt, "x", "y"});
	CHECK(ThrowsMarc([&] { ApplyReplaceRules(r, rules); }));
}

static void TestChangeCase() {
	Record r = Rec({
	    CF("008", "970101s1997"),
	    DF("245", "1", "0", {{"a", "the CAFÉ at ÎLE d'or :"}, {"b", "eine STRAßE."}}),
	    DF("650", " ", "0", {{"a", "straße Ÿz"}, {"x", "HISTORY"}}),
	});

	Record out = ChangeCase(r, "245", "a", CaseMode::UPPER);
	CHECK_EQ(out.fields[1].subfields[0].value, std::string("THE CAFÉ AT ÎLE D'OR :"));
	CHECK_EQ(out.fields[1].subfields[1].value, std::string("eine STRAßE.")); // other code untouched
	CHECK_EQ(r.fields[1].subfields[0].value, std::string("the CAFÉ at ÎLE d'or :")); // input untouched

	// "*" hits every subfield; ß upper-cases to SS.
	out = ChangeCase(r, "245", "*", CaseMode::UPPER);
	CHECK_EQ(out.fields[1].subfields[1].value, std::string("EINE STRASSE."));

	out = ChangeCase(r, "650", "a", CaseMode::LOWER);
	CHECK_EQ(out.fields[2].subfields[0].value, std::string("straße ÿz")); // Ÿ → ÿ
	out = ChangeCase(r, "650", "", CaseMode::LOWER);                      // "" = all
	CHECK_EQ(out.fields[2].subfields[1].value, std::string("history"));

	// Title case: word starts after separators; Latin-1 letters case; the
	// apostrophe separates ("d'or" → "D'Or").
	out = ChangeCase(r, "245", "a", CaseMode::TITLE);
	CHECK_EQ(out.fields[1].subfields[0].value, std::string("The Café At Île D'Or :"));
	out = ChangeCase(r, "245", "b", CaseMode::TITLE);
	CHECK_EQ(out.fields[1].subfields[1].value, std::string("Eine Straße."));

	// Digits hold word starts ("3rd" not "3Rd"); unknown scripts pass through
	// but still count as word-internal.
	Record digits = Rec({DF("500", " ", " ", {{"a", "3rd ed. 日本 abc"}})});
	out = ChangeCase(digits, "500", "a", CaseMode::TITLE);
	CHECK_EQ(out.fields[0].subfields[0].value, std::string("3rd Ed. 日本 Abc"));

	// Control fields are never touched, even by a matching pattern.
	out = ChangeCase(r, "...", "*", CaseMode::UPPER);
	CHECK_EQ(out.fields[0].control_value, std::string("970101s1997"));

	CHECK(ThrowsMarc([&] { ChangeCase(r, "24", "a", CaseMode::UPPER); }));
	CHECK(ThrowsMarc([&] { ChangeCase(r, "245", "ab", CaseMode::UPPER); }));
}

static void TestBuildField() {
	Record r = Sample();
	Record out = BuildField(r, "=953  \\\\$a{245$a} / {700$a}");
	CHECK_EQ(out.fields.size(), size_t(8));
	const Field &f = out.fields[7]; // 953 sorts after 700 in tag order
	CHECK_EQ(f.tag, std::string("953"));
	CHECK_EQ(f.ind1, std::string(" "));
	CHECK_EQ(f.ind2, std::string(" "));
	CHECK_EQ(f.subfields.size(), size_t(1));
	CHECK_EQ(f.subfields[0].value, std::string("Cooking basics : / Smith, Jane."));
	CHECK_EQ(r.fields.size(), size_t(7)); // input untouched

	// Wildcard tag takes the FIRST matching subfield; a missing placeholder
	// substitutes ""; literal indicators and multiple codes work.
	out = BuildField(r, "=940  01$a{6..$a}$b{100$a}end");
	const Field &g = out.fields[7];
	CHECK_EQ(g.ind1, std::string("0"));
	CHECK_EQ(g.ind2, std::string("1"));
	CHECK_EQ(g.subfields[0].value, std::string("Cooking."));
	CHECK_EQ(g.subfields[1].value, std::string("end")); // {100$a} → ""

	// A substituted value's '$' stays literal, and {dollar} in the template
	// itself still means '$'.
	Record money = Rec({DF("245", "0", "0", {{"a", "Costs $5"}})});
	out = BuildField(money, "=500  \\\\$a{245$a} for {dollar}2");
	CHECK_EQ(out.fields[1].subfields[0].value, std::string("Costs $5 for $2"));

	// Non-placeholder braces pass through verbatim (a literal '$' outside a
	// placeholder is still a breaker subfield delimiter — write {dollar}).
	out = BuildField(money, "=500  \\\\$a{brace} {245}");
	CHECK_EQ(out.fields[1].subfields[0].value, std::string("{brace} {245}"));

	CHECK(ThrowsMarc([&] { BuildField(r, "not a field line"); }));
	CHECK(ThrowsMarc([&] { BuildField(r, "=95"); }));
	CHECK(ThrowsMarc([&] { BuildField(r, "=LDR  00000nam a2200000 a 4500"); }));
}

static void TestRemoveFieldsWhere() {
	Record r = Sample();
	Record out = RemoveFieldsWhere(r, "650", "a", "^Cook");
	CHECK_EQ(out.fields.size(), size_t(5)); // both 650s start with Cook
	CHECK_EQ(out.fields[3].tag, std::string("651"));
	CHECK_EQ(r.fields.size(), size_t(7)); // input untouched

	out = RemoveFieldsWhere(r, "6..", "2", "^fast$");
	CHECK_EQ(out.fields.size(), size_t(6)); // only the $2 fast 650 goes
	CHECK_EQ(out.fields[3].subfields[0].value, std::string("Cooking."));

	// Search semantics (substring), case-insensitivity flag, no-match no-op.
	out = RemoveFieldsWhere(r, "650", "a", "ery");
	CHECK_EQ(out.fields.size(), size_t(6));
	out = RemoveFieldsWhere(r, "650", "a", "COOK");
	CHECK_EQ(out.fields.size(), size_t(7));
	out = RemoveFieldsWhere(r, "650", "a", "COOK", true);
	CHECK_EQ(out.fields.size(), size_t(5));
	out = RemoveFieldsWhere(r, "650", "x", "nothing matches");
	CHECK_EQ(out.fields.size(), size_t(7));

	CHECK(ThrowsMarc([&] { RemoveFieldsWhere(r, "65", "a", "x"); }));
	CHECK(ThrowsMarc([&] { RemoveFieldsWhere(r, "650", "ab", "x"); }));
	CHECK(ThrowsMarc([&] { RemoveFieldsWhere(r, "650", "a", "(unclosed"); }));
}

int main() {
	TestAddField();
	TestRemoveFields();
	TestSetSubfield();
	TestReplaceInValues();
	TestSetIndicators();
	TestMerge();
	TestRenderAndDiff();
	TestMoveField();
	TestCopyField();
	TestSwapFields();
	TestSortFields();
	TestRenameSubfield();
	TestApplyReplaceRules();
	TestChangeCase();
	TestBuildField();
	TestRemoveFieldsWhere();
	return CHECKS_MAIN_RESULT();
}
