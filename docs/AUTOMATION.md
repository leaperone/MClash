# MClash Automation API v1

MClash exposes user-level application operations to local AI agents and other
same-user tools. The API is intentionally a stable domain command surface, not
reflection over `AppModel` and not a passthrough to Mihomo's controller.

## Quick start

Install MClash in `/Applications`, then choose **Settings → Advanced →
Install Command Line Tool**. This creates `~/.local/bin/mclashctl`; MClash will
not replace an existing file or a link to another target. Add `~/.local/bin` to
the shell or agent `PATH` yourself if it is not already present. For example:

```sh
export PATH="$HOME/.local/bin:$PATH"
mclashctl capabilities --pretty
mclashctl status --pretty
mclashctl core.connect
mclashctl profiles.list --pretty
mclashctl systemProxy.setEnabled --params '{"enabled":true}'
```

If the app was moved and the command points to an old absolute app path, inspect
the link before changing it:

```sh
readlink "$HOME/.local/bin/mclashctl"
```

Only after confirming that the printed target is the obsolete MClash helper,
remove that link, move MClash directly into `/Applications`, and use the in-app
installer again:

```sh
unlink "$HOME/.local/bin/mclashctl"
```

Do not use `ln -sf`: it bypasses the installer's ownership and target checks and
can overwrite a file that MClash did not create.

The first positional argument may be any method returned by
`system.capabilities`. `status` and `capabilities` are aliases for
`system.snapshot` and `system.capabilities`.

The first authenticated command opens a local pairing dialog. **Allow Needed
Access** grants the scopes requested so far; later requests accumulate scopes
and may open the dialog again. **Trust This Client** grants every scope and
permits unattended destructive operations. `mclashctl` saves the returned token
in the current user's Keychain and retries the original command with the same
request ID. MClash stores only a SHA-256 token hash. Pairings expire after 180
days and can be inspected or revoked with `auth.clients.list` and
`auth.clients.revoke`. Trust is monotonic for a pairing: revoke the client before
pairing it again if you want to return it to standard access.

`mclashctl` is intentionally a user-level broker: granting it authority allows
other processes running under the same macOS login to invoke that authority by
executing the helper. Standard access still requires a one-time local
confirmation for each destructive operation. Trusting `mclashctl` allows those
same-login processes to perform destructive operations unattended. Clients that
need an identity boundary between agents should use their own independently
code-signed native executable and connect to the socket directly. Pairing a
shared interpreter such as Python, Node, or a shell binds the interpreter
identity, not an individual script.

CLI options:

- `--params '<json object>'` supplies method parameters.
- `--params-stdin` reads a JSON params object from standard input; use it for
  subscription URLs, inline profiles, and other secrets so they do not enter
  process arguments or shell history.
- `--params-file <path>` reads the JSON params object from a file.
- `--allow-interaction` allows a capability marked `requiresInteraction` to
  present its local panel or, for a standard client, its one-time confirmation.
  It never grants or upgrades trust.
- `--pretty` pretty-prints the response.
- `--no-launch` fails instead of opening MClash when it is not running.
- `--timeout <seconds>` sets the startup/request timeout (default 60 seconds).
  Interactive operations automatically receive at least 330 seconds.
- `--request-id <id>` supplies a stable request ID. Follow the structured
  same-ID/new-ID recovery flags described below.
- `--server-instance <PID:nonce>` binds same-ID recovery to the server instance
  reported with an indeterminate response. It requires `--request-id`.
- `--socket <path>` selects an explicit development socket.

When the CLI launches MClash, it starts it without presenting the main window;
the menu bar item and automation service remain active. An explicit development
socket never receives or persists the production Keychain token.

Exit code 0 means an RPC result, 2 means an RPC error, and 1 means the CLI could
not form the request or connect. Stdout contains only the JSON-RPC response;
client diagnostics go to stderr.

## Protocol

The discovery document is stored at:

```text
~/Library/Application Support/MClash/Automation/endpoint.json
```

