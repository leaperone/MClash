# Privacy

MClash is a local macOS network utility. It does not include product analytics,
advertising SDKs, or an MClash crash-reporting service. Network traffic is
handled on your Mac by the bundled mihomo core and the App Routing Network
Extension.

## Data stored on this Mac

MClash stores profiles, subscription metadata, settings, runtime state, and
optional traffic history under `~/Library/Application Support/MClash`. These
directories use permissions limited to the current macOS user.

Traffic history records narrow routing metadata such as an application identity,
destination, route, result, and measured byte totals. It does not persist packet
payloads, process IDs, user IDs, or executable paths. The default retention is
30 days; Settings can disable local history or select 7, 30, or 90 days. Traffic
history is excluded from MClash profile backups.

Automation tokens are stored by clients in the current user's Keychain. MClash
stores only token hashes and the paired code identity. Pairings expire after 180
days and can be revoked.

## Network requests

MClash makes network requests only to provide requested product functions:

- downloading or refreshing subscription URLs and providers you configure;
- carrying traffic through the proxy routes in your active profile;
- checking the signed GitHub-hosted Sparkle update feed; and
- performing latency tests or core operations you initiate.

Those services and any proxy provider you configure receive data under their own
privacy terms. MClash does not send your profiles, traffic history, or automation
commands to a Leaperone analytics service.

## Exports and sensitive data

Diagnostic exports redact common credentials, bearer tokens, sensitive query
values, and subscription details. Review an export before sharing it because
application names, destinations, and operational details may still be private.

Backup archives are intentionally unencrypted and may contain full subscription
URLs and proxy credentials. Store and share them as secrets.

## Removing data

Remove profiles and clear traffic history in MClash before uninstalling. To
remove all remaining local data, quit MClash and delete its Application Support
directory and any `one.leaper.mclash.automation` entries that you no longer want
from Keychain Access.
