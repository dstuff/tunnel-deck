package fakedns

// TunnelDeck keeps fake address identities across explicit reconnects. This is
// enabled only by the helper's environment, never by imported configurations.
import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
	"github.com/xtls/xray-core/common/cache"

	"github.com/xtls/xray-core/common/net"
)

type tunnelDeckFakeStore struct {
	file *os.File
	domains map[string]net.Address
	ips map[string]string
	limit int
	seen map[string]int64
	saved map[string]int64
}

type tunnelDeckFakeEntry struct {
	Domain string `json:"domain"`
	IP string `json:"ip"`
	Seen int64 `json:"seen"`
}

func (h *Holder) loadTunnelDeckCache(limit int) error {
	path := os.Getenv("TUNNELDECK_FAKE_DNS_CACHE")
	if path == "" { return nil }
	if h.ipRange.IP.To4() == nil { path += ".v6" } else { path += ".v4" }
	// The helper validates the root-owned 0700 parent before passing this path.
	if info, err := os.Lstat(path); err == nil && (!info.Mode().IsRegular() || info.Mode().Perm() & 0077 != 0 || info.Size() > 16_000_000) {
		return fmt.Errorf("invalid TunnelDeck DNS cache")
	}
	file, err := os.OpenFile(path, os.O_CREATE | os.O_RDWR | os.O_APPEND, 0600)
	if err != nil { return err }
	store := &tunnelDeckFakeStore{file:file, domains:map[string]net.Address{}, ips:map[string]string{}, limit:limit, seen:map[string]int64{}, saved:map[string]int64{}}
	scanner := bufio.NewScanner(io.LimitReader(file, 16_000_001))
	for scanner.Scan() {
		var entry tunnelDeckFakeEntry
		if json.Unmarshal(scanner.Bytes(), &entry) != nil { file.Close(); return fmt.Errorf("damaged TunnelDeck DNS cache") }
		if entry.Seen == 0 { entry.Seen = time.Now().Unix() }
		if entry.Seen < time.Now().Add(-24*time.Hour).Unix() { continue }
		ip := net.ParseAddress(entry.IP)
		if ip.Family().IsDomain() || !h.ipRange.Contains(ip.IP()) || len(entry.Domain) == 0 || len(entry.Domain) > 254 || strings.ContainsAny(entry.Domain, "\x00\r\n") {
			file.Close(); return fmt.Errorf("invalid TunnelDeck DNS cache entry")
		}
		if old, ok := store.domains[entry.Domain]; ok && old.String() != entry.IP { file.Close(); return fmt.Errorf("conflicting TunnelDeck DNS cache entry") }
		if old, ok := store.ips[entry.IP]; ok && old != entry.Domain { file.Close(); return fmt.Errorf("conflicting TunnelDeck DNS cache address") }
		store.domains[entry.Domain] = ip; store.ips[entry.IP] = entry.Domain
		store.seen[entry.Domain] = entry.Seen; store.saved[entry.Domain] = entry.Seen
		if len(store.domains) > limit { file.Close(); return fmt.Errorf("TunnelDeck DNS cache capacity exceeded") }
	}
	if err := scanner.Err(); err != nil { file.Close(); return err }
	h.tunnelDeckCache = store
	return nil
}

func (s *tunnelDeckFakeStore) persist(domain string, ip net.Address, seen int64) error {
	entry, err := json.Marshal(tunnelDeckFakeEntry{domain, ip.String(), seen})
	if err != nil { return err }
	entry = append(entry, '\n')
	if _, err = s.file.Write(entry); err != nil { return err }
	// An answer must not escape until its identity is recoverable after a crash.
	if err = s.file.Sync(); err != nil { return err }
	return nil
}

func (s *tunnelDeckFakeStore) put(domain string, ip net.Address) error {
	if len(s.domains) >= s.limit { return fmt.Errorf("TunnelDeck fake DNS pool full") }
	now := time.Now().Unix()
	if err := s.persist(domain, ip, now); err != nil { return err }
	s.domains[domain] = ip; s.ips[ip.String()] = domain; s.seen[domain] = now; s.saved[domain] = now
	if info, err := s.file.Stat(); err == nil && info.Size() > 8_000_000 { return s.compact() }
	return nil
}

func (s *tunnelDeckFakeStore) touch(domain string) error {
	now := time.Now().Unix(); s.seen[domain] = now
	if now - s.saved[domain] < 3600 { return nil }
	if err := s.persist(domain, s.domains[domain], now); err != nil { return err }
	s.saved[domain] = now
	if info, err := s.file.Stat(); err == nil && info.Size() > 8_000_000 { return s.compact() }
	return nil
}

func (s *tunnelDeckFakeStore) compact() error {
	path := s.file.Name()
	file, err := os.CreateTemp(filepath.Dir(path), ".dns-")
	if err != nil { return err }; defer os.Remove(file.Name())
	encoder := json.NewEncoder(file)
	for domain, ip := range s.domains {
		if err = encoder.Encode(tunnelDeckFakeEntry{domain, ip.String(), s.seen[domain]}); err != nil { file.Close(); return err }
	}
	if err = file.Sync(); err != nil { file.Close(); return err }
	if err = file.Close(); err != nil { return err }
	if err = os.Rename(file.Name(), path); err != nil { return err }
	s.file.Close()
	s.file, err = os.OpenFile(path, os.O_RDWR | os.O_APPEND, 0600)
	return err
}

func (h *Holder) pruneTunnelDeckCache() error {
	s := h.tunnelDeckCache
	if s == nil || len(s.domains) < s.limit { return nil }
	cutoff := time.Now().Add(-24*time.Hour).Unix()
	removed := false
	for domain, seen := range s.seen {
		if seen < cutoff {
			delete(s.ips, s.domains[domain].String()); delete(s.domains, domain); delete(s.seen, domain); delete(s.saved, domain); removed = true
		}
	}
	if removed { h.domainToIP = cache.NewLru(s.limit); return s.compact() }
	return nil
}
