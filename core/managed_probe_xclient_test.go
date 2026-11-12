//go:build xclient && !cgo && !android

package core

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/component/resource"
	"github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

func TestManagedProbeBuildFlagIsStatic(t *testing.T) {
	if !IsManagedBuild() {
		t.Fatal("xclient core did not report its managed build tag")
	}
}

func TestManagedProbeBackgroundLeavesHealthAndEventsUntouched(t *testing.T) {
	node, counter, url := managedNode(t, "managed-background")
	frames := managedEventFrames(t, func() {
		if _, err := node.URLTest(context.Background(), url, nil); err == nil {
			t.Error("background URLTest was permitted")
		}
	})
	if counter.dials.Load() != 0 || len(node.DelayHistory()) != 0 || len(node.ExtraDelayHistories()) != 0 || !node.AliveForTestUrl(url) {
		t.Fatalf("blocked URLTest changed health or dialed: dials=%d history=%d extra=%d", counter.dials.Load(), len(node.DelayHistory()), len(node.ExtraDelayHistories()))
	}
	if events := managedDelayEvents(t, frames, node.Name()); events != 0 {
		t.Fatalf("blocked URLTest emitted %d delay events", events)
	}
}

func TestManagedProbeFormalRPCUpdatesHealthAndEvents(t *testing.T) {
	node, counter, url := managedNode(t, "managed-rpc")
	managedNodes(t, node)
	frames := managedEventFrames(t, func() {
		result := handleTestDelay(&TestDelayParams{ProxyName: node.Name(), TestUrl: url, Timeout: 1000})
		if result == nil || result.Value <= 0 {
			t.Fatalf("formal RPC failed: %+v", result)
		}
	})
	if counter.dials.Load() != 1 || len(node.DelayHistory()) != 1 || !node.AliveForTestUrl(url) {
		t.Fatal("formal RPC did not update the real proxy")
	}
	if events := managedDelayEvents(t, frames, node.Name()); events != 1 {
		t.Fatalf("formal RPC emitted %d events, want 1", events)
	}
}

func TestManagedProbeRejectsGroupRPCAndGroupFanout(t *testing.T) {
	node, counter, url := managedNode(t, "managed-group-leaf")
	group := selectorOver(t, "managed-group", node)
	managedNodes(t, node, group)
	result := handleTestDelay(&TestDelayParams{ProxyName: group.Name(), TestUrl: url, Timeout: 1000})
	if result == nil || result.Value > 0 {
		t.Fatalf("group RPC was not rejected: %+v", result)
	}
	_, _ = group.Adapter().(outboundgroup.ProxyGroup).URLTest(context.Background(), url, nil)
	if counter.dials.Load() != 0 || len(node.DelayHistory()) != 0 || len(group.DelayHistory()) != 0 {
		t.Fatal("group test dialed or changed history")
	}
}

