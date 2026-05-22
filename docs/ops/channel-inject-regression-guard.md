# Channel inject — regression guard (2026-05-17)

## What broke (root causes)

| # | Cause | Symptom | Evidence |
|---|--------|---------|----------|
| 1 | Commit `4951175` replaced full bridge with **ingress-only** (`index.ts` −LISTEN/−`claim_batch`) | DB inject + NOTIFY dead; HTTP used wrong notify shape | `git show 4951175`, backup `index.backup-before-ingress-only.ts` |
| 2 | `git reset --hard` to `3316ec1` | Fixes `eeebc7b` / `808c750` dropped from branch | `git reflog` |
| 3 | Cherry-pick `9791ca8d` (`expect_session` gate) | HTTP `503` / `bridge-session-name-empty` | bridge logs 2026-05-16 |
| 4 | Stale bridge on port 45777 (wrong parent `claude.exe`) | `202 ok` but message in wrong session | `bridge-*.log` ppid vs `--name` |
| 5 | **No automated guard** on HTTP legacy path | Regression merged undetected | `bridge-mcp-e2e.mjs` only tests NOTIFY, not `/inject` |

## Known-good contract (do not remove)

1. Boot log: `db-deliver bridge start` (not `ingress-only`).
2. Postgres: `LISTEN c_i_<short_id>` + `claimBatch()` + `pushInboundInjection`.
3. HTTP `POST /inject`: send **legacy** `notifications/claude/channel` params (`channel: 'ccsc'`, `payload`, …) **before** optional `content`+`meta`.
4. Port fallback when `45777` busy (`CCSC_HTTP_ACTUAL_PORT`).
5. **No** `expect_session` gate on HTTP (breaks headless inject).

Golden manual proof: T86 2026-05-17 — `← ccsc-channel: [cursor] T86 A-test`.

## Before every bridge change

```powershell
cd src/CcSessionsCoord.ChannelBridge
npm run build
npm run verify
# optional full DB e2e:
node ../../tests/smoke/bridge-mcp-e2e.mjs
node ../../tests/smoke/bridge-http-inject.mjs
```

## Before `git reset` / large rollback

```powershell
git branch backup/pre-rollback-$(Get-Date -Format 'yyyyMMdd-HHmmss')
git stash push -m "pre-rollback-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
```

Never reset past `808c750` on `feat/db-centric-greenfield` without re-applying cherry-picks.

## Tag known-good (once)

```powershell
git tag -a channel-inject-ok-20260517 -m "LISTEN+HTTP legacy inject verified T86" 808c750
```

## Live session smoke (operator)

```powershell
# Port from newest bridge log for your claude --name Txx parent PID
$body = @{ channel='ccsc'; payload='ping'; injection_id="t-$(Get-Date -Format 'HHmmss')"; kind='inject'; priority=10; source_session_id='cursor-agent' } | ConvertTo-Json -Compress
Invoke-WebRequest -Uri 'http://127.0.0.1:45777/inject' -Method POST -Body $body -ContentType 'application/json'
```

Expect: HTTP 202 + visible `← ccsc-channel:` in session without typing first.
