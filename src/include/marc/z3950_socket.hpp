//! Blocking TCP implementation of Z3950Transport (POSIX sockets; Winsock on
//! Windows).  Kept DuckDB-free so it builds and tests in the standalone core
//! suites on every platform.  Not thread-safe: one connection per instance.
#pragma once

#include "marc/z3950.hpp"

#include <string>

namespace marc {

//! Connects in the constructor (name resolution + TCP connect, both bounded
//! by `timeout_seconds`), closes in the destructor.  Send() writes the whole
//! buffer; Recv() returns whatever bytes are available (empty string = peer
//! closed).  All failures — resolve, connect, timeout, I/O — throw MarcError
//! with the host:port in the message.
class SocketTransport : public Z3950Transport {
public:
	SocketTransport(const std::string &host, int port, int timeout_seconds);
	~SocketTransport() override;

	SocketTransport(const SocketTransport &) = delete;
	SocketTransport &operator=(const SocketTransport &) = delete;

	void Send(const std::string &bytes) override;
	std::string Recv() override;

private:
	// The socket handle, kept as an integer so this header stays free of
	// platform socket headers (SOCKET is a uintptr_t on Windows, an int on
	// POSIX; -1 is "closed" for both here).
	long long fd_ = -1;
	std::string endpoint_; // "host:port" for error messages
};

} // namespace marc