It is a user-owned mode-0600 regular file. The actual Unix socket uses a short,
random path under the user's temporary directory and is also mode 0600. MClash
checks the connecting process with `getpeereid` and rejects a different UID.

Each connection carries one request and one response. Messages are UTF-8 JSON
preceded by a four-byte unsigned big-endian payload length. The maximum frame
size is 1 MiB. Requests use this envelope:

```json
{
  "jsonrpc": "2.0",
  "apiVersion": 1,
  "id": "client-generated-id",
  "method": "routing.proxy.select",
  "params": {
    "group": "GLOBAL",
    "proxy": "Hong Kong 01"
  },
  "allowInteraction": false,
  "authorization": "paired-client-token"
}
```

Every response contains the same `id`, `apiVersion`, and exactly one of
`result` or `error`. Clients must call `system.capabilities` instead of assuming
that a method exists in every application version.

Clients may rely on schema versions, IDs, enums, error codes, and error types as
machine-readable contracts. Human-readable fields such as `message`, `title`,
`consequence`, `technicalDetail`, `lastError`, and supervisor log text are
opaque, may follow MClash's selected interface language, and may change wording.
Mihomo stdout and stderr remain verbatim. Diagnostic text queries match the
rendered text in its current language.

`system.capabilities` and `auth.pair` are the only unauthenticated methods.
Capabilities report `requiredScope`, `requiresInteraction`, risk, parameter
names, types, and whether each parameter is required. Interactive presentations
are globally rate-limited. The scopes are:

- `read.basic`: redacted application and operating state.
- `read.sensitive`: connections, process candidates, rules, logs, and detailed
  diagnostics. Logs and error text are still redacted for credentials.
- `control`: non-destructive state changes.
- `destructive`: destructive requests; standard clients need local approval for
  each call, while trusted clients may invoke them unattended.

Recent mutation request IDs are idempotent per paired client for the current
MClash process (up to 256 responses or 4 MiB per client, with a global cap of
1,024 responses or 16 MiB). Reusing the same ID and identical parameters
retrieves the result of the same execution; reusing it with different parameters
is rejected. When an error has `retryable: true` and
`data.retryWithNewRequestID: true`, correct its stated precondition and use a
new ID to request a new execution. A transport `client_error` prints the
request ID to stderr. If an error reports `outcomeIndeterminate: true` and
`retryWithSameRequestID: true`, query again with `--request-id` set to that
same ID and `--server-instance` set to the reported binding; do not start a
duplicate execution. Paged list methods accept `offset` and
`limit` and return `items`, `total`, and `hasMore`. App Routing rule replacement
also requires the `expectedRevision` returned by the list/status query.

### Timeouts and safe recovery

For each socket request, the selected timeout is one absolute monotonic deadline
shared by connection, server verification, the complete request write, and the
complete response read. Time spent in one phase reduces the budget left for
every later phase; the timeout does not restart between reads or writes.

Transport failures use structured JSON on stderr. `phase` is `connect`,
`verify_server`, `write_request`, or `read_response`; the human-readable
`message` is not a stable contract. For example, a response timeout after the
complete request was written can look like:

```json
{"message":"Automation poll failed: Operation timed out","method":"configuration.apply","outcomeIndeterminate":true,"phase":"read_response","requestID":"7f990167-b9aa-44f5-a186-934f143d2be3","retryWithSameRequestID":true,"serverInstance":"43210:93aa5fc7-b2f2-4ac8-a3f2-c180affc88db","type":"client_error"}
```

At `read_response`, MClash may already have executed the request. If
`retryWithSameRequestID` is true, resend the identical method and parameters
with that exact request ID and the reported server instance to retrieve the
cached execution:

```sh
mclashctl configuration.apply --params-file proposed.json \
  --request-id 7f990167-b9aa-44f5-a186-934f143d2be3 \
  --server-instance 43210:93aa5fc7-b2f2-4ac8-a3f2-c180affc88db \
  --allow-interaction
```

