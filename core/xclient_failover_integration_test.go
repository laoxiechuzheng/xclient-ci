//go:build xclient && !cgo && !android

package core

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	logrus "github.com/sirupsen/logrus"
)

type failoverDialCounter struct {
	C.ProxyAdapter
	dials atomic.Int32
}

func (p *failoverDialCounter) DialContext(ctx context.Context, metadata *C.Metadata) (C.Conn, error) {
	p.dials.Add(1)
	return p.ProxyAdapter.DialContext(ctx, metadata)
}

type failoverNode struct {
	server          *httptest.Server
	name            string
	active, maximum atomic.Int32
}

func failoverMaximum(value *atomic.Int32, next int32) {
	for current := value.Load(); next > current; current = value.Load() {
		if value.CompareAndSwap(current, next) {
			return
		}
	}
}

func newFailoverNode(name, origin string, active, maximum *atomic.Int32) *failoverNode {
	node := &failoverNode{name: name}
	node.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodConnect || r.Host != origin {
			http.Error(w, "fixture target refused", 403)
			return
		}
		client, buffered, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		defer client.Close()
		_ = client.SetDeadline(time.Now().Add(6 * time.Second))
		failoverMaximum(&node.maximum, node.active.Add(1))
		defer node.active.Add(-1)
		failoverMaximum(maximum, active.Add(1))
		defer active.Add(-1)
		_, _ = buffered.WriteString("HTTP/1.1 200 Connection established\r\n\r\n")
		_ = buffered.Flush()
		request, err := http.ReadRequest(buffered.Reader)
		if err != nil {
			return
		}
		defer request.Body.Close()
		if request.URL.Path != "/probe" && request.URL.Path != "/traffic" {
			return
		}
		if name == "JP-C" {
			time.Sleep(1100 * time.Millisecond)
			return
		}
		upstream, err := net.DialTimeout("tcp4", origin, time.Second)
		if err != nil {
			return
		}
		defer upstream.Close()
		_ = upstream.SetDeadline(time.Now().Add(3 * time.Second))
		request.Header.Set("X-Fixture-Node", name)
		request.Close = true
		if request.Write(upstream) == nil {
			_, _ = io.Copy(client, upstream)
		}
	}))
	return node
}

