//go:build !cgo && !android

package core

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

type managedCountAdapter struct {
	*outbound.Base
	dials atomic.Int32
	fail  atomic.Bool
}

func (a *managedCountAdapter) DialContext(ctx context.Context, metadata *constant.Metadata) (constant.Conn, error) {
	a.dials.Add(1)
	if a.fail.Load() {
		return nil, errors.New("connection refused")
	}
	conn, err := (&net.Dialer{}).DialContext(ctx, "tcp", metadata.RemoteAddress())
	if err != nil {
		return nil, err
	}
	return outbound.NewConn(conn, a), nil
}

func managedNode(t *testing.T, name string) (*adapter.Proxy, *managedCountAdapter, string) {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(server.Close)
	a := &managedCountAdapter{Base: outbound.NewBase(outbound.BaseOption{Name: name, Type: constant.Socks5})}
	return adapter.NewProxy(a), a, server.URL
}

func managedNodes(t *testing.T, nodes ...constant.Proxy) {
	t.Helper()
	values := map[string]constant.Proxy{}
	for _, node := range nodes {
		values[node.Name()] = node
	}
	tunnel.UpdateProxies(values, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })
}

func managedDelayEvents(t *testing.T, frames [][]byte, name string) int {
	t.Helper()
	count := 0
	for _, frame := range frames {
		var call MethodCall
		if err := json.Unmarshal(frame, &call); err != nil || call.Method != messageMethod {
			continue
		}
		var messages []struct {
			Type MessageType     `json:"type"`
			Data json.RawMessage `json:"data"`
		}
		if err := json.Unmarshal(call.Arguments, &messages); err != nil {
			t.Fatal(err)
		}
		for _, message := range messages {
			var delay Delay
			if message.Type == DelayMessage && json.Unmarshal(message.Data, &delay) == nil && delay.Name == name {
				count++
			}
		}
	}
	return count
}

func managedWait() {
	time.Sleep(3 * messageBatchInterval)
}

func managedEventFrames(t *testing.T, run func()) [][]byte {
	t.Helper()
	fake := &fakeConn{}
	previous := swapConn(fake)
	defer swapConn(previous)
	run()
	marker := "managed-barrier-" + t.Name()
	if !sendMessage(DelayMessage, &Delay{Name: marker}) {
		t.Fatal("could not enqueue the event barrier")
	}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		frames := fake.frames(t)
		if managedDelayEvents(t, frames, marker) == 1 {
			return frames
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("delay event barrier did not arrive")
	return nil
}