The CLI refuses to send if the discovery PID or nonce changed and reports
`outcomeIndeterminate: true` with `retryWithSameRequestID: false`. Explicit
`--socket` connections have no trusted discovery binding; both transport errors
and RPC timeouts omit `serverInstance` and report
`retryWithSameRequestID: false`. Never generate a new ID for that recovery.
Reuse the original parameters and interaction flag exactly. An RPC
`operation_timeout` on stdout also includes `error.data.serverInstance` when
same-ID recovery is safe; copy that binding into the same option. Without a
binding it reports `retryWithSameRequestID: false`. If `retryWithNewRequestID`
is true instead, fix the reported precondition and begin a new execution with a
new ID.

`auth.pair` is the exception: an indeterminate transport failure must not be
retried automatically or recovered with the same request ID. If the server
reports a pairing timeout, no token was issued. Start a new pairing request only
when a user is ready to handle a new local authorization prompt.

## Operation families

The current v1 surface includes:

- `system.*`: capabilities and combined snapshots.
- `app.ui.*`, `app.quit`, `app.update.*`: UI, lifecycle, and Sparkle updates.
- `settings.*`: login, notifications, startup, and connection-reset behavior.
- `configuration.*`: redacted desired-configuration snapshots, validation,
  atomic persistence, object deletion, and workspace activation.
- `core.*`: status, connect, disconnect, toggle, and restart.
- `profiles.*`, `backup.*`: safe profile metadata, import/subscriptions,
  activation/refresh/removal, pending imports, and interactive backup panels.
- `runtime.*`: read, replace, and reset transactionally applied overrides.
- `routing.*`, `mihomo.rules.*`, `providers.*`: modes, groups, node selection,
  latency, rule refresh, and provider operations.
- `systemProxy.*`: status, enablement, preferences, and guard control.
- `appRouting.*`: status, enablement, DNS, transactional rule replacement,
  on-demand paged candidates, Proxifier preview/import, retry, and activity clearing.
- `traffic.*`: cached statistics/connections, connection closure, persistent
  Today/Week summaries, and paged session-ledger applications/routes/history.
- `logs.*`, `diagnostics.*`: cached logs, paged redacted reports, and actionable
  operational issues.

Run `mclashctl capabilities --pretty` for exact method names, risk levels, and
parameter hints from the running version.

## Unified Configuration workflow

The Configuration API edits MClash's desired Configuration manifest. It does
not expose source locations, node host values, node parameter values,
subscription secrets, or generated Mihomo YAML. `configuration.snapshot`,
`configuration.proxyGroup.selectors.export`, and `configuration.plan` require
`read.sensitive`; `configuration.apply`, `configuration.delete`, and
`configuration.workspace.activate` are destructive operations. A standard
client must pass `--allow-interaction` and receive local approval for each
destructive call; a trusted client may run them unattended.

The six methods are:

| Method | Parameters | Result |
| --- | --- | --- |
| `configuration.snapshot` | Optional `nodeOffset`, `nodeLimit`, `sourceOffset`, `sourceLimit` | Safe document, paged source/node summaries, revision, runtime metadata, diagnostics, and `diagnosticCount` |
| `configuration.proxyGroup.selectors.export` | `groupID`, `expectedRevision`, optional `offset`, `limitBytes` | One selector policy encoded as revision-bound Base64 byte chunks with total size and SHA-256 |
| `configuration.plan` | `document`, `expectedRevision` | `changed`, `valid`, `diagnostics`, `diagnosticCount`, `compilations` |
| `configuration.apply` | `document`, `expectedRevision` | Compact apply receipt |
| `configuration.delete` | `kind`, `id`, `expectedRevision` | Compact delete receipt; referenced objects are rejected rather than cascaded |
| `configuration.workspace.activate` | `id`, `expectedRevision` | Compact activation receipt and runtime snapshot |

### Snapshot, plan, and apply

Start every edit from a fresh snapshot. Offsets must be non-negative. Node
limits are `1...200` (default 100); source limits are `1...100` (default 50).

