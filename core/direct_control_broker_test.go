package core

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"io"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func directTestSession(n byte) string {
	return base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{n}, 16))
}

func directTestBroker(t *testing.T, dial directDial, limits directBrokerLimits) *directBroker {
	t.Helper()
	b, err := newDirectBroker(dial, limits)
	if err != nil {
		t.Fatal("create direct broker:", err)
	}
	t.Cleanup(b.Close)
	return b
}

func directEventually(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("direct broker did not settle before deadline")
		}
		time.Sleep(time.Millisecond)
	}
}

func directOpen(t *testing.T, b *directBroker, session string) OpenDirectSocketResult {
	t.Helper()
	result, err := b.Open(OpenDirectSocketParams{SessionID: session, Host: "fixed.example.invalid", Port: 443})
	if err != nil {
		t.Fatal("open direct ticket:", err)
	}
	return result
}

func directConnect(t *testing.T, result OpenDirectSocketResult) *net.TCPConn {
	t.Helper()
	conn, err := net.Dial("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(result.BridgePort)))
	if err != nil {
		t.Fatal(err)
	}
	client := conn.(*net.TCPConn)
	_ = client.SetDeadline(time.Now().Add(2 * time.Second))
	t.Cleanup(func() { _ = client.Close() })
	return client
}

func directAuthenticate(t *testing.T, client net.Conn, ticket string) {
	t.Helper()
	data, err := base64.RawURLEncoding.DecodeString(ticket)
	if err != nil {
		t.Fatal("decode test ticket")
	}
	if _, err := client.Write(data); err != nil {
		t.Fatal(err)
	}
}

func directReadClosed(t *testing.T, conn net.Conn) {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(time.Second))
	var data [1]byte
	n, err := conn.Read(data[:])
	if n != 0 || err == nil {
		t.Fatal("refused connection did not close without response bytes")
	}
	if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("refused connection was left open")
	}
}

type directAcceptFailure struct{ temporary bool }

func (e directAcceptFailure) Error() string   { return "injected accept failure" }
func (e directAcceptFailure) Timeout() bool   { return false }
func (e directAcceptFailure) Temporary() bool { return e.temporary }

type directFaultListener struct {
	net.Listener
	failures []error
	always   error
	calls    atomic.Int32
}

func (l *directFaultListener) Accept() (net.Conn, error) {
	index := int(l.calls.Add(1)) - 1
	if index < len(l.failures) {
		return nil, l.failures[index]
	}
	if l.always != nil {
		return nil, l.always
	}
	return l.Listener.Accept()
}

func directFaultBroker(t *testing.T, faults []error, always error) (*directBroker, *directFaultListener) {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal("fixture bind failed")
	}
	fault := &directFaultListener{Listener: listener, failures: faults, always: always}
	ctx, cancel := context.WithCancel(context.Background())
	b := &directBroker{listener: fault, dial: func(context.Context, string, int) (net.Conn, error) {
		local, peer := net.Pipe()
		go func() { defer peer.Close(); _, _ = io.Copy(peer, peer) }()
		return local, nil
	}, limits: (directBrokerLimits{}).defaults(), ctx: ctx, cancel: cancel,
		entries: make(map[string]*directPipe), sessions: make(map[string]map[string]*directPipe),
		pending: make(map[[32]byte]*directPipe), unauth: make(map[net.Conn]struct{})}
	b.launch(b.accept)
	t.Cleanup(b.Close)
	return b, fault
}

func TestDirectBrokerTemporaryAcceptRetriesAndKeepsServing(t *testing.T) {
	b, fault := directFaultBroker(t, []error{directAcceptFailure{temporary: true}}, nil)
	result := directOpen(t, b, directTestSession(70))
	client := directConnect(t, result)
	directAuthenticate(t, client, result.Ticket)
	if _, err := client.Write([]byte("probe")); err != nil {
		t.Fatal("fixture write failed")
	}
	got := make([]byte, 5)
	if _, err := io.ReadFull(client, got); err != nil || string(got) != "probe" {
		t.Fatal("one temporary accept failure disabled the broker")
	}
	if fault.calls.Load() < 2 {
		t.Fatal("temporary accept failure was not retried")
	}
}

