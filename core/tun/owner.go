package tun

import (
	"errors"
	"io"
	"math"
	"sync"
)

type ListenerOwner struct {
	mu         sync.Mutex
	listener   io.Closer
	next       int64
	generation int64
}

func (o *ListenerOwner) Start(create func() (io.Closer, error)) (int64, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.next == math.MaxInt64 {
		return 0, errors.New("TUN generation exhausted")
	}
	if err := o.closeLocked(); err != nil {
		return 0, err
	}
	listener, err := create()
	if err != nil {
		return 0, err
	}
	if listener == nil {
		return 0, errors.New("TUN listener unavailable")
	}
	o.next++
	o.generation = o.next
	o.listener = listener
	return o.generation, nil
}

func (o *ListenerOwner) Stop(expected int64) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if expected < 0 || expected > o.next || (o.listener != nil && expected != o.generation) {
		return errors.New("TUN generation changed")
	}
	return o.closeLocked()
}

func (o *ListenerOwner) Generation() int64 {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.generation
}

func (o *ListenerOwner) closeLocked() error {
	if o.listener == nil {
		return nil
	}
	if err := o.listener.Close(); err != nil {
		return err
	}
	o.listener = nil
	o.generation = 0
	return nil
}
