//go:build !xclient && !cgo && !android

package core

import (
	"context"
	"testing"
)

func TestUnmanagedURLTestPreservesNativeBehavior(t *testing.T) {
	if IsManagedBuild() {
		t.Fatal("ordinary core reported a managed build")
	}
	node, counter, url := managedNode(t, "unmanaged-default")
	if _, err := node.URLTest(context.Background(), url, nil); err != nil {
		t.Fatal(err)
	}
	if counter.dials.Load() != 1 || len(node.DelayHistory()) != 1 || !node.AliveForTestUrl(url) {
		t.Fatal("ordinary native health checking changed")
	}
}
