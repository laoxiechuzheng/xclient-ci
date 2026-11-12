package core

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/keepalive"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/resolver/hosts"
)

var directControlOwner struct {
	sync.Mutex
	broker  *directBroker
	stopped bool
}

func dialDirectControl(ctx context.Context, host string, port int) (net.Conn, error) {
	addresses, err := directControlAddresses(ctx, host)
	if err != nil {
		return nil, directUnavailable
	}
	return dialDirectAddresses(ctx, addresses, port, func(ctx context.Context, address netip.Addr, port int) (net.Conn, error) {
		network := "tcp6"
		if address.Is4() {
			network = "tcp4"
		}
		// This shared control applies Android protect or desktop interface/mark
		// without passing literal addresses through profile DNS or hosts again.
		physical := &net.Dialer{Control: dialer.ICMPControl(address)}
		keepalive.SetNetDialer(physical)
		return physical.DialContext(ctx, network, net.JoinHostPort(address.String(), strconv.Itoa(port)))
	}, 200*time.Millisecond)
}

// Resolve outside the profile: recovery must work with broken subscription DNS.
func directControlAddresses(ctx context.Context, host string) ([]netip.Addr, error) {
	if ip, err := netip.ParseAddr(host); err == nil {
		return []netip.Addr{ip.Unmap()}, nil
	}
	name := strings.ToLower(strings.TrimSuffix(host, "."))
	if name == "localhost" || strings.HasSuffix(name, ".localhost") {
		return []netip.Addr{netip.MustParseAddr("127.0.0.1"), netip.IPv6Loopback()}, nil
	}
	var addresses []netip.Addr
	static, _ := hosts.LookupStaticHost(name)
	for _, value := range static {
		if ip, err := netip.ParseAddr(value); err == nil {
			addresses = append(addresses, ip)
		}
	}
	if len(addresses) == 0 {
		if resolver.SystemResolver == nil {
			return nil, directUnavailable
		}
		var err error
		addresses, err = resolver.SystemResolver.LookupIP(resolver.WithInitiator(ctx, resolver.InitiatorDirect), name)
		if err != nil {
			return nil, directUnavailable
		}
	}
	seen := make(map[netip.Addr]bool)
	result := make([]netip.Addr, 0, 16)
	for _, ipv4 := range []bool{true, false} {
		for _, ip := range addresses {
			ip = ip.Unmap()
			if ip.IsValid() && ip.Zone() == "" && ip.Is4() == ipv4 && !seen[ip] && len(result) < 16 {
				seen[ip] = true
				result = append(result, ip)
			}
		}
	}
	if len(result) == 0 {
		return nil, directUnavailable
	}
	return result, nil
}

func directControlBroker() (*directBroker, error) {
	directControlOwner.Lock()
	defer directControlOwner.Unlock()
	if directControlOwner.stopped {
		return nil, directUnavailable
	}
	if directControlOwner.broker == nil {
		broker, err := newDirectBroker(dialDirectControl, directBrokerLimits{})
		if err != nil {
			return nil, err
		}
		directControlOwner.broker = broker
	}
	return directControlOwner.broker, nil
}

func initDirectControl() {
	directControlOwner.Lock()
	if directControlOwner.stopped {
		directControlOwner.broker = nil
		directControlOwner.stopped = false
	}
	directControlOwner.Unlock()
}

func shutdownDirectControl() {
	directControlOwner.Lock()
	directControlOwner.stopped = true
	broker := directControlOwner.broker
	directControlOwner.broker = nil
	directControlOwner.Unlock()
	if broker != nil {
		broker.Close()
	}
}

func directMethodFailure(err error) error {
	if err == nil {
		return nil
	}
	var code directControlError
	if !errors.As(err, &code) {
		code = directUnavailable
	}
	return &MethodError{Code: string(code), Message: "direct control request failed"}
}

func handleOpenDirectSocket(params OpenDirectSocketParams) (OpenDirectSocketResult, error) {
	if !validDirectTarget(params) {
		return OpenDirectSocketResult{}, directMethodFailure(directInvalidArguments)
	}
	broker, err := directControlBroker()
	if err != nil {
		return OpenDirectSocketResult{}, directMethodFailure(err)
	}
	result, err := broker.Open(params)
	return result, directMethodFailure(err)
}

func handleCloseDirectSocket(params CloseDirectSocketParams) (bool, error) {
	if !validDirectSession(params.SessionID) || !validDirectConnection(params.ConnectionID) {
		return false, directMethodFailure(directInvalidArguments)
	}
	directControlOwner.Lock()
	broker := directControlOwner.broker
	directControlOwner.Unlock()
	if broker == nil {
		return true, nil
	}
	return true, directMethodFailure(broker.CloseSocket(params))
}

func handleCloseDirectSession(params CloseDirectSessionParams) (bool, error) {
	if !validDirectSession(params.SessionID) {
		return false, directMethodFailure(directInvalidArguments)
	}
	directControlOwner.Lock()
	broker := directControlOwner.broker
	directControlOwner.Unlock()
	if broker == nil {
		return true, nil
	}
	return true, directMethodFailure(broker.CloseSession(params.SessionID))
}
