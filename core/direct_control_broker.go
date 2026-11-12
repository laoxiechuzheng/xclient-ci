package core

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"io"
	"net"
	"net/netip"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type directControlError string

func (e directControlError) Error() string { return string(e) }

const (
	directInvalidArguments directControlError = "invalid_arguments"
	directUnavailable      directControlError = "direct_unavailable"
	directLimit            directControlError = "direct_limit"
)

type directDial func(context.Context, string, int) (net.Conn, error)

type directBrokerLimits struct {
	MaxSessions, MaxPending, MaxActive, MaxUnauth    int
	TicketTTL, AuthTimeout, DialTimeout, IdleTimeout time.Duration
	Random                                           io.Reader
}

func (l directBrokerLimits) defaults() directBrokerLimits {
	if l.MaxSessions <= 0 {
		l.MaxSessions = 16
	}
	if l.MaxPending <= 0 {
		l.MaxPending = 128
	}
	if l.MaxActive <= 0 {
		l.MaxActive = 64
	}
	if l.MaxUnauth <= 0 {
		l.MaxUnauth = 16
	}
	if l.TicketTTL <= 0 {
		l.TicketTTL = 10 * time.Second
	}
	if l.AuthTimeout <= 0 {
		l.AuthTimeout = 2 * time.Second
	}
	if l.DialTimeout <= 0 {
		l.DialTimeout = 8 * time.Second
	}
	if l.IdleTimeout <= 0 {
		l.IdleTimeout = 90 * time.Second
	}
	if l.Random == nil {
		l.Random = rand.Reader
	}
	return l
}

type directPipe struct {
	id, session, host string
	port              int
	ticket            [32]byte
	expires           time.Time
	ctx               context.Context
	cancel            context.CancelFunc
	local, remote     net.Conn
	progress          atomic.Int64
}

type directCleanup struct {
	cancel        context.CancelFunc
	local, remote net.Conn
}

func (c directCleanup) close() {
	if c.cancel != nil {
		c.cancel()
	}
	if c.local != nil {
		_ = c.local.Close()
	}
	if c.remote != nil {
		_ = c.remote.Close()
	}
}

type directBroker struct {
	mu       sync.Mutex
	wg       sync.WaitGroup
	listener net.Listener
	dial     directDial
	limits   directBrokerLimits
	ctx      context.Context
	cancel   context.CancelFunc
	closed   bool
	active   int
	entries  map[string]*directPipe
	sessions map[string]map[string]*directPipe
	pending  map[[32]byte]*directPipe
	unauth   map[net.Conn]struct{}
}

func newDirectBroker(dial directDial, limits directBrokerLimits) (*directBroker, error) {
	if dial == nil {
		return nil, directUnavailable
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, directUnavailable
	}
	ctx, cancel := context.WithCancel(context.Background())
	b := &directBroker{listener: listener, dial: dial, limits: limits.defaults(), ctx: ctx, cancel: cancel,
		entries: make(map[string]*directPipe), sessions: make(map[string]map[string]*directPipe),
		pending: make(map[[32]byte]*directPipe), unauth: make(map[net.Conn]struct{})}
	b.launch(b.accept)
	b.launch(b.sweep)
	return b, nil
}

func (b *directBroker) launch(run func()) {
	b.wg.Add(1)
	go func() {
		defer b.wg.Done()
		defer func() {
			if recover() != nil {
				b.stop()
			}
		}()
		run()
	}()
}