func TestDirectBrokerAcceptRetryIsBoundedAndCancellable(t *testing.T) {
	started := time.Now()
	b, fault := directFaultBroker(t, nil, directAcceptFailure{temporary: true})
	directEventually(t, func() bool { return fault.calls.Load() >= 2 })
	if time.Since(started) < 5*time.Millisecond {
		t.Fatal("temporary accept retry spun without backoff")
	}
	closing := time.Now()
	b.Close()
	if time.Since(closing) > 100*time.Millisecond {
		t.Fatal("close waited for accept backoff")
	}
	calls := fault.calls.Load()
	time.Sleep(15 * time.Millisecond)
	if calls != fault.calls.Load() {
		t.Fatal("accept retry resumed after close")
	}
}

func TestDirectBrokerPermanentAcceptErrorCloses(t *testing.T) {
	b, fault := directFaultBroker(t, []error{directAcceptFailure{}}, nil)
	directEventually(t, func() bool { b.mu.Lock(); defer b.mu.Unlock(); return b.closed })
	if _, err := b.Open(OpenDirectSocketParams{SessionID: directTestSession(71), Host: "fixture.invalid", Port: 443}); err != directUnavailable {
		t.Fatal("permanent accept failure did not fail closed")
	}
	if fault.calls.Load() != 1 {
		t.Fatal("permanent accept failure was retried")
	}
}

func TestDirectBrokerPartialTicketBindingAndBidirectionalBinary(t *testing.T) {
	peers := make(chan net.Conn, 1)
	bound := make(chan string, 1)
	b := directTestBroker(t, func(_ context.Context, host string, port int) (net.Conn, error) {
		bound <- net.JoinHostPort(host, strconv.Itoa(port))
		local, peer := net.Pipe()
		peers <- peer
		return local, nil
	}, directBrokerLimits{})
	result := directOpen(t, b, directTestSession(1))
	second := directOpen(t, b, directTestSession(1))
	if result.ConnectionID == second.ConnectionID || result.Ticket == second.Ticket || !validDirectConnection(result.ConnectionID) {
		t.Fatal("tickets and connection ids must be independent random values")
	}
	if !b.listener.Addr().(*net.TCPAddr).IP.Equal(net.IPv4(127, 0, 0, 1)) {
		t.Fatal("bridge must bind only IPv4 loopback")
	}
	client := directConnect(t, result)
	ticket, _ := base64.RawURLEncoding.DecodeString(result.Ticket)
	if len(ticket) != 32 {
		t.Fatal("ticket must contain exactly 32 raw bytes")
	}
	if _, err := client.Write(ticket[:7]); err != nil {
		t.Fatal(err)
	}
	data := []byte{0x16, 0x03, 0x03, 0, 3, 0xff, 0, 0x80}
	if _, err := client.Write(append(ticket[7:], data...)); err != nil {
		t.Fatal(err)
	}
	peer := <-peers
	defer peer.Close()
	_ = peer.SetDeadline(time.Now().Add(time.Second))
	if <-bound != "fixed.example.invalid:443" {
		t.Fatal("ticket did not retain its minted target")
	}
	got := make([]byte, len(data))
	if _, err := io.ReadFull(peer, got); err != nil || !bytes.Equal(got, data) {
		t.Fatal("partial ticket consumed adjacent TLS bytes")
	}
	reply := []byte{0x17, 0x03, 0x03, 0, 2, 0, 0xfe}
	go func() { _, _ = peer.Write(reply) }()
	got = make([]byte, len(reply))
	if _, err := io.ReadFull(client, got); err != nil || !bytes.Equal(got, reply) {
		t.Fatal("bridge inserted an ACK or corrupted the reverse stream")
	}
}

