package tun

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

type testCloser struct {
	err        error
	panicClose bool
	closed     int
}

func (c *testCloser) Close() error {
	if c.panicClose {
		panic("fixture close panic")
	}
	if c.err != nil {
		return c.err
	}
	c.closed++
	return nil
}

func TestListenerOwnerRetainsUnknownCloseForRetry(t *testing.T) {
	var owner ListenerOwner
	resource := &testCloser{err: errors.New("close refused")}
	generation, err := owner.Start(func() (io.Closer, error) { return resource, nil })
	if err != nil {
		t.Fatal(err)
	}
	if err = owner.Stop(generation); err == nil {
		t.Fatal("unknown close accepted")
	}
	if owner.Generation() != generation {
		t.Fatal("unknown owner discarded")
	}
	created := false
	if _, err = owner.Start(func() (io.Closer, error) { created = true; return &testCloser{}, nil }); err == nil || created {
		t.Fatal("unknown listener replaced")
	}
	resource.err = nil
	if err = owner.Stop(generation); err != nil {
		t.Fatal(err)
	}
	if owner.Generation() != 0 || resource.closed != 1 {
		t.Fatal("confirmed listener not released")
	}
	if err = owner.Stop(generation); err != nil {
		t.Fatal("confirmed close not idempotent", err)
	}
}

func TestListenerOwnerPanicDoesNotDiscardResource(t *testing.T) {
	var owner ListenerOwner
	resource := &testCloser{panicClose: true}
	generation, err := owner.Start(func() (io.Closer, error) { return resource, nil })
	if err != nil {
		t.Fatal(err)
	}
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("expected close panic")
			}
		}()
		_ = owner.Stop(generation)
	}()
	if owner.Generation() != generation {
		t.Fatal("panicked owner discarded")
	}
	resource.panicClose = false
	if err := owner.Stop(generation); err != nil {
		t.Fatal(err)
	}
}

func TestListenerOwnerOldGenerationCannotCloseReplacement(t *testing.T) {
	var owner ListenerOwner
	old := &testCloser{}
	first, err := owner.Start(func() (io.Closer, error) { return old, nil })
	if err != nil {
		t.Fatal(err)
	}
	current := &testCloser{}
	second, err := owner.Start(func() (io.Closer, error) { return current, nil })
	if err != nil {
		t.Fatal(err)
	}
	if second <= first || old.closed != 1 {
		t.Fatal("replacement generation invalid")
	}
	if err := owner.Stop(first); err == nil || current.closed != 0 {
		t.Fatal("stale stop touched current listener")
	}
	if err := owner.Stop(second); err != nil {
		t.Fatal(err)
	}
}

func TestListenerOwnerOwnedFileIsActuallyClosed(t *testing.T) {
	var owner ListenerOwner
	file, err := os.Create(filepath.Join(t.TempDir(), "owned-tun-fixture"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = file.Close() })
	generation, err := owner.Start(func() (io.Closer, error) { return file, nil })
	if err != nil {
		t.Fatal(err)
	}
	if err := owner.Stop(generation); err != nil {
		t.Fatal(err)
	}
	if _, err := file.Write([]byte("closed")); !errors.Is(err, os.ErrClosed) {
		t.Fatal("owned file still usable", err)
	}
}

func TestListenerOwnerConcurrentReplacementAndOldStop(t *testing.T) {
	for range 50 {
		var owner ListenerOwner
		first, err := owner.Start(func() (io.Closer, error) { return &testCloser{}, nil })
		if err != nil {
			t.Fatal(err)
		}
		current := &testCloser{}
		var second int64
		var group sync.WaitGroup
		group.Add(2)
		go func() {
			defer group.Done()
			var err error
			second, err = owner.Start(func() (io.Closer, error) { return current, nil })
			if err != nil {
				t.Error(err)
			}
		}()
		go func() { defer group.Done(); _ = owner.Stop(first) }()
		group.Wait()
		if owner.Generation() != second || current.closed != 0 {
			t.Fatal("old stop closed replacement")
		}
		if err := owner.Stop(second); err != nil {
			t.Fatal(err)
		}
	}
}
