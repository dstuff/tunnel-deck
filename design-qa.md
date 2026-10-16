# TunnelDeck — compact connection list

final result: passed

Selected visual: option 1, `Design/ConnectionList/reference.png` (1377 × 1142).
Implementation: `Design/ConnectionList/implementation-connected-final.png` (1560 × 1260).
Native window: 780 × 630 points, Retina scale 2. Source normalized to width
780 points while retaining its aspect ratio (780 × 647); implementation normalized
to 780 × 630. No stretching. This is a macOS application, so CSS size does not apply.
State: dark, three synthetic profiles, first profile connected in isolated DEBUG
preview. Preview status is simulated and is not evidence of VPN connectivity.

## Comparison history

Initial evidence: `Design/ConnectionList/comparison-initial.png` and
`Design/ConnectionList/comparison-focus-initial.png`, source left / application
right in each shared comparison image. The focused image includes the title bar,
status and profile rows, with legible text and controls.

- P2: Status section and rows are taller than the selected mock. Reduce status
  vertical padding/minimum height and row padding; align the profile name column.
- P2: Native toolbar initially collapsed Add Connection to an icon; native
  background-window buttons also reduced action prominence. Keep the full text
  label and explicit blue primary / outlined secondary styles.
- P2: Verify that auxiliary windows open and come to the front from row actions;
  use explicit app activation and provide a keyboard path for profile settings.

Second comparison: `Design/ConnectionList/comparison-final.png` and
`Design/ConnectionList/comparison-focus-final.png`, again source left / application
right. Status padding and row height are reduced; the name column aligns with
the source; primary actions stay blue, secondary actions have explicit outlines,
and the Add button retains its label. Native row actions now activate the app
before presenting an auxiliary window. Add, profile settings and diagnostics were
opened and inspected after the rebuild. No actionable P0/P1/P2 findings remain.

## Required fidelity surfaces

- Typography: system SF UI with a 16-point semibold profile name and 19-point
  semibold status; readable native callout/caption supporting text. The focused
  comparison checks text weights, alignment and single-line action labels.
  `Design/ConnectionList/long-name.png` confirms that long names truncate rather
  than resize or wrap action buttons. System font fallback and optical rendering
  remain platform-owned; there are no downloaded fonts or rasterized labels.
- Spacing: revised status and row spacing follows the source hierarchy. At the
  same normalized width, the application is 17 points shorter overall; this is an
  accepted initial window-size difference, with persistent footer controls and a
  scrolling profile area. No clipped controls or nested cards.
- Colors: semantic system-adaptive surfaces, green connected status and blue
  actions. Normal use follows the system theme; the comparison preview is dark.
  The source's decorative gradient is replaced by the native flat window surface.
  The active row has a restrained blue fill and hairline border. Status also has
  a text label, and primary/secondary actions remain distinguishable by shape.
- Assets: existing SF Symbols are used; the mock contains no raster illustrations.
  Platform window chrome and its screen-sharing indicator are supplied by macOS.
- Copy: profile names match the source in preview. The application displays Xray
  rather than claiming a specific outbound subtype from protocol metadata alone.
  Timer is live; its exact value differs from the mock.

The full-view and focused comparisons were opened together for review. A focused
crop is included because typography, the toolbar label, row alignment and action
affordances require closer inspection than a full-window image alone.

## Verification so far

- Current unit suite: 39 tests passed, including 12 persistence tests,
  leading-comment AWG import and failed import rollback. DEBUG application
  packaging/signature verification and normal launch passed. A separate release
  build passed during the earlier UI verification, before the storage migration.
  Username and password fields from a previous OpenConnect step are ignored for
  other protocols.
- Native add flow: Command-N, rejection of an incomplete VLESS link, recognition
  of an example OpenConnect address, credential fields and cancellation without
  saving into the real profile store.
- Isolated preview: switching changes the active row and status; deleting the
  active profile is disabled. Full JSON import completed with a long test name;
  the new row appeared without connecting automatically.
  Disconnect returned all rows to Connect. Profile settings opened from the row
  menu and through Command-I, displayed the correct profile and closed with Done.
  Diagnostics opened from the footer in a separate native window.
- Additional native evidence: `Design/ConnectionList/profile-editor.png` and
  `Design/ConnectionList/long-name.png`. Light/system theme was also inspected in
  the normal app and in the auxiliary form. These images were captured during
  the earlier UI pass, before removal of the Keychain persistence toggle.
- Local storage follow-up, 16 October 2026: the settings, profile editor and
  import confirmation were inspected after replacing Keychain with one local
  profile file. Their copy now describes automatic local persistence; there is
  no secrets-persistence toggle. Tests restore every protocol's fields from disk
  and cover legacy formats, file permissions and read/write failures. The preview
  uses a separate temporary file and the normal app starts without connecting.
- Browser console checks do not apply: this is the native SwiftUI app, not a web
  prototype. No browser-only replacement was built.
- Real servers / handshake / routes were not exercised for this UI change.

## Follow-up polish

- P3: macOS renders the ellipsis Menu as a native symbol rather than reproducing
  the mock's circular artwork exactly. It retains its tooltip, accessibility
  label and context-menu alternative. Existing protocol SF Symbols are preserved.
- Native window chrome and the automation screen-sharing indicator differ from
  the conceptual image; these are not app content or raster assets to recreate.

## Implementation checklist

- [x] Compare full view and focused regions after fixing initial findings.
- [x] Verify all five fidelity surfaces and key native interactions.
- [x] Verify local parsing, persistence and cancellation/cleanup coordination.
- [x] Keep real VPN connectivity outside the claims of this design QA pass.