func TestManagedProbeProviderInitialAndTickDoNotDial(t *testing.T) {
	node, counter, url := managedNode(t, "managed-initial")
	health := provider.NewHealthCheck([]constant.Proxy{node}, url, 100, 1, false, nil)
	pd, err := provider.NewCompatibleProvider("managed-provider", []constant.Proxy{node}, health)
	if err != nil {
		t.Fatal(err)
	}
	defer pd.Close()
	if err := pd.Initial(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(2200 * time.Millisecond)
	if pd.Count() != 1 || counter.dials.Load() != 0 || len(node.DelayHistory()) != 0 {
		t.Fatalf("provider Initial/tick dialed: %d", counter.dials.Load())
	}
}

func TestManagedProbeProviderUpdatesKeepFetcherWithoutHealthDials(t *testing.T) {
	node, counter, url := managedNode(t, "managed-update")
	health := provider.NewHealthCheck(nil, url, 100, 1, false, nil)
	parser := func([]byte) ([]constant.Proxy, error) { return []constant.Proxy{node}, nil }
	vehicle := resource.NewFileVehicle(filepath.Join(t.TempDir(), "provider.yaml"))
	pd, err := provider.NewProxySetProvider("managed-updates", time.Hour, nil, parser, vehicle, health)
	if err != nil {
		t.Fatal(err)
	}
	defer pd.Close()
	if _, _, err := pd.SideUpdate([]byte("first")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(vehicle.Path(), []byte("second"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := pd.Update(); err != nil {
		t.Fatal(err)
	}
	managedWait()
	if pd.Version() != 2 || pd.Count() != 1 {
		t.Fatal("provider refresh was disabled")
	}
	if _, err := os.Stat(vehicle.Path()); err != nil {
		t.Fatal("Fetcher did not persist its update")
	}
	if counter.dials.Load() != 0 || len(node.DelayHistory()) != 0 {
		t.Fatalf("provider update health check dialed: %d", counter.dials.Load())
	}
}

func managedFallback(t *testing.T, url string, nodes ...constant.Proxy) *outboundgroup.Fallback {
	t.Helper()
	health := provider.NewHealthCheck(nodes, url, 100, 1, false, nil)
	pd, err := provider.NewCompatibleProvider("managed-fallback-provider", nodes, health)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = pd.Close() })
	group, err := outboundgroup.NewFallback(outboundgroup.GroupCommonOption{Name: "managed-fallback", URL: url}, outboundgroup.FallbackOption{}, nil, []P.ProxyProvider{pd})
	if err != nil {
		t.Fatal(err)
	}
	return group
}

func TestManagedProbeDialFailureDoesNotTriggerNativeRetest(t *testing.T) {
	node, counter, url := managedNode(t, "managed-failure")
	group := managedFallback(t, url, node)
	counter.fail.Store(true)
	_, _ = group.DialContext(context.Background(), &constant.Metadata{})
	managedWait()
	if counter.dials.Load() != 1 || len(node.DelayHistory()) != 0 {
		t.Fatalf("traffic failure triggered extra health dials: %d", counter.dials.Load())
	}
}

func TestManagedProbeFallbackKeepsDeadUntilFormalSameURLRecovery(t *testing.T) {
	node, counter, url := managedNode(t, "managed-recovery")
	other, _, _ := managedNode(t, "managed-other")
	managedNodes(t, node, other)
	group := managedFallback(t, url, other, node)
	if err := group.Set(node.Name()); err != nil || group.Now() != node.Name() {
		t.Fatal("a fresh proxy cannot be selected")
	}
	counter.fail.Store(true)
	_ = handleTestDelay(&TestDelayParams{ProxyName: node.Name(), TestUrl: url, Timeout: 1000})
	counter.fail.Store(false)
	before := counter.dials.Load()
	history := len(node.DelayHistory())
	if err := group.Set(node.Name()); err != nil || group.Now() == node.Name() {
		t.Fatal("unconfirmed dead proxy was treated as healthy")
	}
	if counter.dials.Load() != before || len(node.DelayHistory()) != history {
		t.Fatal("Fallback.Set issued a hidden health probe")
	}
	result := handleTestDelay(&TestDelayParams{ProxyName: node.Name(), TestUrl: url, Timeout: 1000})
	if result == nil || result.Value <= 0 {
		t.Fatal("formal recovery failed")
	}
	before = counter.dials.Load()
	if err := group.Set(node.Name()); err != nil || group.Now() != node.Name() || counter.dials.Load() != before {
		t.Fatal("a formally recovered proxy cannot be selected without another probe")
	}
}

func TestManagedProbePermitBindsNodeURLAndIsSingleUse(t *testing.T) {
	node, counter, url := managedNode(t, "managed-permit")
	other, otherCounter, _ := managedNode(t, "managed-wrong-node")
	ctx := delayProbeContext(context.Background(), node.Name(), url)
	if _, err := other.URLTest(ctx, url, nil); err == nil {
		t.Fatal("permit accepted a different node")
	}
	if _, err := node.URLTest(ctx, url+"/other", nil); err == nil {
		t.Fatal("permit accepted a different URL")
	}
	if _, err := node.URLTest(ctx, url, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := node.URLTest(ctx, url, nil); err == nil {
		t.Fatal("permit was replayed")
	}
	if counter.dials.Load() != 1 || otherCounter.dials.Load() != 0 || len(node.DelayHistory()) != 1 || len(other.DelayHistory()) != 0 {
		t.Fatal("denied or replayed probe changed state")
	}
}

func TestManagedProbeOtherURLSuccessDoesNotEraseDeadBinding(t *testing.T) {
	node, counter, url := managedNode(t, "managed-url-binding")
	other, _, _ := managedNode(t, "managed-binding-other")
	managedNodes(t, node, other)
	group := managedFallback(t, url+"/group", other, node)
	counter.fail.Store(true)
	_ = handleTestDelay(&TestDelayParams{ProxyName: node.Name(), TestUrl: url + "/group", Timeout: 1000})
	counter.fail.Store(false)
	_ = handleTestDelay(&TestDelayParams{ProxyName: node.Name(), TestUrl: url + "/primary", Timeout: 1000})
	if node.AliveForTestUrl(url+"/group") || !node.AliveForTestUrl(url+"/primary") {
		t.Fatal("one URL's success was used as another URL's health")
	}
	if err := group.Set(node.Name()); err != nil || group.Now() == node.Name() {
		t.Fatal("a stale dead group binding was selected")
	}
	result := handleTestDelay(&TestDelayParams{ProxyName: node.Name(), TestUrl: url + "/group", Timeout: 1000})
	if result == nil || result.Value <= 0 {
		t.Fatal("formal binding confirmation failed")
	}
	if err := group.Set(node.Name()); err != nil || group.Now() != node.Name() {
		t.Fatal("same-URL confirmed binding was not selectable")
	}
}