```sh
mclashctl configuration.snapshot \
  --params '{"nodeOffset":0,"nodeLimit":100,"sourceOffset":0,"sourceLimit":50}' \
  --pretty > snapshot.json
```

Build one request containing the snapshot's opaque `configurationRevision` and
its compact safe `document`. This example renames one proxy group while
leaving its write-only member list and selector policy unchanged:

```sh
GROUP_ID='replace-with-proxy-group-uuid'
jq --arg id "$GROUP_ID" '
  .result as $snapshot
  | {
      expectedRevision: $snapshot.configurationRevision,
      document: (
        $snapshot.document
        | .proxyGroups |= map(
            if .id == $id then .name = "Primary route" else . end
          )
      )
    }
' snapshot.json > proposed.json

mclashctl configuration.plan \
  --params-file proposed.json \
  --pretty > plan.json
```

A plan never saves data and never returns a document. Check `result.valid` and
its diagnostics, then pass the exact same `proposed.json` to apply; do not
reconstruct a request from the plan:

```sh
APPLY_REQUEST_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
mclashctl configuration.apply \
  --params-file proposed.json \
  --request-id "$APPLY_REQUEST_ID" \
  --allow-interaction \
  --pretty
```

Plan and apply are separate executions, so they use different request IDs, but
apply must reuse the original `document` and `expectedRevision`. If a CAS
`configuration_revision_conflict` occurs, fetch a new snapshot, rebuild and
plan the request, then apply with a new request ID. Likewise, after correcting
`configuration_invalid`, `configuration_dependencies`, or any error carrying
`retryWithNewRequestID`, use a new ID. Only an indeterminate transport or RPC
timeout carrying `retryWithSameRequestID` permits replaying the identical apply
with its original ID.

Apply returns a compact receipt rather than another Configuration snapshot:

```json
{
  "configurationRevision": "new-opaque-uuid",
  "changed": true,
  "valid": true,
  "diagnostics": [],
  "diagnosticCount": 0,
  "compilations": [],
  "currentSessionChanged": false
}
```

`configuration.apply` atomically saves the desired manifest but does not change
the currently running proxy session. A later app launch or restart may load the
saved manifest. Use `configuration.workspace.activate` to select and compile a
workspace immediately. It reconnects the core only when a proxy session was
already running; it does not start a stopped core.

### Export and replace selectors

Snapshots return `selectorCount` but omit selector bodies. Export one group's
complete typed selector JSON before changing that policy. Every chunk must use
the same snapshot revision. Decode and concatenate bytes by `offset`; a chunk
may split a UTF-8 sequence or JSON token, so parse only after the byte count and
full-payload SHA-256 match.

```sh
REV="$(jq -r '.result.configurationRevision' snapshot.json)"
GROUP_ID='replace-with-proxy-group-uuid'
OFFSET=0
EXPECTED_SHA=''
TOTAL_BYTES=''
: > selectors.json

while :; do
  jq -n \
    --arg groupID "$GROUP_ID" \
    --arg expectedRevision "$REV" \
    --argjson offset "$OFFSET" \
    '{groupID:$groupID,expectedRevision:$expectedRevision,offset:$offset,limitBytes:262144}' \
    | mclashctl configuration.proxyGroup.selectors.export --params-stdin \
    > selector-chunk.json

  CHUNK_SHA="$(jq -r '.result.sha256' selector-chunk.json)"
  CHUNK_TOTAL="$(jq -r '.result.totalBytes' selector-chunk.json)"
  if [ -z "$EXPECTED_SHA" ]; then
    EXPECTED_SHA="$CHUNK_SHA"
    TOTAL_BYTES="$CHUNK_TOTAL"
  fi
  [ "$CHUNK_SHA" = "$EXPECTED_SHA" ] && [ "$CHUNK_TOTAL" = "$TOTAL_BYTES" ] || exit 1
  jq -r '.result.dataBase64' selector-chunk.json | base64 -D >> selectors.json

  NEXT_OFFSET="$(jq -r '.result.nextOffset // empty' selector-chunk.json)"
  [ -n "$NEXT_OFFSET" ] || break
  OFFSET="$NEXT_OFFSET"
done

[ "$(wc -c < selectors.json | tr -d ' ')" = "$TOTAL_BYTES" ] || exit 1
[ "$(shasum -a 256 selectors.json | awk '{print $1}')" = "$EXPECTED_SHA" ] || exit 1
jq empty selectors.json
```

