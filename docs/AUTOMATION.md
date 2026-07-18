# MClash Automation API v1

MClash exposes user-level application operations to local AI agents and other
same-user tools. The API is intentionally a stable domain command surface, not
reflection over `AppModel` and not a passthrough to Mihomo's controller.

## Quick start

```sh
MCLASHCTL=/Applications/MClash.app/Contents/Helpers/mclashctl
"$MCLASHCTL" capabilities --pretty
"$MCLASHCTL" status --pretty
"$MCLASHCTL" core.connect
"$MCLASHCTL" profiles.list --pretty
"$MCLASHCTL" systemProxy.setEnabled --params '{"enabled":true}'
```

The first positional argument may be any method returned by
`system.capabilities`. `status` and `capabilities` are aliases for
`system.snapshot` and `system.capabilities`.

The first authenticated command opens a local pairing dialog. `mclashctl`
requests only the scope required by that command, saves the returned token in
the mclashctl-only Keychain access group, and retries the original request with
the same request ID. A later command needing a different scope asks to pair again.
MClash stores only a SHA-256 token hash. Pairings expire after 180 days and can
be inspected or revoked with `auth.clients.list` and `auth.clients.revoke`.

`mclashctl` is intentionally a user-level broker: granting it a scope allows
other processes running under the same macOS login to invoke that scope by
executing the helper. Destructive operations still require a one-time local
confirmation. Clients that need an identity boundary between agents should use
their own independently code-signed native executable and connect to the socket
directly. Pairing a shared interpreter such as Python, Node, or a shell binds
the interpreter identity, not an individual script.

CLI options:

- `--params '<json object>'` supplies method parameters.
- `--params-stdin` reads a JSON params object from standard input; use it for
  subscription URLs, inline profiles, and other secrets so they do not enter
  process arguments or shell history.
- `--params-file <path>` reads the JSON params object from a file.
- `--allow-interaction` allows a capability marked `requiresInteraction` to
  present its local panel or one-time confirmation. It never means silent approval.
- `--pretty` pretty-prints the response.
- `--no-launch` fails instead of opening MClash when it is not running.
- `--timeout <seconds>` sets the startup/request timeout (default 60 seconds).
  Interactive operations automatically receive at least 300 seconds.
- `--request-id <id>` supplies a stable request ID. Preserve it when recovering
  from a transport error or indeterminate operation timeout.
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

`system.capabilities` and `auth.pair` are the only unauthenticated methods.
Capabilities report `requiredScope`, `requiresInteraction`, risk, parameter
names, types, and whether each parameter is required. Interactive presentations
are globally rate-limited. The scopes are:

- `read.basic`: redacted application and operating state.
- `read.sensitive`: connections, process candidates, rules, logs, and detailed
  diagnostics. Logs and error text are still redacted for credentials.
- `control`: non-destructive state changes.
- `destructive`: destructive requests; each call still needs local approval.

Recent mutation request IDs are idempotent per paired client for the current
MClash process (up to 256 responses or 4 MiB per client, with a global cap of
1,024 responses or 16 MiB). Reusing the same ID and identical parameters
retrieves the result of the same execution; reusing it with different parameters
is rejected. When an error has `retryable: true` and
`data.retryWithNewRequestID: true`, correct its stated precondition and use a
new ID to request a new execution. A transport `client_error` prints the
request ID to stderr. If an error reports `outcomeIndeterminate: true` and
`retryWithSameRequestID: true`, query again with `--request-id` set to that
same ID; do not start a duplicate execution. Paged list methods accept `offset` and
`limit` and return `items`, `total`, and `hasMore`. App Routing rule replacement
also requires the `expectedRevision` returned by the list/status query.

## Operation families

The current v1 surface includes:

- `system.*`: capabilities and combined snapshots.
- `app.ui.*`, `app.quit`, `app.update.*`: UI, lifecycle, and Sparkle updates.
- `settings.*`: login, notifications, startup, and connection-reset behavior.
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
- Destructive commands require a fresh local approval dialog on every call.
- Controller secrets, Network Extension credentials, full subscription URLs,
  and raw internal service methods are never returned.
- The API cannot invoke a shell command, evaluate code, or proxy arbitrary
  Mihomo endpoints.
- Queries use already-cached state. They do not acquire a permanent telemetry
  lease, so closing the main window still suspends expensive UI-only streams.
- v1 has no event subscription. Callers may poll bounded snapshots at a
  sensible interval; a future event API must use demand-based leases and
  release them on disconnect.
