// SocketTransport over a real loopback TCP connection: a scripted server
// thread answers Init/Search/Present, including a deliberately split (partial
// send) response to exercise APDU re-framing over sockets.  Protocol details
// themselves are covered by z3950_test.cpp against the mock transport.
#include "marc/core.hpp"
#include "marc/z3950.hpp"
#include "marc/z3950_socket.hpp"

#include "checks.hpp"

#include <chrono>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
using socket_t = SOCKET;
static void CloseSock(socket_t s) {
	closesocket(s);
}
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
using socket_t = int;
static const socket_t INVALID_SOCKET = -1;
static void CloseSock(socket_t s) {
	close(s);
}
#endif

using namespace marc;

// ---- minimal APDU builders (mirrors of the z3950_test.cpp helpers) ---------

static std::string C(uint32_t n, std::string_view content) {
	return ber::Tlv(ber::Class::CONTEXT, false, n, content);
}
static std::string CS(uint32_t n, std::string_view content) {
	return ber::Tlv(ber::Class::CONTEXT, true, n, content);
}
static std::string US(std::string_view content) {
	return ber::Tlv(ber::Class::UNIVERSAL, true, ber::TAG_SEQUENCE, content);
}
static std::string I(int64_t v) {
	return ber::IntegerContent(v);
}

static std::string InitResponseApdu() {
	std::string body;
	body += C(3, ber::BitStringContent({0, 1}));
	body += C(4, ber::BitStringContent({0, 1}));
	body += C(5, I(1 << 20));
	body += C(6, I(4 << 20));
	body += C(12, "\xFF");
	return CS(21, body);
}

static std::string SearchResponseApdu(int64_t count) {
	std::string body;
	body += C(23, I(count));
	body += C(24, I(0));
	body += C(25, I(1));
	body += C(22, "\xFF");
	return CS(23, body);
}

static std::string NamePlusRecord(std::string_view iso2709) {
	std::string external = ber::Tlv(ber::Class::UNIVERSAL, false, ber::TAG_OID, ber::OidContent({1, 2, 840, 10003, 5, 10}));
	external += C(1, iso2709);
	return US(CS(1, CS(1, external)));
}

static std::string PresentResponseApdu(const std::vector<std::string> &recs, int64_t next_pos) {
	std::string body;
	body += C(24, I(static_cast<int64_t>(recs.size())));
	body += C(25, I(next_pos));
	body += C(27, I(0));
	std::string list;
	for (const auto &r : recs) {
		list += NamePlusRecord(r);
	}
	body += CS(28, list);
	return CS(25, body);
}

static std::string FakeIso2709(const std::string &control_number, const std::string &title) {
	Record rec;
	rec.leader = "00000nam a2200000 a 4500";
	Field f001;
	f001.tag = "001";
	f001.is_control = true;
	f001.control_value = control_number;
	rec.fields.push_back(f001);
	Field f245;
	f245.tag = "245";
	f245.ind1 = "1";
	f245.ind2 = "0";
	f245.subfields.push_back({"a", title});
	rec.fields.push_back(f245);
	return WriteRecord(rec);
}

// ---- scripted loopback server ----------------------------------------------

//! Listen on 127.0.0.1:ephemeral; returns the socket and fills `port`.
static socket_t Listen(uint16_t &port) {
	socket_t s = socket(AF_INET, SOCK_STREAM, 0);
	CHECK(s != INVALID_SOCKET);
	struct sockaddr_in addr;
	std::memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	addr.sin_port = 0;
	CHECK(bind(s, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) == 0);
	CHECK(listen(s, 1) == 0);
#ifdef _WIN32
	int len = sizeof(addr);
#else
	socklen_t len = sizeof(addr);
#endif
	CHECK(getsockname(s, reinterpret_cast<struct sockaddr *>(&addr), &len) == 0);
	port = ntohs(addr.sin_port);
	return s;
}