var directHostLabel = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$`)

func validDirectSession(session string) bool {
	if len(session) < 22 || len(session) > 64 {
		return false
	}
	decoded, err := base64.RawURLEncoding.DecodeString(session)
	return err == nil && len(decoded) >= 16 && base64.RawURLEncoding.EncodeToString(decoded) == session
}

func validDirectConnection(id string) bool {
	if len(id) != 22 {
		return false
	}
	decoded, err := base64.RawURLEncoding.DecodeString(id)
	return err == nil && len(decoded) == 16 && base64.RawURLEncoding.EncodeToString(decoded) == id
}

func validDirectTarget(p OpenDirectSocketParams) bool {
	if !validDirectSession(p.SessionID) || p.Port < 1 || p.Port > 65535 || len(p.Host) == 0 || len(p.Host) > 253 {
		return false
	}
	if ip, err := netip.ParseAddr(p.Host); err == nil {
		return ip.Zone() == ""
	}
	for _, label := range strings.Split(p.Host, ".") {
		if !directHostLabel.MatchString(label) {
			return false
		}
	}
	return true
}

func (b *directBroker) Open(p OpenDirectSocketParams) (OpenDirectSocketResult, error) {
	if !validDirectTarget(p) {
		return OpenDirectSocketResult{}, directInvalidArguments
	}
	b.mu.Lock()
	cleanup := b.expiredLocked(time.Now())
	defer func() {
		b.mu.Unlock()
		for _, c := range cleanup {
			c.close()
		}
	}()
	if b.closed {
		return OpenDirectSocketResult{}, directUnavailable
	}
	owner := b.sessions[p.SessionID]
	if len(b.pending) >= b.limits.MaxPending || b.active >= b.limits.MaxActive || (owner == nil && len(b.sessions) >= b.limits.MaxSessions) {
		return OpenDirectSocketResult{}, directLimit
	}
	var id string
	var ticket [32]byte
	for attempt := 0; attempt < 8; attempt++ {
		var rawID [16]byte
		if _, err := io.ReadFull(b.limits.Random, rawID[:]); err != nil {
			return OpenDirectSocketResult{}, directUnavailable
		}
		if _, err := io.ReadFull(b.limits.Random, ticket[:]); err != nil {
			return OpenDirectSocketResult{}, directUnavailable
		}
		id = base64.RawURLEncoding.EncodeToString(rawID[:])
		duplicate := false
		for _, current := range b.entries {
			if current.ticket == ticket {
				duplicate = true
				break
			}
		}
		if b.entries[id] == nil && !duplicate {
			break
		}
		id = ""
	}
	if id == "" {
		return OpenDirectSocketResult{}, directUnavailable
	}
	ctx, cancel := context.WithCancel(b.ctx)
	entry := &directPipe{id: id, session: p.SessionID, host: p.Host, port: p.Port, ticket: ticket, expires: time.Now().Add(b.limits.TicketTTL), ctx: ctx, cancel: cancel}
	if owner == nil {
		owner = make(map[string]*directPipe)
		b.sessions[p.SessionID] = owner
	}
	owner[id] = entry
	b.entries[id] = entry
	b.pending[ticket] = entry
	return OpenDirectSocketResult{ConnectionID: id, BridgePort: b.listener.Addr().(*net.TCPAddr).Port, Ticket: base64.RawURLEncoding.EncodeToString(ticket[:]), ExpiresInMs: b.limits.TicketTTL.Milliseconds()}, nil
}

func (b *directBroker) detachLocked(entry *directPipe) directCleanup {
	if b.entries[entry.id] != entry {
		return directCleanup{}
	}
	delete(b.entries, entry.id)
	if b.pending[entry.ticket] == entry {
		delete(b.pending, entry.ticket)
	}
	owner := b.sessions[entry.session]
	delete(owner, entry.id)
	if len(owner) == 0 {
		delete(b.sessions, entry.session)
	}
	return directCleanup{cancel: entry.cancel, local: entry.local, remote: entry.remote}
}

func (b *directBroker) retire(entry *directPipe) {
	b.mu.Lock()
	cleanup := b.detachLocked(entry)
	b.mu.Unlock()
	cleanup.close()
}

func (b *directBroker) CloseSocket(p CloseDirectSocketParams) error {
	if !validDirectSession(p.SessionID) || !validDirectConnection(p.ConnectionID) {
		return directInvalidArguments
	}
	b.mu.Lock()
	entry := b.entries[p.ConnectionID]
	var cleanup directCleanup
	if entry != nil && entry.session == p.SessionID {
		cleanup = b.detachLocked(entry)
	}
	b.mu.Unlock()
	cleanup.close()
	return nil
}

func (b *directBroker) CloseSession(session string) error {
	if !validDirectSession(session) {
		return directInvalidArguments
	}
	b.mu.Lock()
	var cleanup []directCleanup
	for _, entry := range b.sessions[session] {
		cleanup = append(cleanup, b.detachLocked(entry))
	}
	b.mu.Unlock()
	for _, c := range cleanup {
		c.close()
	}
	return nil
}

func (b *directBroker) expiredLocked(now time.Time) []directCleanup {
	var cleanup []directCleanup
	for _, entry := range b.entries {
		pending := entry.local == nil && !now.Before(entry.expires)
		idle := entry.remote != nil && now.Sub(time.Unix(0, entry.progress.Load())) >= b.limits.IdleTimeout
		if pending || idle {
			cleanup = append(cleanup, b.detachLocked(entry))
		}
	}
	return cleanup
}

func (b *directBroker) sweep() {
	interval := min(b.limits.TicketTTL/4, b.limits.IdleTimeout/4, time.Second)
	if interval < time.Millisecond {
		interval = time.Millisecond
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-b.ctx.Done():
			return
		case now := <-ticker.C:
			b.mu.Lock()
			cleanup := b.expiredLocked(now)
			b.mu.Unlock()
			for _, c := range cleanup {
				c.close()
			}
		}
	}
}

func (b *directBroker) accept() {
	var delay time.Duration
	for {
		conn, err := b.listener.Accept()
		if err != nil {
			var networkError net.Error
			if errors.As(err, &networkError) && networkError.Temporary() {
				if delay == 0 {
					delay = 5 * time.Millisecond
				} else {
					delay = min(delay*2, time.Second)
				}
				timer := time.NewTimer(delay)
				select {
				case <-b.ctx.Done():
					timer.Stop()
					return
				case <-timer.C:
					continue
				}
			}
			b.stop()
			return
		}
		delay = 0
		b.mu.Lock()
		peer, ok := conn.RemoteAddr().(*net.TCPAddr)
		if b.closed || !ok || !peer.IP.IsLoopback() || len(b.unauth) >= b.limits.MaxUnauth {
			b.mu.Unlock()
			_ = conn.Close()
			continue
		}
		b.unauth[conn] = struct{}{}
		b.launch(func() { b.serve(conn) })
		b.mu.Unlock()
	}
}

func (b *directBroker) serve(local net.Conn) {
	defer local.Close()
	defer func() { b.mu.Lock(); delete(b.unauth, local); b.mu.Unlock() }()
	_ = local.SetReadDeadline(time.Now().Add(b.limits.AuthTimeout))
	var ticket [32]byte
	if _, err := io.ReadFull(local, ticket[:]); err != nil {
		return
	}
	b.mu.Lock()
	entry := b.pending[ticket]
	delete(b.unauth, local)
	if entry == nil {
		b.mu.Unlock()
		return
	}
	if b.closed || !time.Now().Before(entry.expires) || b.active >= b.limits.MaxActive {
		cleanup := b.detachLocked(entry)
		b.mu.Unlock()
		cleanup.close()
		return
	}
	delete(b.pending, ticket)
	entry.local = local
	b.active++
	b.mu.Unlock()
	defer func() { b.retire(entry); b.mu.Lock(); b.active--; b.mu.Unlock() }()
	_ = local.SetReadDeadline(time.Time{})
	ctx, cancel := context.WithTimeout(entry.ctx, b.limits.DialTimeout)
	remote, err := b.dial(ctx, entry.host, entry.port)
	cancel()
	if err != nil {
		if remote != nil {
			_ = remote.Close()
		}
		return
	}
	if remote == nil {
		return
	}
	b.mu.Lock()
	if b.closed || b.entries[entry.id] != entry || entry.ctx.Err() != nil {
		b.mu.Unlock()
		_ = remote.Close()
		return
	}
	entry.remote = remote
	entry.progress.Store(time.Now().UnixNano())
	b.mu.Unlock()
	done := make(chan struct{})
	b.launch(func() { defer close(done); b.copy(entry, remote, local) })
	b.copy(entry, local, remote)
	<-done
}

type directProgressWriter struct {
	io.Writer
	progress *atomic.Int64
}

func (w directProgressWriter) Write(data []byte) (int, error) {
	n, err := w.Writer.Write(data)
	if n > 0 {
		w.progress.Store(time.Now().UnixNano())
	}
	return n, err
}

func (b *directBroker) copy(entry *directPipe, dst, src net.Conn) {
	if _, err := io.Copy(directProgressWriter{Writer: dst, progress: &entry.progress}, src); err != nil {
		b.retire(entry)
		return
	}
	if half, ok := dst.(interface{ CloseWrite() error }); ok {
		_ = half.CloseWrite()
	}
}

func (b *directBroker) stop() {
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return
	}
	b.closed = true
	b.cancel()
	var cleanup []directCleanup
	for _, entry := range b.entries {
		cleanup = append(cleanup, b.detachLocked(entry))
	}
	var unauth []net.Conn
	for conn := range b.unauth {
		unauth = append(unauth, conn)
	}
	b.mu.Unlock()
	_ = b.listener.Close()
	for _, conn := range unauth {
		_ = conn.Close()
	}
	for _, c := range cleanup {
		c.close()
	}
}

func (b *directBroker) Close() { b.stop(); b.wg.Wait() }
