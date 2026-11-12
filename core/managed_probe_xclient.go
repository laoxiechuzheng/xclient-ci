//go:build xclient

package core

import (
	"context"
	"errors"
	"sync/atomic"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/constant"
)

type managedProbeKey struct{}

type managedProbePermit struct {
	name string
	url  string
	used atomic.Bool
}

var errManagedProbeRequired = errors.New("URL test requires a managed single-proxy request")

func IsManagedBuild() bool { return true }

func init() {
	adapter.BeforeURLTestHook = func(ctx context.Context, url, name string) error {
		if ctx == nil {
			return errManagedProbeRequired
		}
		permit, ok := ctx.Value(managedProbeKey{}).(*managedProbePermit)
		if !ok || permit.name != name || permit.url != url || !permit.used.CompareAndSwap(false, true) {
			return errManagedProbeRequired
		}
		return nil
	}
}

func delayProbeContext(ctx context.Context, name, url string) context.Context {
	return context.WithValue(ctx, managedProbeKey{}, &managedProbePermit{name: name, url: url})
}

func allowDelayProbe(proxy constant.Proxy) bool { return !isProxyGroupType(proxy.Type()) }