func TestDirectBrokerAtomicConsumeReplayAndUnknownHaveNoState(t *testing.T) {
	var dials atomic.Int32
	peers := make(chan net.Conn, 4)
	b := directTestBroker(t, func(context.Context, string, int) (net.Conn, error) {
		dials.Add(1)
		conn, peer := net.Pipe()
		peers <- peer
		return conn, nil
	}, directBrokerLimits{})
	result := directOpen(t, b, directTestSession(2))
	clients := make([]*net.TCPConn, 4)
	var writes sync.WaitGroup
	for i := range clients {
		clients[i] = directConnect(t, result)
		writes.Add(1)
		go func(client net.Conn) {
			defer writes.Done()
			ticket, _ := base64.RawURLEncoding.DecodeString(result.Ticket)
			_, _ = client.Write(ticket)
		}(clients[i])
	}
	writes.Wait()
	directEventually(t, func() bool { b.mu.Lock(); defer b.mu.Unlock(); return dials.Load() == 1 && len(b.unauth) == 0 })
	if dials.Load() != 1 {
		t.Fatal("one ticket caused multiple outbound dials")
	}
	_ = b.CloseSession(directTestSession(2))
	for _, client := range clients {
		directReadClosed(t, client)
	}
	select {
	case peer := <-peers:
		_ = peer.Close()
	default:
	}
	unknown := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x55}, 32))
	for i := 0; i < 24; i++ {
		client := directConnect(t, result)
		directAuthenticate(t, client, unknown)
		directReadClosed(t, client)
		_ = b.CloseSession(directTestSession(byte(i + 30)))
		_ = b.CloseSocket(CloseDirectSocketParams{SessionID: directTestSession(3), ConnectionID: directTestSession(byte(i + 60))})
	}
	directEventually(t, func() bool {
		b.mu.Lock()
		defer b.mu.Unlock()
		return len(b.entries) == 0 && len(b.sessions) == 0 && len(b.pending) == 0 && len(b.unauth) == 0 && b.active == 0
	})
	if dials.Load() != 1 {
		t.Fatal("unknown or replayed tickets dialed outbound")
	}
}

func TestDirectBrokerExpiryAndAdmissionBounds(t *testing.T) {
	var dials atomic.Int32
	b := directTestBroker(t, func(context.Context, string, int) (net.Conn, error) { dials.Add(1); return nil, errors.New("refused") }, directBrokerLimits{MaxSessions: 1, MaxPending: 2, TicketTTL: 40 * time.Millisecond})
	first := directOpen(t, b, directTestSession(4))
	if _, err := b.Open(OpenDirectSocketParams{SessionID: directTestSession(5), Host: "host.invalid", Port: 443}); err != directLimit {
		t.Fatal("session limit was not enforced while a pending slot remained free")
	}
	_ = directOpen(t, b, directTestSession(4))
	if _, err := b.Open(OpenDirectSocketParams{SessionID: directTestSession(4), Host: "host.invalid", Port: 443}); err != directLimit {
		t.Fatal("pending limit was not enforced")
	}
	if _, err := b.Open(OpenDirectSocketParams{SessionID: directTestSession(5), Host: "host.invalid", Port: 443}); err != directLimit {
		t.Fatal("session limit was not enforced")
	}
	directEventually(t, func() bool { b.mu.Lock(); defer b.mu.Unlock(); return len(b.pending) == 0 && len(b.sessions) == 0 })
	client := directConnect(t, first)
	directAuthenticate(t, client, first.Ticket)
	directReadClosed(t, client)
	if dials.Load() != 0 {
		t.Fatal("expired ticket dialed outbound")
	}
	_ = directOpen(t, b, directTestSession(5))
}

func TestDirectBrokerUnauthenticatedBoundAndDeadline(t *testing.T) {
	var dials atomic.Int32
	b := directTestBroker(t, func(context.Context, string, int) (net.Conn, error) { dials.Add(1); return nil, errors.New("refused") }, directBrokerLimits{MaxUnauth: 1, AuthTimeout: 300 * time.Millisecond})
	result := directOpen(t, b, directTestSession(6))
	stalled := directConnect(t, result)
	directEventually(t, func() bool { b.mu.Lock(); defer b.mu.Unlock(); return len(b.unauth) == 1 })
	rejected := directConnect(t, result)
	ticket, _ := base64.RawURLEncoding.DecodeString(result.Ticket)
	_, _ = rejected.Write(ticket)
	directReadClosed(t, rejected)
	directReadClosed(t, stalled)
	if dials.Load() != 0 {
		t.Fatal("unauthenticated sockets caused outbound work")
	}
	client := directConnect(t, result)
	directAuthenticate(t, client, result.Ticket)
	directReadClosed(t, client)
	if dials.Load() != 1 {
		t.Fatal("authentication refusal consumed an unused ticket")
	}
}