To preserve selectors, omit `memberSelectors`. To replace them, put the complete
decoded array in that group's `memberSelectors`; use `[]` only to clear the
policy. Exported legacy data may exceed current write limits and remain readable,
but it must be omitted to preserve it or replaced with a bounded array.

### Delete and activate

Fetch a fresh snapshot before either operation and use its
`configurationRevision`. Delete supports only the listed object kinds and never
cascades through dependencies:

```sh
mclashctl configuration.delete \
  --params '{
    "kind":"rule",
    "id":"replace-with-rule-uuid",
    "expectedRevision":"replace-with-configuration-revision"
  }' \
  --request-id "$(uuidgen | tr '[:upper:]' '[:lower:]')" \
  --allow-interaction \
  --pretty

mclashctl configuration.workspace.activate \
  --params '{
    "id":"replace-with-workspace-uuid",
    "expectedRevision":"replace-with-configuration-revision"
  }' \
  --request-id "$(uuidgen | tr '[:upper:]' '[:lower:]')" \
  --allow-interaction \
  --pretty
```

Apply and delete receipts contain `configurationRevision`, `changed`, `valid`,
`diagnostics`, `diagnosticCount`, `compilations`, and `currentSessionChanged`
(`false`). A delete receipt additionally contains `deletedKind` and `deletedID`. An activation
receipt contains `configurationRevision`, `workspaceID`, `activated` (`true`),
`currentSessionChanged`, and `runtimeSnapshot`. Mutations never return the full
document; call `configuration.snapshot` separately with the required read scope.

### Configuration document contract

All Configuration object IDs and `expectedRevision` values are UUID strings.
Always reuse the snapshot document so every required top-level collection is
present. An update may add objects, but omitting an existing object is rejected;
use `configuration.delete`. Fields ending in `Update` are write-only whole-value
replacements. They are omitted from snapshots and preserve an existing value
when omitted; for a new object, an omitted collection becomes empty. Count and
workspace `revision` fields are informational and do not perform writes. A
workspace revision is not the opaque Configuration `expectedRevision`.
`proxyGroups.memberSelectors` is also a write-only whole replacement. Snapshots
omit its body and return only `selectorCount`; use
`configuration.proxyGroup.selectors.export` to read it. Omitting the field
preserves an existing group's selectors, and an empty array clears them.

| `document` field | Exact item fields |
| --- | --- |
| `schemaVersion` | v1 requires integer `1` |
| `nodeSettings[]` | `id`, `enabled?`, `userAliasUpdate?`, `removeUserAlias?`, `tagsUpdate?`, `regionUpdate?`, `removeRegion?` |
| `proxyGroups[]` | `id`, `name`, `type`, `enabled`, `membersUpdate?`, `memberCount?`, `memberSelectors?`, `selectorCount?` |
| `rules[]` | `id`, `enabled`, `priority`, `matchersUpdate?`, `matcherCount?`, `action`, `unavailableFallback`, `workspaceScope?` |
| `ruleSets[]` | `id`, `name`, `rulesUpdate?`, `ruleCount?`, `defaultAction`, `sourceURLUpdate?`, `removeSourceURL?` |
| `dnsPolicies[]` | `id`, `name`, `mode`, `nameserversUpdate?`, `nameserverCount?`, `fallbackNameserversUpdate?`, `fallbackNameserverCount?`, `proxyServerUpdate?`, `removeProxyServer?`, `rulesUpdate?`, `ruleCount?`, `takeoverEnabled` |
| `entrances[]` | `id`, `kind`, `enabled`, `bindAddress`, `port?`, `defaultAction`, `workspaceOverride?` |
| `workspaces[]` | `id`, `name`, `nodeScope?`, `nodeIDsUpdate?`, `nodeCount?`, `effectiveNodeCount?`, `proxyGroupIDsUpdate?`, `proxyGroupCount?`, `ruleIDsUpdate?`, `ruleCount?`, `ruleSetIDsUpdate?`, `ruleSetCount?`, `dnsPolicyID`, `entranceIDsUpdate?`, `entranceCount?`, `revision?` |

