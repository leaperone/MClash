# MClash Release Candidate Manual Test Plan

This checklist is intentionally limited to user-driven UI validation. It does
not require TUN, configuration-file editing, or exposing the controller secret.
Use a non-production macOS account or be prepared to restore network settings
before testing failure scenarios.

## 1. Clean launch and first profile

- Launch MClash with no profiles. Confirm Overview, the sidebar footer, and the
  menu bar all say traffic capture is off and explain that a profile must be
  chosen. They must not present an empty profile list as healthy if application
  storage failed to initialize.
- Open the menu bar popup repeatedly. Confirm every row is clickable, the popup
  remains within the screen, the status/actions/profile/mode/proxy groups are
  visible above the footer, and **Open MClash**, **Settings**, and **Quit** work.
- In Profiles, open **Add Subscription**. Confirm a URL without `http://` or
  `https://` cannot be submitted.
- Add a valid Clash subscription. While it downloads and validates, confirm the
  sheet shows progress, fields and Add are disabled, Cancel remains available,
  and the rest of the window is visibly modal rather than apparently frozen.
- Confirm success creates exactly one profile, activates it, closes the sheet,
  and restores sidebar/toolbar interaction.
- Repeat with an invalid or unreachable URL. Confirm the error appears inside
  the sheet and Cancel returns to a fully clickable Profiles screen.

## 2. Core and connection lifecycle

- Connect with a subscription that does not define `port`, `socks-port`, or
  `mixed-port`. Confirm MClash creates a temporary local listener and displays
  usable HTTP and SOCKS5 addresses without changing the stored subscription.
- Confirm Connect does not display a Keychain, login key, or account-password
  authorization prompt. A macOS network-settings prompt, if the OS requires one
  for system proxy changes, must be clearly attributable to that operation.
- Connect from Overview, then disconnect from the menu bar. Confirm the status,
  traffic, proxy groups, rules, providers, and connections return to their
  disconnected states.
- Repeat connect/disconnect rapidly. Confirm transitional buttons are disabled
  and the core never launches twice.
- Quit while disconnected and relaunch. Confirm the active profile persists.
- With the core connected, terminate only the bundled `mclash-mihomo` process from
  Activity Monitor. Confirm MClash reports the crash, performs bounded restart,
  reconnects live metrics without duplicating streams, and safely restores then
  re-enables System Proxy if it was on before the crash.
- On a clean macOS account, block outbound access to GitHub before importing a
  profile containing GEOIP, GEOSITE, and IP-ASN rules. Confirm profile validation
  and the first connection succeed without a GEO database download. Repeat with
  `geodata-mode: true` to cover `GeoIP.dat` as well as the default MMDB mode.

## 3. macOS system proxy safety

- Before testing, note the current macOS proxy settings for the active network
  service.
- Connect, enable **Use macOS System Proxy**, and confirm HTTP/HTTPS traffic uses
  MClash. Also verify `curl --socks5-hostname` succeeds through the SOCKS5
  address shown in Overview. Disable it and confirm the exact previous macOS
  settings return.
- With the default preference enabled, confirm Connect starts the core and then
  enables the system proxy only after HTTP/SOCKS listener readiness. Turn off
  **Enable macOS system proxy when connecting** in Settings and confirm a later
  Connect leaves the system proxy off while manual proxy addresses remain usable.
- Enable the system proxy, then disconnect from Overview and from the menu bar.
  Confirm the previous settings are restored before the core stops and normal
  networking continues.
- Enable the system proxy and Quit MClash. Confirm Quit waits for restoration and
  normal networking continues afterward.
- Enable the proxy, force-terminate MClash, then relaunch. Confirm startup detects
  and restores the persisted snapshot before normal controls become available.
- Simulate or trigger a System Proxy permission failure. Confirm the error can be
  dismissed, the Sidebar remains clickable, and a failed activation that made no
  changes does not leave a recovery snapshot or block Quit.
