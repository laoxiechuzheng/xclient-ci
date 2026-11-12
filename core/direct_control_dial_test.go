package core

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"
)

func TestDirectAddressDialSlowIPv4FallsBackToIPv6WithinBudget(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	winner, peer := net.Pipe()
	defer winner.Close()
	defer peer.Close()
	started := time.Now()
	got, err := dialDirectAddresses(ctx, []netip.Addr{netip.MustParseAddr("192.0.2.1"), netip.MustParseAddr("192.0.2.2"), netip.MustParseAddr("2001:db8::1")}, 443,
		func(ctx context.Context, address netip.Addr, _ int) (net.Conn, error) {
			if address.Is6() {
				return winner, nil
			}
			<-ctx.Done()
			return nil, ctx.Err()
		}, 10*time.Millisecond)
	if err != nil || got != winner || time.Since(started) >= 150*time.Millisecond {
		t.Fatal("a slow IPv4 attempt consumed the IPv6 connection budget")
	}
}

func TestDirectAddressDialBoundsWorkersAndWaitsForCancellation(t *testing.T) {
	for _, cancelled := range []bool{false, true} {
		t.Run(map[bool]string{false: "failure", true: "cancel"}[cancelled], func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			var active, maximum, calls atomic.Int32
			release := make(chan struct{})
			go func() {
				for calls.Load() < 2 {
					select {
					case <-ctx.Done():
						return
					case <-time.After(time.Millisecond):
					}
				}
				if cancelled {
					cancel()
				} else {
					close(release)
				}
			}()
			got, err := dialDirectAddresses(ctx, []netip.Addr{netip.MustParseAddr("192.0.2.1"), netip.MustParseAddr("192.0.2.2"), netip.MustParseAddr("192.0.2.3"), netip.MustParseAddr("2001:db8::1")}, 443,
				func(ctx context.Context, _ netip.Addr, _ int) (net.Conn, error) {
					n := active.Add(1)
					defer active.Add(-1)
					calls.Add(1)
					for old := maximum.Load(); old < n && !maximum.CompareAndSwap(old, n); old = maximum.Load() {
					}
					select {
					case <-ctx.Done():
					case <-release:
					}
					return nil, errors.New("fixture dial failed")
				}, 10*time.Millisecond)
			if got != nil || err == nil || maximum.Load() != 2 || active.Load() != 0 {
				t.Fatal("address race exceeded its worker bound or retained a worker")
			}
			if !cancelled && calls.Load() != 4 {
				t.Fatal("failed candidates were not replaced")
			}
		})
	}
}

type directCloseObserved struct {
	net.Conn
	closed atomic.Bool
}

func (c *directCloseObserved) Close() error {
	c.closed.Store(true)
	return c.Conn.Close()
}

func TestDirectAddressDialClosesLateWinnerWithoutClosingSelectedSocket(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	first, firstPeer := net.Pipe()
	defer firstPeer.Close()
	late := &directCloseObserved{Conn: first}
	second, secondPeer := net.Pipe()
	defer secondPeer.Close()
	winner := &directCloseObserved{Conn: second}
	defer winner.Close()
	got, err := dialDirectAddresses(ctx, []netip.Addr{netip.MustParseAddr("192.0.2.1"), netip.MustParseAddr("2001:db8::1")}, 443,
		func(ctx context.Context, address netip.Addr, _ int) (net.Conn, error) {
			if address.Is4() {
				<-ctx.Done()
				return late, nil
			}
			return winner, nil
		}, 10*time.Millisecond)
	if err != nil || got != winner || !late.closed.Load() || winner.closed.Load() {
		t.Fatal("late dial leaked a socket or cancellation closed the selected socket")
	}
}