`?` marks an optional field; its key may be absent when the value is nil.

`nodeSettings` is a sparse patch over profile-supplied nodes; it cannot create
or delete nodes. It is empty in a snapshot; read current values from the paged
`nodes` summaries and add only the node IDs to change. Within one item, omitted
fields preserve their values. Empty `tagsUpdate` clears the tags.
If a node summary's `tags.count` differs from `tagCount`, legacy tags exceed
the supported projection and must not be copied back. Clear them with an empty
`tagsUpdate` before setting a new bounded list.
`userAliasUpdate` cannot be combined with `removeUserAlias: true`, and
`regionUpdate` cannot be combined with `removeRegion: true`.

Every other document array is the complete object catalog. Ordinary optional
model fields such as `workspaceScope` and `port` are part of that full object;
preserve the snapshot value unless clearing it is intentional.
Group `memberCount` counts only explicit `members`; `selectorCount` counts
dynamic policies. Effective runtime membership is their de-duplicated union,
including each selector's fixed pins and current matches.
`workspaceOverride` must remain nil in v1. `remove...` fields are sparse
removal flags. Each write-only array is a whole replacement, not an
append/remove delta. `sourceURLUpdate` and
`removeSourceURL`, or `proxyServerUpdate` and `removeProxyServer`, are mutually
exclusive. A rule-set source URL must be HTTP or HTTPS and have a host.
Workspace `nodeScope` is `allEnabled` when the stored ID list is empty and
`listed` otherwise. `allEnabled` accepts only an omitted or empty
`nodeIDsUpdate`; `listed` requires at least one ID. Switching from `allEnabled`
to `listed` therefore requires an explicit non-empty `nodeIDsUpdate`. New
workspaces must state the scope. `nodeCount` reports stored IDs, while
`effectiveNodeCount` reports currently runtime-eligible nodes.

Nested tagged objects have these exact shapes:

- Group member example: `{"kind":"node","id":"uuid"}`.
- A member selector is
  `{"id":"uuid","name":"US nodes","include":[{"kind":"tagContains","value":"US"}],"exclude":[],"fixedNodeIDs":[]}`.
  Conditions are ANDed within one selector; multiple selectors on a group are
  ORed. Any matching `exclude` removes an automatic match; explicit
  `fixedNodeIDs` remain pinned. Condition kinds are `nameContains`, `nameEquals`, `hostContains`,
  `hostEquals`, `ipEquals`, `source`, `protocolIs`, and `tagContains`. `source`
  uses a source UUID value and `protocolIs` uses a node protocol enum value.
- Matcher examples: `{"kind":"domainSuffix","value":"example.com"}` and
  `{"kind":"portRange","lowerBound":443,"upperBound":8443}`. `port` and
  `userID` also use a string `value`; `userID` must be a decimal UInt32. Ports
  must be in `1...65535`.
- Action examples: `{"kind":"direct"}` and
  `{"kind":"proxyGroup","proxyGroupID":"uuid"}`. `proxyGroupID` is required
  only for `proxyGroup`.

The exact enum values are:

| Field | Values |
| --- | --- |
| Proxy-group `type` | `select`, `fallback`, `urlTest`, `loadBalance`, `direct`, `reject`, `relay` |
| Member `kind` | `node`, `group` |
| Workspace `nodeScope` | `allEnabled`, `listed` |
| Selector condition `kind` | `nameContains`, `nameEquals`, `hostContains`, `hostEquals`, `ipEquals`, `source`, `protocolIs`, `tagContains` |
| Matcher `kind` | `application`, `processPath`, `userID`, `domainExact`, `domainSuffix`, `domainWildcard`, `ipCIDR`, `transport`, `port`, `portRange` |
| Action `kind` | `direct`, `reject`, `proxyGroup` |
| `unavailableFallback` | `direct`, `reject` |
| DNS `mode` | `system`, `fakeIP`, `redirHost` |
| Entrance `kind` | `http`, `socks5`, `appRouting`, `tun` |
| Delete `kind` | `proxyGroup`, `rule`, `ruleSet`, `dnsPolicy`, `entrance`, `workspace` |

The v1 resource limits are deliberately finite. Top-level documents allow at
most 2,000 node patches, 256 proxy groups, 2,048 rules, 256 rule sets, 64 DNS
policies, 32 entrances, and 64 workspaces. A group or workspace may reference
at most 4,096 members or nodes; a rule may contain 256 matchers; a rule set may
contain 8,192 inline rules; a DNS policy may contain 64 primary and 64 fallback
nameservers plus 512 policy rules; and a node patch may contain 64 tags. Proxy
group nesting is limited to 64 levels.
Workspace group, rule, rule-set, and entrance references are each capped by
their corresponding top-level catalog limit.
Each group may contain 64 selectors; each selector may contain 32 total
include/exclude conditions and 512 fixed node IDs. One document may contain
512 selectors, 2,048 selector conditions, and 4,096 fixed selector IDs.

Names and aliases are limited to 256 UTF-8 bytes; tags and regions to 128;
matcher and DNS values to 1,024; inline rule-set entries and source URLs to
2,048; and bind addresses to 255. Non-source matcher expansion is limited to
4,096 entries per rule, 16,384 per workspace, and 65,536 per plan. DNS
expansion is limited to 4,096 per workspace and 16,384 per plan. Each compiled
workspace YAML is limited to 4 MiB. At most 256 diagnostics and 256 KiB of
encoded diagnostic entries are returned while `diagnosticCount` reports the
full number.
Selector names and text values are limited to 256 UTF-8 bytes. Selector match
work is limited to 4,194,304 operations per workspace and 16,777,216 per plan.
Persistence reserves response, diagnostic, and minimum-page space for the
compact snapshot. Each compact document plus one changed group's encoded
selector array must also fit the 1 MiB request envelope after response
headroom. Unchanged oversized legacy selector arrays remain readable through
export, but any replacement must satisfy the current limits.

