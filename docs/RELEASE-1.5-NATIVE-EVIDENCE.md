# 1.5.x release gate

The 1.5.x release line requires an explicit native validation report. The
report is intentionally separate from `Support/Info.plist`, so preparing the
gate does not change the version of the installed production application.

Create `ReleaseEvidence/<version>.json` on the exact commit to be released
with this shape:

```json
{
  "schema_version": 1,
  "release_version": "1.5.0",
  "commit": "<40-character git commit>",
  "status": "passed",
  "backend": "native",
  "capabilities": ["nativeRuntime", "nativeRouting", "nativeDNS"],
  "validation_commands": [
    "./scripts/typecheck.sh",
    "./scripts/integration-test.sh"
  ]
}
```

The release workflow refuses a 1.5.x build when the report is missing,
points at another commit/version, or does not explicitly prove all three
native capabilities. Do not fabricate this file: generate it only after the
isolated native runtime and CLI/network checks pass.
