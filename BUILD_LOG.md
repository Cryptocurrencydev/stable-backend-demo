# Build log

Built with Claude Code on 2026-11-02. Times are WAT (UTC+1).

The raw markers below were appended with `date` during the session. Several phases overlapped: code was written while the local Docker/Supabase images were downloading over a slow connection. Some markers were therefore written at batch boundaries rather than at the exact moment a phase ended. The "Notes" column says when that happened, cross-checked against file modification times.

| # | Phase | Start | End | Duration | Notes |
|---|---|---|---|---|---|
| 0 | Toolchain: Supabase CLI, Docker (Colima), Deno | 12:54 | 13:34 | 40 min | The Homebrew API (`formulae.brew.sh`) was unreachable, so official release binaries were installed from GitHub and dl.deno.land instead. The Colima VM image download alone took about 15 min. Phases 1 to 6 were written in parallel from 13:13. |
| 1–5 | Schema migrations, `api` schema, permission engine + RLS, write functions + idempotency, offline sync | 13:13 | 13:29 | 16 min | 11 migrations. Not yet run against a database at this point. |
| 6 | Outbox + 3 edge functions + Deno unit tests | 13:29 | 13:33 | ~4 min | The 38 Deno tests passed at about 13:33. The marker reads 13:40 because it was logged later in a batch. |
| 7a | pgTAP suites (9 files) + HTTP e2e test | 13:34 | 13:42 | ~8 min | Written before the database was available. |
| 8 | GitHub Actions: CI + placeholder deploy | 13:39 | 13:41 | ~2 min | |
| 9 | API.md + README draft | 13:40 | 13:46 | ~6 min | |
| (wait) | Postgres image pull (~0.5 MB/s) | 13:46 | 14:12 | 26 min | Idle time. Test files were re-reviewed against the SQL, which caught 2 bugs before the first run. |
| 7b | First real run: migrations + seed applied cleanly. First pgTAP run: 7/9 files failing | 14:12 | 14:14 | 2.5 min | Fixed: (1) Postgres checks EXECUTE on functions in views and RLS policies as the *calling* role, so the three functions used there were granted to `authenticated` behind a "self-only" guard; (2) the product RLS read policy saw the pre-update owner; (3) the privilege test called `has_table_privilege` across schemas. Result: **251/251 pass**. |
| 7c | `supabase db lint` clean, HTTP e2e **14/14** | 14:14 | 14:15 | 1 min | |
| 10 | Full-history secret scan (gitleaks, 6 commits, no leaks), public repo created + pushed, GitHub CI green (2m23s: 251 pgTAP, 38 Deno, 14 e2e, secret scan); placeholder deploy ran and skipped | 14:15 | 14:18 | 3 min | This log update was itself merged through a pull request to show CI running on PRs. |

Wall clock from brief to green CI: 12:54 → 14:18 (1 h 24 min), including 40 min of toolchain setup and a 26 min image-download wait.

## Raw markers

```
PHASE 0 start 2026-11-02 12:54:16 WAT
PHASE 1 start 2026-11-02 13:13:51 WAT
PHASE 1-5 SQL drafted (schema, api, permissions, writes, sync) 2026-11-02 13:29:42 WAT
PHASE 6 start (outbox + edge functions) 2026-11-02 13:29:42 WAT
PHASE 0 docker ready 2026-11-02 13:34:38 WAT
PHASE 6 edge functions + deno tests (38 passing) done 2026-11-02 13:40:05 WAT
PHASE 7 pgTAP + e2e tests drafted 2026-11-02 13:40:05 WAT
PHASE 8 CI workflows drafted 2026-11-02 13:40:05 WAT
PHASE 9 docs start 2026-11-02 13:40:05 WAT
PHASE 7 local stack up, migrations+seed applied clean 2026-11-02 14:12:09 WAT
PHASE 7 pgTAP 251/251 passing after 3 fixes 2026-11-02 14:14:41 WAT
PHASE 7 db lint clean + e2e 14/14 2026-11-02 14:14:56 WAT
PHASE 10 pushed 2026-11-02 14:15:59 WAT (GitHub CI started 13:16:05Z, green 13:18:28Z)
```
