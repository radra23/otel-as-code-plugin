# nextjs-brownfield-api-helper

A Next.js 15 service that already has OpenTelemetry, with one file per role the scanner has to
tell apart (#169):

| file | role | belongs in |
|---|---|---|
| `src/telemetry.node.ts` | constructs `NodeSDK` | `bootstrapFiles` |
| `src/instrumentation.ts` | framework hook, only imports the bootstrap | `wiredInto` |
| `src/lib/log-exception.ts` | calls the Logs **API**, constructs no provider | `apiCallSites` |
| `src/app/monitoring/route.ts` | second importer of the helper | recorded as an importer |

None of the files carries the plugin's ownership marker, so `/otel-instrument` must
refuse (hand-written OTel) and never offer any of them to `--force`.
