package core

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/netip"
	"strconv"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/trie"
	"github.com/metacubex/mihomo/tunnel"
)

func directRPCFixture(t *testing.T) {
	t.Helper()
	shutdownDirectControl()
	initDirectControl()
	t.Cleanup(shutdownDirectControl)
}

func directRPC(t *testing.T, method string, args any) MethodResponse {
	t.Helper()
	body, err := json.Marshal(args)
	if err != nil {
		t.Fatal(err)
	}
	var response MethodResponse
	if err := json.Unmarshal(handleMethodCall(&MethodCall{Method: CoreMethod(method), Arguments: body}), &response); err != nil {
		t.Fatal(err)
	}
	return response
}

func TestDirectControlRPCRawTicketAndTLSBytes(t *testing.T) {
	directRPCFixture(t)
	target, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	data := []byte{0x16, 0x03, 0x03, 0x00, 0x04, 0x00, 0xff, 0x01, 0x02}
	serverDone := make(chan error, 1)
	go func() {
		conn, err := target.Accept()
		if err != nil {
			serverDone <- err
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
		body := make([]byte, len(data))
		_, err = io.ReadFull(conn, body)
		if err == nil && !bytes.Equal(body, data) {
			err = io.ErrUnexpectedEOF
		}
		if err == nil {
			_, err = conn.Write(body)
		}
		serverDone <- err
	}()
	session := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 16))
	_, portText, _ := net.SplitHostPort(target.Addr().String())
	port, _ := strconv.Atoi(portText)
	response := directRPC(t, "openDirectSocket", map[string]any{"sessionId": session, "host": "127.0.0.1", "port": port})
	if response.Error != nil {
		t.Fatalf("openDirectSocket error code: %s", response.Error.Code)
	}
	result, ok := response.Result.(map[string]any)
	if !ok {
		t.Fatal("direct socket result must be an object")
	}
	if len(result) != 4 {
		t.Fatal("direct socket result must have exactly four camelCase fields")
	}
	connection, _ := result["connectionId"].(string)
	ticket, _ := base64.RawURLEncoding.DecodeString(result["ticket"].(string))
	bridgePort := int(result["bridgePort"].(float64))
	if connection == "" || len(ticket) != 32 || result["expiresInMs"].(float64) <= 0 {
		t.Fatal("invalid direct socket result fields")
	}
	t.Cleanup(func() { directRPC(t, "closeDirectSession", map[string]any{"sessionId": session}) })
	client, err := net.Dial("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(bridgePort)))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := client.Write(append(ticket, data...)); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, len(data))
	if _, err := io.ReadFull(client, got); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, data) {
		t.Fatal("bridge inserted a preamble or lost adjacent TLS bytes")
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
	if response := directRPC(t, "closeDirectSocket", map[string]any{"sessionId": session, "connectionId": connection}); response.Error != nil || response.Result != true {
		t.Fatal("closeDirectSocket must acknowledge ownership cleanup")
	}
}

func TestDirectControlRPCRejectsUnsafeArguments(t *testing.T) {
	session := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{8}, 16))
	for _, args := range []map[string]any{
		{"sessionId": "short", "host": "localhost", "port": 443},
		{"sessionId": session, "host": "https://host.invalid", "port": 443},
		{"sessionId": session, "host": "host.invalid", "port": "443"},
		{"sessionId": session, "host": "host.invalid", "port": 443.5},
		{"sessionId": session, "host": "host.invalid", "port": 0},
	} {
		response := directRPC(t, "openDirectSocket", args)
		if response.Error == nil || response.Error.Code != "invalid_arguments" {
			t.Fatal("unsafe direct request must fail as invalid_arguments")
		}
	}
}

func directNamedEcho(t *testing.T, host string) {
	t.Helper()
	directTargetEcho(t, host, "tcp4", "127.0.0.1:0")
}