- If a genuine restore failure is present, Quit must show **Try Again**,
  **Cancel**, and **Quit Anyway**. Confirm Quit Anyway stops the bundled core but
  preserves the snapshot for the next recovery attempt.

## 4. Local proxy ports and restart safety

- In Settings, confirm **Local Proxy** presents HTTP, SOCKS5, and Mixed as
  independent listeners and identifies whether each value comes from the
  profile, a custom override, or MClash's temporary fallback.
- Open **Edit Ports & Restart…**. For each listener, verify **Profile**,
  **Custom**, and **Off** have explicit meanings. Custom ports must accept only
  `1...65535`; duplicate enabled ports must be rejected beside the fields.
- Set HTTP, SOCKS5, and Mixed to three different free ports. Apply while
  connected and confirm progress advances through validation and restart,
  MClash reconnects automatically, and an enabled macOS System Proxy is
  restored only after the new listeners answer their respective protocols.
- Apply the same values again. Confirm MClash reports no change and does not
  restart the core.
- Occupy one requested port with another local process, then apply. Confirm the
  old configuration, core session, and System Proxy state are all restored and
  the failed values are not persisted.
- Confirm Overview, Proxies, Settings, and the menu bar all show the same three
  listener identities. Click every visible address and confirm it copies the
  complete `127.0.0.1:port` value with immediate visual feedback.

## 5. Daily menu bar workflow

- Verify **Mihomo Core** and **macOS Capture** are separate rows. A running Core
  with System Proxy and App Routing both off must say capture is off/local only,
  never simply “Connected”.
- Verify upload/download rates, active connections, App Routing relay/rule
  counts, and the last successfully proxied-flow evidence are readable in both
  light and dark appearance. Interrupt a live stream and confirm its cached
  number becomes **Stale** or **Unavailable**, not a plausible live zero.
- Open Overview, Traffic, App Routing, and Attention from the menu bar. Confirm
  each opens the existing main window at the requested destination.
- Switch Rule / Global / Direct and confirm the main Proxies view reflects the
  server-confirmed mode. With the default Settings option enabled, confirm old
  connections close so the new route takes effect immediately; disable the
  option and confirm existing connections are preserved.
- In the menu bar popup, confirm Rule uses the same **Nested Groups → Entry
  Groups → Special Groups** order as the Proxies tab, Global shows only
  GLOBAL, and Direct hides proxy-group controls entirely.
- Switch among at least three profiles. When connected, confirm MClash validates
  before interruption, reconnects automatically, and restores system proxy only
  after the new controller is ready.
- Open each of the first three policy groups, search for a long node name, select
  it, and run latency testing. Confirm large node lists scroll smoothly.
- Refresh the active subscription while connected. Confirm an unchanged
  subscription does not restart the core and an updated subscription safely
  reconnects.

## 6. Main feature coverage

- App Routing: confirm the dedicated sidebar destination opens its rule table,
  Settings shows only a status summary and **Manage App Routing…**, and the
  selected destination is restored after relaunching the app.
- App Routing: add a rule by selecting a running application, then add another
  with **Choose Other Application…** and select a signed `.app` that is not
  running. Confirm its icon, display name, bundle identifier, and executable
  path appear before saving.
- App Routing: verify `com.google.*` matches application bundle/signing IDs and
  `*.example.com` is presented and saved as a domain-and-subdomains match.
  Confirm exact app selection remains based on its designated code-signing
  requirement.
- App Routing: duplicate, edit, disable, delete, and move rules up/down. Confirm
  the table order is the evaluation order and the first matching rule wins.
  While an existing App Routing relay and an unrelated Mihomo connection are
  active, edit only match criteria or priority and confirm both connections stay
  online. Add a rule that needs a previously unavailable Mihomo group listener
  and confirm the app uses the verified restart path instead.
- App Routing: keep Advanced Matching collapsed for the normal application →
  Mihomo path, then expand it and verify exact process, executable path, UID,
  IP, CIDR, domain, TCP/UDP, port range, and unavailable-route fallback inputs.
