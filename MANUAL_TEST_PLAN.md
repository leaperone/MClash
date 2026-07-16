# MClash Release Candidate Manual Test Plan

This checklist is intentionally limited to user-driven UI validation. It does
not require TUN, configuration-file editing, or exposing the controller secret.
Use a non-production macOS account or be prepared to restore network settings
before testing failure scenarios.

## 1. Clean launch and first profile

- Launch MClash with no profiles. Confirm the main window and menu bar item both
  show **Disconnected** and **Choose a Profile**.
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
- With the core connected, terminate only the bundled `mihomo` process from
  Activity Monitor. Confirm MClash reports the crash, performs bounded restart,
  reconnects live metrics without duplicating streams, and safely restores then
  re-enables System Proxy if it was on before the crash.

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

## 4. Daily menu bar workflow

- Verify current status, active profile, upload/download rates, and any degraded
  live-data warning are readable in both light and dark appearance.
- Switch Rule / Global / Direct and confirm the main Proxies view reflects the
  server-confirmed mode. With the default Settings option enabled, confirm old
  connections close so the new route takes effect immediately; disable the
  option and confirm existing connections are preserved.
- In the menu bar popup, confirm Rule shows only relevant rule groups, Global
  shows only GLOBAL, and Direct hides proxy-group controls entirely.
- Switch among at least three profiles. When connected, confirm MClash validates
  before interruption, reconnects automatically, and restores system proxy only
  after the new controller is ready.
- Open each of the first three policy groups, search for a long node name, select
  it, and run latency testing. Confirm large node lists scroll smoothly.
- Refresh the active subscription while connected. Confirm an unchanged
  subscription does not restart the core and an updated subscription safely
  reconnects.

## 5. Main feature coverage

- Proxies: confirm Rule groups follow the subscription YAML order rather than
  alphabetical order. Global must show only GLOBAL, and Direct must show a
  clear bypass state instead of irrelevant node controls.
- Proxies: confirm **Nested Groups** is the first Sidebar section. Resize the
  detail area until node rows and group controls enter their compact layouts;
  long names must remain distinguishable and available in help text.
- Proxies: with a large subscription and live connections, enter and leave the
  tab repeatedly, scroll the node list, and remain on the page for at least
  three five-second proxy refresh cycles. The window, spinner, scrolling, and
  sidebar selection must remain responsive. Inspector should start closed and
  opening it must not stall live updates.
- Proxies: switch between **List** and **Topology**. Confirm nested groups appear
  once, the highlighted route follows `group → child group → final node`,
  dialer dependencies use a distinct dashed connection, and large groups use a
  “more nodes” summary instead of rendering every node at once.
- Proxies: select a nested group from the Sidebar, from a list-row chevron, and
  by double-clicking a topology group. Confirm the List, Topology, and Inspector
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
- Connections: search by host/process/rule/node, sort table columns, inspect one
  connection's metadata, close one connection, and close all connections.
- Logs: confirm source filters, search, pause/resume follow, export, and Clear
  work and the list remains responsive under load.
- Overview: verify traffic chart/rates, total traffic, routing mode, current
  proxy, connection count, memory, HTTP/SOCKS addresses, system proxy state, and
  core version. At a normal wide window, Traffic and Configuration must appear
  side by side; at a narrow width they must return to one readable column.
- Across every tab, switch between light and dark appearance and between empty
  and populated states. Confirm the page background stays continuous, lists
  keep consistent outer margins, and banners do not stack or change the page
  surface unexpectedly.
- With no traffic, confirm download and upload show `0 B/s`, totals show `0 B`,
  and no surface spells the value as `Zero`.

## 6. Accessibility and edge cases

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

## Release sign-off

Record macOS version, Mac architecture, MClash version/build, bundled mihomo
version, profile type, and pass/fail notes for every section. A release is not
approved if any system-proxy restoration case fails or if a control can enter a
persistent non-clickable state.