func directTargetEcho(t *testing.T, host, network, address string) {
	t.Helper()
	directRPCFixture(t)
	target, err := net.Listen(network, address)
	if err != nil {
		t.Fatal("fixture bind failed")
	}
	defer target.Close()
	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		conn, err := target.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
		_, _ = io.Copy(conn, conn)
	}()
	defer func() { target.Close(); <-serverDone }()
	result, err := handleOpenDirectSocket(OpenDirectSocketParams{SessionID: directTestSession(22), Host: host, Port: target.Addr().(*net.TCPAddr).Port})
	if err != nil {
		t.Fatal("named target mint failed")
	}
	client := directConnect(t, result)
	defer client.Close()
	ticket, _ := base64.RawURLEncoding.DecodeString(result.Ticket)
	payload := []byte{0x16, 3, 3, 0, 1, 0xff}
	if _, err := client.Write(append(ticket, payload...)); err != nil {
		t.Fatal("bridge write failed")
	}
	got := make([]byte, len(payload))
	if _, err := io.ReadFull(client, got); err != nil || !bytes.Equal(got, payload) {
		t.Fatal("named target did not relay original bytes to the local fixture")
	}
}

func TestDirectControlNamedTargetBeforeProfile(t *testing.T) {
	for _, host := range []string{"localhost", "LOCALHOST", "fixture.localhost"} {
		t.Run(host, func(t *testing.T) { directNamedEcho(t, host) })
	}
}

type directDNSFixture struct {
	resolver.Resolver
	addresses   []netip.Addr
	domainCalls atomic.Int32
}

func (r *directDNSFixture) Invalid() bool { return true }
func (r *directDNSFixture) LookupIP(ctx context.Context, host string) ([]netip.Addr, error) {
	if ip, err := netip.ParseAddr(host); err == nil {
		return []netip.Addr{ip}, nil
	}
	r.domainCalls.Add(1)
	if r.addresses == nil {
		return nil, errors.New("fixture profile DNS unavailable")
	}
	return r.addresses, nil
}
func (r *directDNSFixture) LookupIPv4(ctx context.Context, host string) ([]netip.Addr, error) {
	return r.LookupIP(ctx, host)
}
func (r *directDNSFixture) LookupIPv6(ctx context.Context, host string) ([]netip.Addr, error) {
	return nil, resolver.ErrIPVersion
}

func TestDirectControlDNSDoesNotUseBrokenProfileResolver(t *testing.T) {
	previousSystem, previousDirect := resolver.SystemResolver, resolver.DirectHostResolver
	previousProxy, previousDefault := resolver.ProxyServerHostResolver, resolver.DefaultResolver
	previousMode := tunnel.Mode()
	t.Cleanup(func() {
		resolver.SystemResolver, resolver.DirectHostResolver = previousSystem, previousDirect
		resolver.ProxyServerHostResolver, resolver.DefaultResolver = previousProxy, previousDefault
		tunnel.SetMode(previousMode)
	})
	physical := &directDNSFixture{addresses: []netip.Addr{netip.MustParseAddr("127.0.0.1")}}
	profile := &directDNSFixture{}
	resolver.SystemResolver, resolver.DirectHostResolver = physical, profile
	resolver.ProxyServerHostResolver, resolver.DefaultResolver = profile, profile
	tunnel.SetMode(tunnel.Global)
	directNamedEcho(t, "control.fixture.invalid")
	if physical.domainCalls.Load() != 1 || profile.domainCalls.Load() != 0 {
		t.Fatal("control DNS consulted the profile resolver or skipped physical DNS")
	}
}

func TestDirectControlLiteralIPIgnoresProfileHosts(t *testing.T) {
	previous := resolver.DefaultHosts
	t.Cleanup(func() { resolver.DefaultHosts = previous })
	profile := trie.New[resolver.HostValue]()
	if err := profile.Insert("127.0.0.1", resolver.HostValue{IPs: []netip.Addr{netip.MustParseAddr("127.0.0.2")}}); err != nil {
		t.Fatal("fixture hosts insertion failed")
	}
	resolver.DefaultHosts = resolver.NewHosts(profile)
	directNamedEcho(t, "127.0.0.1")
}

func TestDirectControlIPv6IgnoresProfileDisableIPv6(t *testing.T) {
	previous := resolver.DisableIPv6
	resolver.DisableIPv6 = true
	t.Cleanup(func() { resolver.DisableIPv6 = previous })
	directTargetEcho(t, "::1", "tcp6", "[::1]:0")
}

