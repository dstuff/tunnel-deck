package dispatcher

import (
	"context"
	"testing"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
)

type tunnelDeckProbeSniff struct{ protocol string }

func (s tunnelDeckProbeSniff) Protocol() string { return s.protocol }
func (s tunnelDeckProbeSniff) Domain() string   { return "example.com" }

func TestTunnelDeckSystemProbePreservesOnlyReservedDestination(t *testing.T) {
	d := new(DefaultDispatcher)
	request := session.SniffingRequest{Enabled: true, RouteOnly: true,
		OverrideDestinationForProtocol: []string{"http", "tls", "quic", "fakedns"}}
	for _, protocol := range []string{"http", "tls"} {
		for _, test := range []struct {
			name, inbound, address string
			port                   net.Port
			network                net.Network
			override               bool
		}{
			{"system", "td-traffic", "198.18.0.3", 443, net.Network_TCP, false},
			{"ordinary IP", "td-traffic", "192.0.2.1", 443, net.Network_TCP, true},
			{"FakeDNS", "td-traffic", "198.19.0.3", 443, net.Network_TCP, true},
			{"other port", "td-traffic", "198.18.0.3", 8443, net.Network_TCP, true},
			{"other inbound", "td-probe", "198.18.0.3", 443, net.Network_TCP, true},
			{"no inbound", "", "198.18.0.3", 443, net.Network_TCP, true},
			{"UDP", "td-traffic", "198.18.0.3", 443, net.Network_UDP, true},
			{"IPv6", "td-traffic", "2001:db8::3", 443, net.Network_TCP, true},
		} {
			t.Run(protocol+"/"+test.name, func(t *testing.T) {
				ctx := context.Background()
				if test.inbound != "" {
					ctx = session.ContextWithInbound(ctx, &session.Inbound{Tag: test.inbound})
				}
				destination := net.Destination{Address: net.ParseAddress(test.address), Port: test.port, Network: test.network}
				if got := d.shouldOverride(ctx, tunnelDeckProbeSniff{protocol}, request, destination); got != test.override {
					t.Fatalf("override = %v, want %v", got, test.override)
				}
			})
		}
	}
}
