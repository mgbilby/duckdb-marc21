//! TCP transport for the Z39.50 client core.  POSIX sockets, with the small
//! Winsock delta (#ifdef _WIN32) kept inline so the file cross-compiles under
//! mingw for the Windows CI builds.
#include "marc/z3950_socket.hpp"

#include <cerrno>
#include <cstring>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
using socket_t = SOCKET;
static constexpr socket_t INVALID_SOCK = INVALID_SOCKET;
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
using socket_t = int;
static constexpr socket_t INVALID_SOCK = -1;
#endif

namespace marc {

namespace {

void CloseSocket(socket_t s) {
#ifdef _WIN32
	closesocket(s);
#else
	close(s);
#endif
}

void SetBlocking(socket_t s, bool blocking) {
#ifdef _WIN32
	u_long mode = blocking ? 0 : 1;
	ioctlsocket(s, FIONBIO, &mode);
#else
	int flags = fcntl(s, F_GETFL, 0);
	if (flags >= 0) {
		fcntl(s, F_SETFL, blocking ? (flags & ~O_NONBLOCK) : (flags | O_NONBLOCK));
	}
#endif
}

bool ConnectInProgress() {
#ifdef _WIN32
	int err = WSAGetLastError();
	return err == WSAEWOULDBLOCK || err == WSAEINPROGRESS;
#else
	return errno == EINPROGRESS;
#endif
}

void SetIoTimeout(socket_t s, int seconds) {
#ifdef _WIN32
	DWORD ms = static_cast<DWORD>(seconds) * 1000;
	setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char *>(&ms), sizeof(ms));
	setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char *>(&ms), sizeof(ms));
#else
	struct timeval tv;
	tv.tv_sec = seconds;
	tv.tv_usec = 0;
	setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
#endif
}

//! Non-blocking connect bounded by `timeout_seconds` (a plain blocking
//! connect can take minutes on an unresponsive host).
void ConnectWithTimeout(socket_t s, const struct sockaddr *addr, size_t addr_len, int timeout_seconds,
                        const std::string &endpoint) {
	SetBlocking(s, false);
	int rc = connect(s, addr, static_cast<int>(addr_len));
	if (rc != 0) {
		if (!ConnectInProgress()) {
			throw MarcError("z3950: connect to " + endpoint + " failed");
		}
		fd_set wfds, efds;
		FD_ZERO(&wfds);
		FD_ZERO(&efds);
		FD_SET(s, &wfds);
		FD_SET(s, &efds);
		struct timeval tv;
		tv.tv_sec = timeout_seconds;
		tv.tv_usec = 0;
		rc = select(static_cast<int>(s) + 1, nullptr, &wfds, &efds, &tv);
		if (rc <= 0) {
			throw MarcError("z3950: connect to " + endpoint + " timed out");
		}
		int so_error = 0;
#ifdef _WIN32
		int len = sizeof(so_error);
		getsockopt(s, SOL_SOCKET, SO_ERROR, reinterpret_cast<char *>(&so_error), &len);
#else
		socklen_t len = sizeof(so_error);
		getsockopt(s, SOL_SOCKET, SO_ERROR, &so_error, &len);
#endif
		if (FD_ISSET(s, &efds) || so_error != 0) {
			throw MarcError("z3950: connect to " + endpoint + " failed");
		}
	}
	SetBlocking(s, true);
}

#ifdef _WIN32
//! Winsock needs process-wide startup; do it once, never tear it down (the
//! OS reclaims at process exit, and other components may still be using it).
void EnsureWinsock() {
	static const int rc = [] {
		WSADATA data;
		return WSAStartup(MAKEWORD(2, 2), &data);
	}();
	if (rc != 0) {
		throw MarcError("z3950: WSAStartup failed");
	}
}
#endif

} // namespace

SocketTransport::SocketTransport(const std::string &host, int port, int timeout_seconds) {
	if (port <= 0 || port > 65535) {
		throw MarcError("z3950: invalid port " + std::to_string(port));
	}
	if (timeout_seconds <= 0) {
		timeout_seconds = 15;
	}
	endpoint_ = host + ":" + std::to_string(port);
#ifdef _WIN32
	EnsureWinsock();
#endif

	struct addrinfo hints;
	std::memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;
	hints.ai_protocol = IPPROTO_TCP;
	struct addrinfo *res = nullptr;
	if (getaddrinfo(host.c_str(), std::to_string(port).c_str(), &hints, &res) != 0 || !res) {
		throw MarcError("z3950: cannot resolve host \"" + host + "\"");
	}

	socket_t s = INVALID_SOCK;
	std::string last_error = "z3950: connect to " + endpoint_ + " failed";
	for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
		s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
		if (s == INVALID_SOCK) {
			continue;
		}
		try {
			ConnectWithTimeout(s, ai->ai_addr, static_cast<size_t>(ai->ai_addrlen), timeout_seconds, endpoint_);
			break;
		} catch (MarcError &e) {
			last_error = e.what();
			CloseSocket(s);
			s = INVALID_SOCK;
		}
	}
	freeaddrinfo(res);
	if (s == INVALID_SOCK) {
		throw MarcError(last_error);
	}
	SetIoTimeout(s, timeout_seconds);
	fd_ = static_cast<long long>(s);
}

SocketTransport::~SocketTransport() {
	if (fd_ >= 0) {
		CloseSocket(static_cast<socket_t>(fd_));
	}
}

void SocketTransport::Send(const std::string &bytes) {
	auto s = static_cast<socket_t>(fd_);
	size_t off = 0;
	while (off < bytes.size()) {
#ifdef _WIN32
		int n = send(s, bytes.data() + off, static_cast<int>(bytes.size() - off), 0);
#else
		auto n = send(s, bytes.data() + off, bytes.size() - off, 0);
#endif
		if (n <= 0) {
			throw MarcError("z3950: send to " + endpoint_ + " failed (connection lost or timed out)");
		}
		off += static_cast<size_t>(n);
	}
}

std::string SocketTransport::Recv() {
	auto s = static_cast<socket_t>(fd_);
	char buf[1 << 16];
#ifdef _WIN32
	int n = recv(s, buf, static_cast<int>(sizeof(buf)), 0);
	if (n < 0 && WSAGetLastError() == WSAETIMEDOUT) {
		throw MarcError("z3950: no response from " + endpoint_ + " (timed out)");
	}
#else
	auto n = recv(s, buf, sizeof(buf), 0);
	if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
		throw MarcError("z3950: no response from " + endpoint_ + " (timed out)");
	}
#endif
	if (n < 0) {
		throw MarcError("z3950: receive from " + endpoint_ + " failed");
	}
	return std::string(buf, static_cast<size_t>(n)); // empty = peer closed
}

} // namespace marc
