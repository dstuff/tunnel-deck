package fakedns

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestTunnelDeckCacheSurvivesReconnect(t *testing.T) {
	t.Setenv("TUNNELDECK_FAKE_DNS_CACHE", filepath.Join(t.TempDir(), "cache"))
	a, err := NewFakeDNSHolder(); if err != nil { t.Fatal(err) }
	ip := a.GetFakeIPForDomain("synthetic.example")[0]
	if err := a.Close(); err != nil { t.Fatal(err) }
	b, err := NewFakeDNSHolder(); if err != nil { t.Fatal(err) }; defer b.Close()
	if got := b.GetDomainFromFakeDNS(ip); got != "synthetic.example" { t.Fatal(got) }
	if got := b.GetFakeIPForDomain("synthetic.example")[0]; got.String() != ip.String() { t.Fatal("identity changed") }
	other := b.GetFakeIPForDomain("another.example")[0]
	if other.String() == ip.String() { t.Fatal("address reused") }
}

func TestTunnelDeckCachePrunesOnlyInactiveEntries(t *testing.T) {
	t.Setenv("TUNNELDECK_FAKE_DNS_CACHE", filepath.Join(t.TempDir(), "cache"))
	a, err := NewFakeDNSHolderConfigOnly(&FakeDnsPool{IpPool:"198.19.0.0/24", LruSize:2})
	if err != nil { t.Fatal(err) }; if err = a.Start(); err != nil { t.Fatal(err) }; defer a.Close()
	a.GetFakeIPForDomain("expired.example")
	live := a.GetFakeIPForDomain("live.example")[0]
	a.tunnelDeckCache.seen["expired.example"] = time.Now().Add(-25*time.Hour).Unix()
	if len(a.GetFakeIPForDomain("new.example")) != 1 { t.Fatal("expired entry not pruned") }
	if a.GetDomainFromFakeDNS(live) != "live.example" { t.Fatal("live entry lost") }
	if len(a.GetFakeIPForDomain("full.example")) != 0 { t.Fatal("active identities must not be reused when full") }
}

func TestTunnelDeckCacheRejectsCorruption(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cache")
	t.Setenv("TUNNELDECK_FAKE_DNS_CACHE", path)
	if err := os.WriteFile(path+".v4", []byte("{bad}\n"), 0600); err != nil { t.Fatal(err) }
	if _, err := NewFakeDNSHolder(); err == nil { t.Fatal("accepted corrupt cache") }
}
