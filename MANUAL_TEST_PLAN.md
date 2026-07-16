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
- Switch among at least three profiles. When connected, confirm MClash validates
  before interruption, reconnects automatically, and restores system proxy only
  after the new controller is ready.
- Open each of the first three policy groups, search for a long node name, select
  it, and run latency testing. Confirm large node lists scroll smoothly.
- Refresh the active subscription while connected. Confirm an unchanged
  subscription does not restart the core and an updated subscription safely
  reconnects.

## 5. Main feature coverage

- Proxies: test Rule/Global/Direct, system proxy, group selection, searchable
  node picker, selected-node display, and group latency testing.
- Rules: search by type, payload, and policy; verify result counts and hit counts.
- Providers: refresh all, update proxy providers, run health checks, update rule
  providers, and verify subscription usage/expiry where supplied.
- Connections: search by host/process/rule/node, sort table columns, inspect one
  connection's metadata, close one connection, and close all connections.
- Logs: confirm source filters, search, pause/resume follow, export, and Clear
  work and the list remains responsive under load.
- Overview: verify traffic chart/rates, total traffic, routing mode, current
  proxy, connection count, memory, HTTP/SOCKS addresses, system proxy state, and
  core version.

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