- App Routing: turn the feature on while connected, approve the system
  extension if macOS requests it, and confirm the status reaches **App Routing
  On**. If it reports **Restart Required**, restart macOS and repeat the check.
- App Routing: open **Activity** and create long-lived traffic from two
  applications. Confirm each live provider-owned connection occupies one stable
  row for its lifetime; app/PID, target host/IP/port, route, relay state, current
  download/upload speed, transferred bytes, and duration update automatically.
  Close each connection and confirm its row disappears on the next activity
  refresh instead of remaining as history. Double-click a row and verify the
  complete Application → Capture → App Rule → Mihomo Rule → Proxy Path →
  Destination pipeline.
- App Routing: exercise a normal Direct rule and confirm it does not appear as a
  live connection because macOS owns it after handoff. Exercise a provider-owned
  Direct fallback and confirm it remains visible with measured speed. Stop or
  invalidate the Provider while the Host stays open;
  after bounded retries, green On must become a durable Attention/Failed state
  with the actual disconnect reason and a Retry action.

- Proxies: confirm Rule groups follow the subscription YAML order rather than
  alphabetical order. Global must show only GLOBAL, and Direct must show a
  clear bypass state instead of irrelevant node controls.
- Proxies: confirm the Sidebar follows **Nested Groups → Entry Groups → Special
  Groups**. Resize the detail area to the minimum width; List must still show
  the group Sidebar and node list, and long names must remain distinguishable
  and available in help text.
- Proxies: at default and wide window widths, confirm the group and node columns
  consume the complete workspace without an unused blank region. On a wide
  window, open Inspector and confirm it forms a stable third column without
  hiding the group Sidebar or leaving a gap between nodes and details.
- Resize the main window below 900×600 points. Confirm AppKit enforces that
  minimum content size and every destination remains usable at the boundary.
- Proxies: with a large subscription and live connections, enter and leave the
  tab repeatedly, scroll the node list, and remain on the page for at least
  three five-second proxy refresh cycles. The window, spinner, scrolling, and
  sidebar selection must remain responsive. Inspector should start as the third
  column on a wide window and remain closed on a narrow window; showing either
  presentation must not stall live updates.
- Proxies: switch between **List** and **Topology**. Confirm List retains its
  two-column structure while the independently rendered Topology may use a
  compact group navigator at narrower widths. Confirm nested groups appear once,
  the highlighted route follows `group → child group → final node`, dialer
  dependencies use a distinct dashed connection, and large groups use a “more
  nodes” summary instead of rendering every node at once.
- Proxies: select a nested group from the Sidebar, from a list-row chevron, and
  from a topology group chevron. Confirm the List, Topology, and Inspector
  stay synchronized and the current route remains readable with long names.
- Proxies: test Profile / Latency / Name sorting. Profile order must remain
  stable, equal latency results must keep their profile order, and changing one
  group's sort must not change another group's saved preference.
- Proxies: for URLTest and Fallback groups, pin a preferred node and confirm the
  UI distinguishes the pinned preference from the current healthy node. Run
  **Test All** and confirm the fixed marker and preference remain unchanged.
  Use **Resume Automatic** and confirm the fixed marker disappears.
  LoadBalance groups must explain that the final node varies per connection and
  must not present a misleading manual-selection action.
- Proxies: create traffic through several domains. Confirm Inspector labels the
  data as observed this session and shows the real domain, rule, root-to-leaf
  chain, traffic deltas, active connection counts, and focused-node scope.
- Proxies: verify topology zoom, scrolling, Inspector show/hide, node selection,
  latency testing, keyboard focus, VoiceOver labels, and Reduce Motion behavior.
  Resize the detail area to its minimum width and confirm the topology toolbar
  switches to compact controls without clipping. With VoiceOver, confirm member
  edges, current-path edges, and both active and inactive dialer dependencies
  are announced with distinct relationships.
- Rules: search by type, payload, and policy; verify result counts and hit counts.
- Providers: refresh all, update proxy providers, run health checks, update rule
  providers, and verify subscription usage/expiry where supplied.
