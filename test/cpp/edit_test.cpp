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

int main() {
	TestAddField();
	TestRemoveFields();
	TestSetSubfield();
	TestReplaceInValues();
	TestSetIndicators();
	TestMerge();
	TestRenderAndDiff();
	return CHECKS_MAIN_RESULT();
}
