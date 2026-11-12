package core

import (
	"context"
	"net"
	"net/netip"
	"sync"
	"time"
)

type directAddressDial func(context.Context, netip.Addr, int) (net.Conn, error)

func dialDirectAddresses(ctx context.Context, addresses []netip.Addr, port int, dial directAddressDial, stagger time.Duration) (net.Conn, error) {
	var ipv4, ipv6 []netip.Addr
	for _, ip := range addresses {
		if ip.Is4() {
			ipv4 = append(ipv4, ip)
		} else {
			ipv6 = append(ipv6, ip)
		}
	}
	ordered := make([]netip.Addr, 0, len(addresses))
	for len(ipv4) != 0 || len(ipv6) != 0 {
		if len(ipv4) != 0 {
			ordered = append(ordered, ipv4[0])
			ipv4 = ipv4[1:]
		}
		if len(ipv6) != 0 {
			ordered = append(ordered, ipv6[0])
			ipv6 = ipv6[1:]
		}
	}
	if len(ordered) == 0 || ctx.Err() != nil {
		return nil, directUnavailable
	}
	ctx, cancel := context.WithCancel(ctx)
	type attempt struct {
		conn net.Conn
		err  error
	}
	results := make(chan attempt, 2)
	var workers sync.WaitGroup
	defer func() {
		cancel()
		workers.Wait()
		for len(results) != 0 {
			if conn := (<-results).conn; conn != nil {
				_ = conn.Close()
			}
		}
	}()
	active, next := 0, 0
	start := func() {
		ip := ordered[next]
		next++
		active++
		workers.Add(1)
		go func() {
			defer workers.Done()
			var result attempt
			func() {
				defer func() {
					if recover() != nil {
						result.err = directUnavailable
					}
				}()
				result.conn, result.err = dial(ctx, ip, port)
			}()
			if result.err != nil || ctx.Err() != nil {
				if result.conn != nil {
					_ = result.conn.Close()
					result.conn = nil
				}
			}
			results <- result
		}()
	}
	start()
	timer := time.NewTimer(stagger)
	defer timer.Stop()
	fallback := timer.C
	for active != 0 {
		select {
		case <-ctx.Done():
			return nil, directUnavailable
		case <-fallback:
			fallback = nil
			if active < 2 && next < len(ordered) {
				start()
			}
		case result := <-results:
			active--
			if result.conn != nil && result.err == nil {
				if ctx.Err() != nil {
					_ = result.conn.Close()
					return nil, directUnavailable
				}
				return result.conn, nil
			}
			if next < len(ordered) && ctx.Err() == nil {
				start()
			}
		}
	}
	return nil, directUnavailable
}