func TestDirectBrokerCloseCancelsLateDialWithoutReleasingPhysicalSlot(t *testing.T) {
	entered := make(chan context.Context, 1)
	release := make(chan struct{})
	var releaseOnce sync.Once
	peerReady := make(chan net.Conn, 1)
	b := directTestBroker(t, func(ctx context.Context, _ string, _ int) (net.Conn, error) {
		entered <- ctx
		<-release
		conn, peer := net.Pipe()
		peerReady <- peer
		return conn, nil
	}, directBrokerLimits{MaxActive: 1})
	t.Cleanup(func() { releaseOnce.Do(func() { close(release) }) })
	result := directOpen(t, b, directTestSession(7))
	client := directConnect(t, result)
	directAuthenticate(t, client, result.Ticket)
	ctx := <-entered
	if err := b.CloseSession(directTestSession(7)); err != nil {
		t.Fatal(err)
	}
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("session close did not cancel a dial")
	}
	if _, err := b.Open(OpenDirectSocketParams{SessionID: directTestSession(8), Host: "host.invalid", Port: 443}); err != directLimit {
		t.Fatal("late dialing worker released its physical concurrency slot early")
	}
	releaseOnce.Do(func() { close(release) })
	peer := <-peerReady
	defer peer.Close()
	directReadClosed(t, peer)
	directReadClosed(t, client)
	directEventually(t, func() bool {
		b.mu.Lock()
		defer b.mu.Unlock()
		return b.active == 0 && len(b.entries) == 0 && len(b.sessions) == 0
	})
	_ = directOpen(t, b, directTestSession(8))
}

func TestDirectBrokerSessionAndConnectionClosureAreIsolated(t *testing.T) {
	peers := make(chan net.Conn, 2)
	b := directTestBroker(t, func(context.Context, string, int) (net.Conn, error) {
		conn, peer := net.Pipe()
		peers <- peer
		return conn, nil
	}, directBrokerLimits{})
	a := directOpen(t, b, directTestSession(9))
	pendingA := directOpen(t, b, directTestSession(9))
	bResult := directOpen(t, b, directTestSession(10))
	clientA := directConnect(t, a)
	directAuthenticate(t, clientA, a.Ticket)
	peerA := <-peers
	defer peerA.Close()
	clientB := directConnect(t, bResult)
	directAuthenticate(t, clientB, bResult.Ticket)
	peerB := <-peers
	defer peerB.Close()
	if err := b.CloseSocket(CloseDirectSocketParams{SessionID: directTestSession(9), ConnectionID: bResult.ConnectionID}); err != nil {
		t.Fatal(err)
	}
	_ = b.CloseSession(directTestSession(9))
	directReadClosed(t, clientA)
	refused := directConnect(t, pendingA)
	directAuthenticate(t, refused, pendingA.Ticket)
	directReadClosed(t, refused)
	go func() { _, _ = peerB.Write([]byte("alive")) }()
	got := make([]byte, 5)
	if _, err := io.ReadFull(clientB, got); err != nil || string(got) != "alive" {
		t.Fatal("closing another session affected this owner")
	}
	_ = b.CloseSocket(CloseDirectSocketParams{SessionID: directTestSession(10), ConnectionID: bResult.ConnectionID})
	directReadClosed(t, clientB)
}

func TestDirectBrokerDialDeadlineAndIdleCleanup(t *testing.T) {
	t.Run("dial", func(t *testing.T) {
		b := directTestBroker(t, func(ctx context.Context, _ string, _ int) (net.Conn, error) { <-ctx.Done(); return nil, ctx.Err() }, directBrokerLimits{DialTimeout: 30 * time.Millisecond})
		result := directOpen(t, b, directTestSession(11))
		client := directConnect(t, result)
		directAuthenticate(t, client, result.Ticket)
		directReadClosed(t, client)
		directEventually(t, func() bool { b.mu.Lock(); defer b.mu.Unlock(); return b.active == 0 && len(b.entries) == 0 })
	})
	t.Run("idle", func(t *testing.T) {
		peers := make(chan net.Conn, 1)
		b := directTestBroker(t, func(context.Context, string, int) (net.Conn, error) {
			conn, peer := net.Pipe()
			peers <- peer
			return conn, nil
		}, directBrokerLimits{IdleTimeout: 40 * time.Millisecond})
		result := directOpen(t, b, directTestSession(12))
		client := directConnect(t, result)
		directAuthenticate(t, client, result.Ticket)
		peer := <-peers
		defer peer.Close()
		directReadClosed(t, client)
		directReadClosed(t, peer)
		directEventually(t, func() bool { b.mu.Lock(); defer b.mu.Unlock(); return b.active == 0 && len(b.entries) == 0 })
	})
}