//! Accept one client; for each complete inbound APDU send the next scripted
//! reply.  The reply at `split_index` is sent in two halves with a pause, so
//! the client must buffer and re-frame.
static void ServeScript(socket_t listener, std::vector<std::string> script, size_t split_index) {
	socket_t client = accept(listener, nullptr, nullptr);
	if (client == INVALID_SOCKET) {
		return;
	}
	std::string inbuf;
	char buf[4096];
	for (size_t i = 0; i < script.size();) {
		size_t framed = 0;
		if (ber::FrameTlv(inbuf, framed)) {
			inbuf.erase(0, framed);
			const std::string &reply = script[i++];
			if (i - 1 == split_index && reply.size() > 2) {
				size_t half = reply.size() / 2;
				send(client, reply.data(), static_cast<int>(half), 0);
				std::this_thread::sleep_for(std::chrono::milliseconds(50));
				send(client, reply.data() + half, static_cast<int>(reply.size() - half), 0);
			} else {
				send(client, reply.data(), static_cast<int>(reply.size()), 0);
			}
			continue;
		}
		auto n = recv(client, buf, sizeof(buf), 0);
		if (n <= 0) {
			break;
		}
		inbuf.append(buf, static_cast<size_t>(n));
	}
	CloseSock(client);
	CloseSock(listener);
}

// ---- tests -----------------------------------------------------------------

static void TestLoopbackSearch() {
	std::string rec1 = FakeIso2709("loop001", "First loopback record");
	std::string rec2 = FakeIso2709("loop002", "Second loopback record");
	// Split the Present response (index 2) to prove re-framing works on the
	// real byte stream, not just against the mock.
	std::vector<std::string> script = {InitResponseApdu(), SearchResponseApdu(2), PresentResponseApdu({rec1, rec2}, 3)};
	uint16_t port = 0;
	socket_t listener = Listen(port);
	std::thread server(ServeScript, listener, script, static_cast<size_t>(2));

	Z3950Result result;
	try {
		SocketTransport transport("127.0.0.1", port, 10);
		result = Z3950Search(transport, "loopdb", "@attr 1=4 loopback", 10);
	} catch (MarcError &e) {
		CHECK(false && "loopback search threw");
		std::fprintf(stderr, "  error: %s\n", e.what());
	}
	server.join();

	CHECK_EQ(result.hit_count, static_cast<int64_t>(2));
	CHECK_EQ(result.raw_records.size(), static_cast<size_t>(2));
	if (result.raw_records.size() == 2) {
		auto r1 = ParseRecord(result.raw_records[0], Encoding::AUTO);
		auto r2 = ParseRecord(result.raw_records[1], Encoding::AUTO);
		CHECK(r1.ControlNumber() && *r1.ControlNumber() == "loop001");
		CHECK(r2.ControlNumber() && *r2.ControlNumber() == "loop002");
	}
}

static void TestConnectRefused() {
	// Grab an ephemeral port, close the listener, then connect to it.
	uint16_t port = 0;
	socket_t listener = Listen(port);
	CloseSock(listener);
	bool threw = false;
	try {
		SocketTransport transport("127.0.0.1", port, 5);
	} catch (MarcError &e) {
		threw = true;
		CHECK(std::string(e.what()).find("connect") != std::string::npos);
	}
	CHECK(threw);
}

static void TestInvalidPort() {
	bool threw = false;
	try {
		SocketTransport transport("localhost", 0, 5);
	} catch (MarcError &e) {
		threw = true;
		CHECK(std::string(e.what()).find("invalid port") != std::string::npos);
	}
	CHECK(threw);
}

static void TestUnresolvableHost() {
	bool threw = false;
	try {
		SocketTransport transport("host.invalid.", 210, 5);
	} catch (MarcError &e) {
		threw = true;
		CHECK(std::string(e.what()).find("resolve") != std::string::npos);
	}
	CHECK(threw);
}

int main() {
#ifdef _WIN32
	WSADATA data;
	if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
		std::fprintf(stderr, "WSAStartup failed\n");
		return 1;
	}
#endif
	TestLoopbackSearch();
	TestConnectRefused();
	TestInvalidPort();
	TestUnresolvableHost();
	return CHECKS_MAIN_RESULT();
}
