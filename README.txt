TunnelDeck — macOS VPN client, development build 0.1

Requirements: macOS 14+, Apple Silicon, Xcode command-line tools, Go 1.24+
(Go downloads the toolchains required by the pinned AWG and Xray sources).
The resulting app includes all three protocol engines; the destination Mac
does not need Homebrew, Go or Xcode command-line tools.

Build and launch:
  ./script/prepare_runtimes.sh     # first setup; downloads official engines
  ./script/build_and_run.sh       # builds, stages and signs dist/TunnelDeck.app
  swift test                     # configuration, persistence and connection workflows
  python3 Tests/Integration/engine_smoke.py  # local real-engine checks, no routes

Open Package.swift in Xcode to work on the project. The project-local Codex
Run action calls script/build_and_run.sh.

Application icon: selected concept 5 (interlocking links).
Resources/AppIcon.png is the transparent master; Resources/AppIcon.icns is the
standalone macOS icon. script/build_icon.sh regenerates the .icns with all
standard and Retina sizes. The build/run script also generates and embeds the
icon automatically and declares it in the app's Info.plist.

Daily controls: the main window is a compact profile list (selected UI concept 1).
Each row connects directly or switches from the active profile. The top status
area disconnects/cancels; switching waits for the previous session's cleanup
before starting the next one, and can be cancelled. Add Connection (Command-N)
accepts a server address, VLESS/Trojan link, JSON or AWG .conf, including file
selection and drag/drop. Local format recognition does not verify a handshake.
Profile settings open from the row's ellipsis menu (or Command-I) and save automatically;
diagnostics open separately (Option-Command-L). Active profiles cannot be deleted.
Closing the main window keeps the app and VPN available from the menu bar.
Administrator confirmation is still required when starting a real tunnel.

UI verification: ./script/build_and_run.sh --preview launches a DEBUG-only
isolated design preview with synthetic profiles in a separate temporary file. Connect,
disconnect and check are simulated in that mode: no helper or network
requests. Normal launch uses the actual saved profiles and engines. The selected
mock and visual QA evidence are in Design/ConnectionList/. Routing preview:
./script/build_and_run.sh --routing-preview. This builds a separate
dist/TunnelDeck Preview.app with an isolated bundle ID and never stops the normal
app. Routing reference and comparisons are in Design/Routing/; the latest report
is design-qa.md.

Shared routing:
Open Routing from the main window, settings, menu bar, or Option-Command-R.
One ordered policy is used by every connection. The first enabled match wins;
otherwise the selected default (VPN/direct) applies. The split editor supports
sites with or without subdomains, IPv4/IPv6 addresses/subnets, and IP countries.
Actions are VPN, direct and block. Changes autosave; use Apply and Reconnect to
apply them to an active connection. The current helper keeps its original snapshot.

Import/export uses standalone .tunneldeck-routing JSON, limited to 128 KB and 1000
rules. It contains no profiles, passwords or keys. Import previews all rules before
replacing the current scheme and never connects automatically. Example:
docs/examples/sites-and-countries.tunneldeck-routing. The address inspector explains
which rule matches; it is not a connectivity test. Country data is bundled DB-IP
Lite (CC BY 4.0), generated reproducibly by script/prepare_geoip.py.

All backends now require the bundled common Xray/Hev router. Native OpenConnect
and AWG interfaces provide scoped VPN channels, while the front utun captures
TCP/UDP for policy decisions. Existing on-link/loopback routes remain system-owned.
Imported Xray routing/dns/policy/inbounds are replaced at runtime by the shared
scheme. Multiple server outbounds require a primary-server selection; its explicit
dialer chain is preserved. FakeDNS identities persist privately across reconnects;
HTTP Host/SNI cannot override a known DNS identity. Apps with their own encrypted
DNS or cached real IPs fall back to IP/country/default decisions.

Implemented backends:
• OpenConnect / ocserv: a single server field accepts the complete HTTPS URL,
  including the ?camouflage-secret query. Existing split settings are shown
  together automatically; changing/removing the query replaces the old secret.
  The exact initial HTTPS URL is preserved;
  username/password via stdin; separate authgroup; optional certificate pin;
  default certificate verification; CSTP/DTLS; validated network callbacks into the shared router.
  OpenConnect 9.21, statically linked OpenSSL 3.6.2 and the pinned vpnc-script
  are bundled in the app, with no Homebrew runtime dependency. They are built
  for arm64/macOS 14+ from verified source archives by script/build_openconnect.sh.
  Default certificate verification uses Apple's /etc/ssl/cert.pem; a configured
  server pin still applies. Hardware-token/PKCS#11/GSSAPI integrations are not
  included in this standalone build; username/password authentication remains.
• AmneziaWG: native official amneziawg-go tag v3.1.20260828 and awg-tools tag
  v3.1.20260812, both built from pinned archives. .conf import retains AWG
  protocol fields, padding, header protection, I1–I5 and timer ranges.
  The helper configures the native utun and scoped AllowedIPs; the shared
  Xray/Hev path applies user rules and DNS for all three backends.
  The bundled daemon's --version retains the upstream historical build string;
  Runtime/versions.json records the actual source tag and binary hash.