func TestDirectBrokerShutdownClosesAllWorkersAndIsTerminal(t *testing.T) {
	entered := make(chan context.Context, 1)
	b := directTestBroker(t, func(ctx context.Context, _ string, _ int) (net.Conn, error) {
		entered <- ctx
		<-ctx.Done()
		return nil, ctx.Err()
	}, directBrokerLimits{})
	result := directOpen(t, b, directTestSession(13))
	_ = directOpen(t, b, directTestSession(14))
	client := directConnect(t, result)
	directAuthenticate(t, client, result.Ticket)
	ctx := <-entered
	unauth := directConnect(t, result)
	b.Close()
	b.Close()
	select {
	case <-ctx.Done():
	default:
		t.Fatal("shutdown left a dialing context alive")
	}
	directReadClosed(t, client)
	directReadClosed(t, unauth)
	if _, err := b.Open(OpenDirectSocketParams{SessionID: directTestSession(15), Host: "host.invalid", Port: 443}); err != directUnavailable {
		t.Fatal("closed broker revived")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.active != 0 || len(b.entries) != 0 || len(b.pending) != 0 || len(b.sessions) != 0 || len(b.unauth) != 0 {
		t.Fatal("shutdown retained owned state")
	}
}

func TestDirectBrokerValidatesTargetsAndOwnerIDs(t *testing.T) {
	for _, host := range []string{"localhost", "api.example.invalid", "127.0.0.1", "::1", "2001:db8::1"} {
		if !validDirectTarget(OpenDirectSocketParams{SessionID: directTestSession(16), Host: host, Port: 443}) {
			t.Fatal("valid target rejected")
		}
	}
	for _, host := range []string{"", "https://api.invalid", "user@api.invalid", "api.invalid/path", "api.invalid:443", "[::1]", "fe80::1%zone", "bad..invalid", "-bad.invalid", "a_b.invalid", "white space", "host\x00invalid"} {
		if validDirectTarget(OpenDirectSocketParams{SessionID: directTestSession(16), Host: host, Port: 443}) {
			t.Fatal("unsafe target accepted")
		}
	}
	if validDirectSession("AAAAAAAAAAAAAAAAAAAAAB") || validDirectSession("short") || validDirectConnection("unknown") {
		t.Fatal("noncanonical or malformed owner/id accepted")
	}
}

func TestDirectBrokerEntropyFailureAndActiveTicketCollisionRetainNoNewState(t *testing.T) {
	random := append(bytes.Repeat([]byte{1}, 16), bytes.Repeat([]byte{3}, 32)...)
	random = append(random, bytes.Repeat([]byte{2}, 16)...)
	random = append(random, bytes.Repeat([]byte{3}, 32)...)
	peers := make(chan net.Conn, 1)
	b := directTestBroker(t, func(context.Context, string, int) (net.Conn, error) {
		conn, peer := net.Pipe()
		peers <- peer
		return conn, nil
	}, directBrokerLimits{Random: bytes.NewReader(random)})
	first := directOpen(t, b, directTestSession(19))
	client := directConnect(t, first)
	directAuthenticate(t, client, first.Ticket)
	peer := <-peers
	defer peer.Close()
	if _, err := b.Open(OpenDirectSocketParams{SessionID: directTestSession(20), Host: "other.invalid", Port: 443}); err != directUnavailable {
		t.Fatal("consumed active ticket was reused or entropy failure was not refused")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.sessions) != 1 || len(b.entries) != 1 || len(b.pending) != 0 {
		t.Fatal("failed mint retained a new owner, ticket or connection")
	}
}