- Traffic: in **Live**, search by host/process/rule/node, sort columns, inspect a
  connection, close one, and close all. In **Apps** and **Routes**, verify active
  counts, observed flow counts, exact measured traffic, and partial-coverage
  warnings. In **History**, verify completed Mihomo and App Routing flows retain
  app, destination, capture origin, result, traffic semantics, and end time.
- Traffic: Direct/fail-open rows and aggregates must explicitly mark unmeasured
  handoffs; rejected rows must say no payload. Interrupt Mihomo or Provider
  telemetry and confirm existing rows are labeled last-known/stale rather than
  disappearing or masquerading as current data.
- Logs: confirm source filters, search, pause/resume follow, **Export
  Diagnostics…**, and Clear work under load. Inspect the exported report for
  operating status, concurrent Attention items, source freshness, and filtered
  logs. Seed test messages containing Bearer tokens, URL credentials, query
  tokens, `-secret`, and password fields; exported text must redact their values.
- Overview: verify the operational summary, capture coverage, concurrent
  Attention count, Core/System Proxy/App Routing rows, current rates, connection
  count, Mihomo session total, active App relays, Top Applications, Top Routes,
  traffic chart, routing mode, current proxy, HTTP/SOCKS addresses, and core
  version. At a normal wide window, Traffic and Configuration must appear side
  by side; at a narrow width they must return to one readable column.
- Overview: interrupt traffic telemetry. Current rates and Mihomo session total
  must change to **Stale**, while the retained chart is labeled **Last received
  samples**. Restore telemetry and confirm the live labels recover.
- Attention: create simultaneous controller, Provider, and system-proxy guard
  failures where practical. Confirm all issues remain visible at once, each
  explains the user consequence, technical detail, and recovery action, and one
  transient banner cannot hide the other issues.
- Across every tab, switch between light and dark appearance and between empty
  and populated states. Confirm the page background stays continuous, lists
  keep consistent outer margins, and banners do not stack or change the page
  surface unexpectedly.
- With no traffic, confirm download and upload show `0 B/s`, totals show `0 B`,
  and no surface spells the value as `Zero`.

## 7. Accessibility and edge cases

- Navigate the sidebar, toolbar, menu popup, subscription sheet, node picker,
  and error actions using only the keyboard.
- With VoiceOver, confirm status is announced with text rather than color alone,
  icon buttons have names, and selected profiles/nodes are identifiable.
- Test system light/dark appearance, Increase Contrast, Reduce Transparency, and
  Reduce Motion.
- Test very long profile/group/node names, at least 500 nodes in one group, and
  several thousand rules. Confirm truncation, search, scrolling, and buttons
  remain usable.
- Test offline startup, subscription HTTP errors, provider update errors, delay
  timeouts, and controller degradation. Confirm errors remain dismissible and
  do not leave an invisible modal layer.

## 8. Signed application updates

- Install a notarized release in `/Applications`, then choose **MClash > Check
  for Updates…**. Confirm Sparkle presents its native result and never opens a
  browser as the primary update path.
- Toggle automatic checks and automatic downloads in Settings, relaunch, and
  confirm both choices persist.
- For an update test, run MClash with the core connected and macOS System Proxy
  enabled. Accept **Install and Relaunch** and confirm MClash restores the prior
  network proxy state, stops mihomo, installs the signed update, and relaunches.
- Simulate a system-proxy restoration failure before accepting the update.
  Confirm MClash cancels termination and Sparkle does not replace the running
  application until restoration succeeds or the user explicitly chooses to
  quit anyway.
- Inspect the shipped `Info.plist` and confirm `SUFeedURL` targets the current
  repository, `SUPublicEDKey` is populated, and the downloaded archive's
  EdDSA signature is accepted. An unsigned or modified archive must fail.

## Release sign-off

Record macOS version, Mac architecture, MClash version/build, bundled mihomo
version, profile type, and pass/fail notes for every section. A release is not
approved if any system-proxy restoration case fails or if a control can enter a
persistent non-clickable state.