func TestDirectControlUsesPhysicalSocketHook(t *testing.T) {
	previous := dialer.DefaultSocketHook
	t.Cleanup(func() { dialer.DefaultSocketHook = previous })
	var called atomic.Int32
	var rawControlled atomic.Bool
	var ipv4, ipv6 atomic.Bool
	dialer.DefaultSocketHook = func(network, _ string, raw syscall.RawConn) error {
		called.Add(1)
		if network == "tcp4" {
			ipv4.Store(true)
		}
		if network == "tcp6" {
			ipv6.Store(true)
		}
		return raw.Control(func(uintptr) { rawControlled.Store(true) })
	}
	directNamedEcho(t, "localhost")
	directTargetEcho(t, "::1", "tcp6", "[::1]:0")
	if called.Load() != 2 || !rawControlled.Load() || !ipv4.Load() || !ipv6.Load() {
		t.Fatal("physical socket hook was not applied to the TCP socket")
	}
	denied := errors.New("fixture protect rejected")
	dialer.DefaultSocketHook = func(string, string, syscall.RawConn) error { return denied }
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	conn, err := dialDirectControl(ctx, "127.0.0.1", 443)
	if conn != nil || err != directUnavailable {
		t.Fatal("socket protection failure did not fail closed")
	}
}

func TestDirectControlGlobalModePreservesHalfCloseAndResponse(t *testing.T) {
	directRPCFixture(t)
	previousMode := tunnel.Mode()
	tunnel.SetMode(tunnel.Global)
	t.Cleanup(func() { tunnel.SetMode(previousMode) })
	target, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	response := bytes.Repeat([]byte{0x17, 0x03, 0x03, 0x00, 0xff}, 20000)
	done := make(chan error, 1)
	go func() {
		conn, err := target.Accept()
		if err != nil {
			done <- err
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
		body, err := io.ReadAll(conn)
		if err == nil && string(body) != "request" {
			err = io.ErrUnexpectedEOF
		}
		if err == nil {
			_, err = conn.Write(response)
		}
		done <- err
	}()
	port := target.Addr().(*net.TCPAddr).Port
	result, err := handleOpenDirectSocket(OpenDirectSocketParams{SessionID: directTestSession(17), Host: "127.0.0.1", Port: port})
	if err != nil {
		t.Fatal(err)
	}
	client := directConnect(t, result)
	ticket, _ := base64.RawURLEncoding.DecodeString(result.Ticket)
	if _, err := client.Write(append(ticket, []byte("request")...)); err != nil {
		t.Fatal(err)
	}
	if err := client.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(client)
	if err != nil || !bytes.Equal(got, response) {
		t.Fatal("DIRECT half-close lost or truncated the response")
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestDirectControlListenerStopIsIndependentAndShutdownIsTerminal(t *testing.T) {
	directRPCFixture(t)
	owner := directTestSession(18)
	first, err := handleOpenDirectSocket(OpenDirectSocketParams{SessionID: owner, Host: "host.invalid", Port: 443})
	if err != nil {
		t.Fatal(err)
	}
	handleStopListener()
	if _, err := handleOpenDirectSocket(OpenDirectSocketParams{SessionID: owner, Host: "host.invalid", Port: 443}); err != nil {
		t.Fatal("proxy stop closed the independent DIRECT broker")
	}
	handleShutdown()
	if _, err := handleOpenDirectSocket(OpenDirectSocketParams{SessionID: owner, Host: "host.invalid", Port: 443}); err == nil || asMethodError(err).Code != "direct_unavailable" {
		t.Fatal("shutdown did not close the DIRECT owner")
	}
	initDirectControl()
	next, err := handleOpenDirectSocket(OpenDirectSocketParams{SessionID: owner, Host: "host.invalid", Port: 443})
	if err != nil {
		t.Fatal("Core reinitialization did not install a fresh owner")
	}
	client := directConnect(t, next)
	directAuthenticate(t, client, first.Ticket)
	directReadClosed(t, client)
}
