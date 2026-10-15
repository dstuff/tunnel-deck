TunnelDeck — macOS VPN client, development build 0.1

Requirements: macOS 14+, Apple Silicon, Xcode command-line tools, Go 1.24+
(Go downloads the 1.25 toolchain required by the pinned AWG source), Homebrew.

Build and launch:
  ./script/prepare_runtimes.sh     # first setup; downloads official engines
  ./script/build_and_run.sh       # builds, stages and signs dist/TunnelDeck.app
  swift test                     # configuration and credential-handling tests
  python3 Tests/Integration/engine_smoke.py  # local real-engine checks, no routes

Open Package.swift in Xcode to work on the project. The project-local Codex
Run action calls script/build_and_run.sh. No original Shadowrocket code is used.

Application icon: selected concept 5 (interlocking links).
Resources/AppIcon.png is the transparent master; Resources/AppIcon.icns is the
standalone macOS icon. script/build_icon.sh regenerates the .icns with all
standard and Retina sizes. The build/run script also generates and embeds the
icon automatically and declares it in the app's Info.plist.

Implemented backends:
• OpenConnect / ocserv: a single server field accepts the complete HTTPS URL,
  including the ?camouflage-secret query. Existing split settings are shown
  together automatically; changing/removing the query replaces the old secret.
  The exact initial HTTPS URL is preserved;
  username/password via stdin; separate authgroup; optional certificate pin;
  default certificate verification; CSTP/DTLS; vpnc-script routing and DNS.
  OpenConnect 9.21 and vpnc-script are installed through Homebrew on this Mac.
• AmneziaWG: native official amneziawg-go tag v3.1.20260828 and awg-tools tag
  v3.1.20260812, both built from pinned archives. .conf import retains AWG
  protocol fields, padding, header protection, I1–I5 and timer ranges.
  The helper configures utun, endpoint bypass routes, AllowedIPs and DNS.
  The bundled daemon's --version retains the upstream historical build string;
  Runtime/versions.json records the actual source tag and binary hash.
• Xray: Xray 26.3.27 + TunnelDeck compatibility patch for macOS arm64, built
  from the pinned official source. JSON/outbound imports and
  VLESS/Trojan links (RAW, WS, gRPC, XHTTP, HTTPUpgrade as applicable).
  JSON can carry VMess/Shadowsocks and other supported Xray outbounds.
  A separate HevSocks5Tunnel 2.19.0/lwIP engine supplies the IP/TCP packet layer
  and forwards TCP/UDP through a generated loopback SOCKS5 listener in Xray.
  This follows the separation observed in Shadowrocket's native packet path;
  it replaces the previous Xray-native TUN ingress. MTU is 4064, interface
  addresses are 198.18.0.1/24 and fd00:1234:ffff::10/64.
  The helper supplies routing/DNS and resolves server hostnames before capture.
  Server IPs have physical-gateway bypass routes. Direct outbounds are bound
  to the original physical interface; explicit imported socket options remain.
  For REALITY/Vision with generic Chrome/Safari fingerprints, a dedicated
  ClientHello profile reproduces the observed Shadowrocket Safari15_5 settings
  (ordinary X25519, no ALPN, one RSA-PSS/SHA384 signature entry). Explicit
  versioned Xray profiles remain intact. Saved user JSON is not rewritten.
  The patch does not change REALITY authentication/certificate verification.
  Imported inbounds/API/log destinations are not started. External script and
  certificate/key-file references are rejected in this development importer.

Connection states are deliberately distinct: validation is not a connection;
OpenConnect requires successful authentication and a successful network script;
AWG requires a server handshake; Xray requires HTTPS data through its TUN.
The Check button validates AWG structure, checks the TLS/HTTP ocserv entrypoint,
and runs Xray's parser followed by real HTTPS through an isolated local SOCKS
listener, including eight parallel requests. It does not install routes.
If the first HTTPS check through the connected Xray tunnel fails, the helper
is stopped and its capture routes/DNS are restored automatically.

Privilege and credentials:
The UI runs as the signed-in user. On Connect, macOS's standard administrator
dialog starts a short-lived bundled helper. It accepts a constrained JSON
request through a 0700/0600 session with ownership, file-type and symlink checks;
neither passwords nor camouflage URLs appear in process arguments. A private
FIFO controls disconnect. The helper watches the UI process and restores its
owned routes/DNS on normal disconnect or UI exit. Imported AWG hooks are rejected.
Authentication password is not forwarded to the root helper: only its cookie.
The helper creates root-only working files and removes them after stopping.
Profile metadata contains no password, query secret or private configuration.
Profile edits are saved automatically, including the selected profile and each
profile's Keychain preference. Credentials/configurations persist in Keychain
by default; the profile toggle can opt out. Pending edits are flushed when
switching profiles and quitting. Older profile files are migrated on save.
Incomplete server input is retained in Keychain until it can be normalized.
Sidebar dots share the main window's profile-specific connection status.
The menu bar uses a chain, a circled chain while busy, and a filled circle
around the chain when connected.
Application logs are sanitized before they reach the UI or its copy action.

This is a local, ad-hoc-signed development application, not an App Store build.
It is not notarized or a production SMAppService privileged-helper installation.
OpenConnect's Homebrew libraries are not embedded, so the app is not portable
to a clean machine without installing that dependency. A production release
needs signed/notarized packaging, privilege lifecycle review and integration
testing for sleep, roaming, forced engine failure and IPv6-only networks.

Current testing scope:
Automated tests cover camouflage URL preservation, configuration injection,
AWG advanced parameters, Xray import/isolation and credential redaction.
The Swift suite also covers automatic persistence/reload for every protocol,
legacy migration, profile selection, Keychain opt-out/failure, pending edits
on deletion, incomplete server input, and profile-specific status indicators.
Local real-engine checks passed: OpenConnect sends
the exact initial camouflage POST over pinned TLS; official AWG tools parse
3.1 ranges/header protection/I1/I3; Xray parses a VLESS/REALITY configuration.
The app's live TLS/HTTP check of the supplied ocserv endpoint returned its
authentication form with a valid certificate. No credentials are in this repo.
An actual user-server session requires entering the VPN password in the app.
Before the dedicated TLS patch, live REALITY/Vision tests were unstable even
without TUN. Standard Chrome/Safari presets, native BSD relay and fragmentation
did not consistently fix them; those guesses were discarded. An A/B test of
the dedicated compatibility ClientHello passed 8/8 twice, versus 3/8 with the
official core's Chrome preset. The separate lwIP packet path also starts and
configures its interface. With both changes, the real system tunnel passed UDP
DNS resolution through 1.1.1.1 and 8/8 simultaneous HTTPS requests; the GUI
confirmed Connected. Normal disconnect restored the en0 default route and
removed utun300. 26 Swift tests and two offline ClientHello tests passed.
IPv6-only upstreams and sleep/roaming remain outside this live verification.
The patched core rebuilds reproducibly from the pinned source plus repo patch;
the app bundle includes that patch and the third-party license notice.
Static findings and runtime limitations are recorded in
../analysis/shadowrocket-xray-compatibility.txt and related investigation files.

Pinned upstream sources:
https://www.infradead.org/openconnect/
https://github.com/amnezia-vpn/amneziawg-go/tree/v3.1.20260828
https://github.com/amnezia-vpn/amneziawg-tools/tree/v3.1.20260812
https://github.com/XTLS/Xray-core/releases/tag/v26.3.27
https://github.com/heiher/hev-socks5-tunnel/releases/tag/2.19.0
Licenses are in Runtime/licenses and Runtime/xray/LICENSE (bundled in the app).