Enabled relay groups and enabled TUN entrances are rejected by v1, as is any
entrance `workspaceOverride`. Source-less Mihomo rules combine destination,
port, and transport categories with AND; multiple values inside one category
remain OR alternatives. Rules with application, process-path, or user-ID
matchers keep the same semantics in App Routing and are not widened into Mihomo
rules. Inline rule-set entries must be a safe domain
suffix or a two-field `DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `IP-CIDR`, or
`IP-CIDR6` entry; MClash appends the rule set's `defaultAction` when compiling.

Diagnostics are `{id,severity,code,subject,message}`, where `severity` is
`warning` or `error`. Compilation summaries are
`{workspaceID,workspaceRevision,configHash,byteCount,captureRuleCount,captureEnabled,captureDNSEnabled}`.
An activation `runtimeSnapshot` is
`{id,workspaceID,workspaceRevision,compilerVersion,mihomoConfigHash,generatedAt,entranceIDs,previousSnapshotID?,applicationSucceeded}`.

The exact snapshot result is
`{configurationRevision,document,sources,nodes,currentWorkspaceID?,lastRuntimeSnapshot?,unifiedConfigurationEnabled,diagnostics,diagnosticCount}`.
Its `sources` and `nodes` are pages shaped as
`{items,offset,limit,total,hasMore}`. Source items contain
`{id,kind,displayName,revision,lastFetchedAt?,lastSuccessfulParseAt?,diagnosticCount}`;
source `kind` is `subscription`, `localFile`, or `pastedConfig`. Node items
contain
`{id,displayName,proto,port,sourceLinks,sourceLinkCount,enabled,health,userAlias?,tags,tagCount,region?,lastSeenAt?,parameterKeys,parameterKeyCount}`.
`sourceLinks` returns at most 256 source IDs; compare it with `sourceLinkCount`
before treating the page as a complete provenance list.
`health` is `{availability,latencyMilliseconds?,checkedAt?}`, with availability
`unknown`, `available`, `unavailable`, `sourceRemoved`, or `unsupported`. Node
`proto` is `http`, `https`, `socks5`, `shadowsocks`, `vmess`, `vless`, `trojan`,
`hysteria`, `hysteria2`, `tuic`, `wireguard`, `ssh`, or `unknown`.

Every JSON request and response payload, including params read from
`--params-file` or stdin, is limited to 1,048,576 bytes; the four-byte length
prefix is not part of that limit. Pagination does not change the payload limit.
Large member, matcher, DNS, rule-set, and workspace arrays are therefore
count-only in snapshots and appear only when explicitly supplied through their
`Update` fields. Selector bodies are also omitted and use the byte-chunk export
above. Fields not listed above are outside the v1 contract and must not be sent.

Dates use ISO 8601. A snapshot offset beyond the current total returns an empty
page whose `offset` equals that total. Important Configuration error data is:

| Error `type` | Machine-readable data and recovery |
| --- | --- |
| `configuration_revision_conflict` | `currentRevision`, `retryWithNewRequestID: true`; fetch a fresh snapshot and rebuild |
| `configuration_invalid` | `diagnostics: [{severity,code,subject,message}]`, `retryWithNewRequestID: true`; correct and start a new execution |
| `configuration_dependencies` | `dependencies: [{kind,id}]`, `retryWithNewRequestID: true`; remove references and start a new execution. Dependency kinds are `workspace`, `proxyGroup`, `rule`, `ruleSet`, `entrance`, `currentWorkspace`, or `runtimeSnapshot` |
| `operation_in_progress` | `retryWithSameRequestID: true`; retry the identical request ID after the other operation finishes; this busy response is not cached |
| `response_too_large` | No retry marker. For a snapshot, first reduce its node/source page; selector bodies use their separate bounded export. If the minimum page still fails, simplify the Configuration catalog in the app. Plan and mutation response budgets are checked before durable writes; if the transport fallback still returns this for a mutation, treat its outcome as unknown, inspect a fresh snapshot, and do not blindly replay it with a new ID |

The `configuration_invalid` error's compact diagnostics omit `id`; diagnostics
in plans, receipts, and snapshots use the full
`{id,severity,code,subject,message}` shape.

Profile YAML can be supplied without granting arbitrary filesystem access:

```sh
jq -n \
  --arg fileName profile.yaml \
  --arg dataBase64 "$(base64 < profile.yaml)" \
  '{fileName:$fileName,dataBase64:$dataBase64,activate:true}' \
  | mclashctl profiles.import --params-stdin
```

File-oriented backup operations remain interactive so an external process
cannot use MClash as an arbitrary file reader or writer.

## Security and performance boundaries

- The transport is local-only; there is no TCP, HTTP, or LAN listener.
- Transport access is limited to the current UID, then authenticated with a
  paired, scoped, expiring token bound to the client's code identity.
- The bundled CLI checks `LOCAL_PEERPID` and validates the server's MClash code
  signature/team before sending a token or command.
- Destructive commands require a fresh local approval for standard clients;
  explicitly trusted clients may invoke them unattended until expiry or revocation.
- Controller secrets, Network Extension credentials, full subscription URLs,
  and raw internal service methods are never returned.
- The API cannot invoke a shell command, evaluate code, or proxy arbitrary
  Mihomo endpoints.
- Queries use already-cached state. They do not acquire a permanent telemetry
  lease, so closing the main window still suspends expensive UI-only streams.
- v1 has no event subscription. Callers may poll bounded snapshots at a
  sensible interval; a future event API must use demand-based leases and
  release them on disconnect.