// The only listener/RPC entry here belongs to an explicitly selected test process.
func TestXClientFailoverHarness(t *testing.T) {
	nonce := os.Getenv("XC_FAILOVER_TEST_NONCE")
	if os.Getenv("XC_FAILOVER_TEST_BRIDGE") != "1" {
		t.Skip("opt-in loopback failover fixture")
	}
	if !regexp.MustCompile(`^[0-9a-f]{32}$`).MatchString(nonce) {
		t.Fatal("fixture nonce required")
	}
	output := os.Stdout
	os.Stdout = os.Stderr
	logrus.SetOutput(os.Stderr)
	var outputMu sync.Mutex
	write := func(value any) {
		data, err := json.Marshal(value)
		if err != nil {
			t.Error("fixture encoding failed")
			return
		}
		outputMu.Lock()
		defer outputMu.Unlock()
		_, _ = fmt.Fprintln(output, string(data))
	}
	var active, maximum atomic.Int32
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/probe" {
			time.Sleep(650 * time.Millisecond)
			w.WriteHeader(204)
			return
		}
		if r.URL.Path != "/traffic" {
			http.NotFound(w, r)
			return
		}
		_, _ = io.WriteString(w, r.Header.Get("X-Fixture-Node"))
	}))
	defer origin.Close()
	originAddress := origin.Listener.Addr().String()
	nodes := map[string]*failoverNode{}
	for _, name := range []string{"JP-A", "JP-B", "JP-C", "US-A"} {
		nodes[name] = newFailoverNode(name, originAddress, &active, &maximum)
		defer nodes[name].server.Close()
	}
	reservation, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := reservation.Addr().(*net.TCPAddr).Port
	_ = reservation.Close()
	home := t.TempDir()
	configPath := filepath.Join(home, "config.yaml")
	configuration := fmt.Sprintf("mixed-port: %d\nbind-address: 127.0.0.1\nallow-lan: false\nmode: rule\nlog-level: error\nfind-process-mode: off\nipv6: false\ngeo-auto-update: false\ndns:\n  enable: false\ntun:\n  enable: false\nprofile:\n  store-selected: false\n  store-fake-ip: false\nproxies:\n", port)
	for _, name := range []string{"JP-A", "JP-B", "JP-C", "US-A"} {
		nodePort := nodes[name].server.Listener.Addr().(*net.TCPAddr).Port
		configuration += fmt.Sprintf("  - {name: %s, type: http, server: 127.0.0.1, port: %d}\n", name, nodePort)
	}
	configuration += "proxy-groups:\n  - {name: JP-Group, type: select, proxies: [JP-A, JP-B, JP-C, US-A]}\nrules:\n  - MATCH,JP-Group\n"
	if err := os.WriteFile(configPath, []byte(configuration), 0600); err != nil {
		t.Fatal(err)
	}
	left, right := net.Pipe()
	previous := swapConn(left)
	defer func() { swapConn(previous); _ = left.Close(); _ = right.Close() }()
	go func() {
		for {
			var header [4]byte
			if _, err := io.ReadFull(right, header[:]); err != nil {
				return
			}
			size := binary.LittleEndian.Uint32(header[:])
			if size > 1024*1024 {
				return
			}
			data := make([]byte, size)
			if _, err := io.ReadFull(right, data); err != nil {
				return
			}
			var event any
			if json.Unmarshal(data, &event) == nil {
				write(map[string]any{"kind": "event", "value": event})
			}
		}
	}()
	handleInitClash(&InitParams{HomeDir: home})
	defer handleShutdown()
	if err := handleSetupConfig(&SetupParams{SelectedMap: map[string]string{"JP-Group": "JP-A"}, TestURL: origin.URL + "/probe"}); err != nil {
		t.Fatal(err)
	}
	counters := map[string]*failoverDialCounter{}
	for name := range nodes {
		proxy := tunnel.AllProxies()[name].(*adapter.Proxy)
		counter := &failoverDialCounter{ProxyAdapter: proxy.ProxyAdapter}
		proxy.ProxyAdapter = counter
		counters[name] = counter
	}
	handleStartLog()
	if !handleStartListener() {
		t.Fatal("fixture listener failed")
	}
	write(map[string]any{"kind": "ready", "nonce": nonce, "result": map[string]any{"url": origin.URL + "/probe", "config": configPath, "port": port}})
	proxyURL, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", port))
	transport := &http.Transport{Proxy: http.ProxyURL(proxyURL), DisableKeepAlives: true, ResponseHeaderTimeout: 3 * time.Second}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 4 * time.Second}
	var work sync.WaitGroup
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 64*1024)
	for scanner.Scan() {
		var input struct {
			MethodCall
			Nonce string `json:"nonce"`
		}
		if json.Unmarshal(scanner.Bytes(), &input) != nil || input.Nonce != nonce {
			t.Error("fixture command refused")
			break
		}
		call := input.MethodCall
		work.Add(1)
		go func() {
			defer work.Done()
			var result any
			switch call.Method {
			case "fixtureStopA":
				nodes["JP-A"].server.Close()
				result = true
			case "fixtureRequest":
				response, err := client.Get(origin.URL + "/traffic")
				if err != nil {
					result = map[string]any{"status": 0}
					break
				}
				data, _ := io.ReadAll(io.LimitReader(response.Body, 128))
				_ = response.Body.Close()
				result = map[string]any{"status": response.StatusCode, "node": string(data)}
			case "fixtureStats":
				counts := map[string]any{}
				for name, counter := range counters {
					counts[name] = counter.dials.Load()
				}
				result = map[string]any{"dials": counts, "maximum": maximum.Load(), "active": active.Load()}
			default:
				allowed := call.Method == asyncTestDelayMethod || call.Method == changeProxyMethod || call.Method == getProxiesMethod || call.Method == getConnectionsMethod || call.Method == closeConnectionMethod
				if call.Method == getConfigMethod {
					var path string
					allowed = json.Unmarshal(call.Arguments, &path) == nil && path == configPath
				}
				if !allowed {
					write(map[string]any{"kind": "response", "id": call.ID, "error": "fixture method refused"})
					return
				}
				data := handleMethodCall(&call)
				var response MethodResponse
				if json.Unmarshal(data, &response) != nil {
					t.Error("fixture response malformed")
					return
				}
				write(map[string]any{"kind": "response", "id": call.ID, "result": response.Result, "error": response.Error})
				return
			}
			write(map[string]any{"kind": "response", "id": call.ID, "result": result})
		}()
	}
	work.Wait()
	if scanner.Err() != nil {
		t.Error("fixture input failed")
	}
}
