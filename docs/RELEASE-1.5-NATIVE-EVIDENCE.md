# 1.5.x release gate

The 1.5.x release line requires an explicit native validation report. The
report is intentionally separate from `Support/Info.plist`, so preparing the
gate does not change the version of the installed production application.

Run the native validation on the commit that will be released and create
`ReleaseEvidence/<version>.json` with this shape:

```json
{
  "schema_version": 1,
  "release_version": "1.5.0",
  "commit": "<40-character git commit tested>",
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
native capabilities. Because adding a tracked report changes the Git SHA, the
normal release flow is: test commit `X`, add only the evidence file, and tag
the resulting evidence-only commit. The gate accepts `X` as the parent only
when that release commit contains no other changed path. It also accepts an
exact HEAD match for externally supplied/untracked evidence. Do not fabricate
this file: generate it only after the isolated native runtime and CLI/network
checks pass.