• Xray: Xray 26.3.27 + TunnelDeck compatibility patch for macOS arm64, built
  from the pinned official source. JSON/outbound imports and
  VLESS/Trojan links (RAW, WS, gRPC, XHTTP, HTTPUpgrade as applicable).
  JSON can carry VMess/Shadowsocks and other supported Xray outbounds.
  A separate HevSocks5Tunnel 2.19.0/lwIP engine supplies the IP/TCP packet layer
  and forwards TCP/UDP through a generated loopback SOCKS5 listener in Xray.
  This replaces the previous Xray-native TUN ingress. MTU is 4064, interface
  addresses are 198.18.0.1/24 and fd00:1234:ffff::10/64.
  The helper supplies routing/DNS and resolves server hostnames before capture.
  Server IPs have physical-gateway bypass routes. Direct outbounds are bound
  to the original physical interface. Server transports are also constrained to
  that interface; other imported socket options remain.
  For REALITY/Vision with generic Chrome/Safari fingerprints, a dedicated
  TunnelDeck ClientHello profile uses Safari15_5-compatible settings
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
All profile data, including passwords, camouflage, original AWG/Xray configurations,
unfinished server input and the selected profile, is saved automatically to
~/Library/Application Support/TunnelDeck/profiles.json. The version 3 JSON document
contains profile metadata, secrets indexed by profile UUID, and the shared routing policy. It has no additional
encryption; the directory is restricted to 0700 and files to 0600. Replacement is
atomic, with a private temporary file. The app does not access Keychain and has no
option to disable persistence for individual profiles. Pending edits are flushed
when switching profiles and quitting. Older metadata documents and profile arrays
are migrated on save, preserving IDs, order and selection; old Keychain secrets
are not imported and must be entered again. Session authentication cookies remain
temporary. A read/format error blocks writing until the file is repaired and the
app restarted; a failed write preserves the last document and the current edits.
Profile rows share the main window's profile-specific connection status.
The menu bar uses a chain, a circled chain while busy, and a filled circle
around the chain when connected.
Application logs are sanitized before they reach the UI or its copy action.
The on-disk session journal is capped at 5,000,000 bytes. Old diagnostic
records are cleared at the limit, while the latest lifecycle events are retained.
The UI tracks rotations without replaying events and keeps its last 1,200 entries.
At startup, abandoned session directories are removed only when neither the UI
nor helper holds their lease. Active sessions and legacy directories without
a lease are left alone.

This is a local, ad-hoc-signed development application, not an App Store build.
It is not notarized or a production SMAppService privileged-helper installation.
All protocol engines and OpenConnect's network script are included. OpenConnect
links only Apple system dylibs; its OpenSSL code is statically included.
Packaging checks verify this and the macOS 14 deployment target. Launch on an
older macOS or a separate clean Mac still requires verification. A production
release needs signed/notarized packaging, privilege lifecycle review and integration
testing for sleep, roaming, forced engine failure and IPv6-only networks.

Current testing scope:
Automated tests cover camouflage URL preservation, configuration injection,
AWG advanced parameters, Xray import/isolation and credential redaction.
The Swift suite also covers automatic persistence/reload for every protocol,
legacy migration, profile selection, file permissions, failed writes, damaged or
unsupported documents, pending edits on deletion, incomplete server input, and
profile-specific status indicators. The current suite passes 48 tests, including
12 persistence tests and 8 bounded-journal/session-cleanup tests. Tests use temporary files and
synthetic credentials, without accessing real user profiles or Keychain.
Local real-engine checks passed: relocated bundled OpenConnect runs with a
clean system PATH, rejects an untrusted certificate/wrong pin and sends the
exact initial camouflage POST with an explicit CA or valid pin. These tests
passed for both the source runtime and the signed app copy, without login,
DTLS, route changes or VPN data transfer. A real ocserv session using the new
OpenSSL backend has not yet been verified. Official AWG tools parse
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
removed utun300. At that live verification on 15 October 2026, 26 Swift tests
and two offline ClientHello tests passed; the current Swift suite is described above.
IPv6-only upstreams and sleep/roaming remain outside this live verification.
The patched core rebuilds reproducibly from the pinned source plus repo patch;
the app bundle includes that patch and the third-party license notice.
Implementation details, verification results and runtime limitations are
recorded in docs/PROTOCOLS.md.

Pinned upstream sources:
https://www.infradead.org/openconnect/
https://github.com/amnezia-vpn/amneziawg-go/tree/v3.1.20260828
https://github.com/amnezia-vpn/amneziawg-tools/tree/v3.1.20260812
https://github.com/XTLS/Xray-core/releases/tag/v26.3.27
https://github.com/heiher/hev-socks5-tunnel/releases/tag/2.19.0
Licenses are in Runtime/licenses and Runtime/xray/LICENSE (bundled in the app).

Routing validation (from TunnelDeck/):
  swift test
  python3 Tests/Integration/routing_smoke.py
  python3 Tests/Integration/engine_smoke.py
  ./script/build_and_run.sh --build-only
The routing smoke uses the actual Swift compiler output and bundled core with
synthetic loopback TCP/UDP/DNS/GeoIP fixtures. It does not create utun, change
system routes/DNS, or prove a new remote VPN handshake/data session. See
docs/PROTOCOLS.md for verified boundaries and remaining live checks.
