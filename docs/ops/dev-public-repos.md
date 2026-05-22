# Dev vs public GitHub repos

| Repo | URL | Visibility | Local path |
|------|-----|------------|------------|
| **cc-sessions-coord-dev** | https://github.com/TPierschke/cc-sessions-coord-dev | private | `~/source/repos/TPierschke/cc-sessions-coord-dev` |
| **cc-sessions-coord** | https://github.com/TPierschke/cc-sessions-coord | public | Release export: `cc-sessions-coord-public-export` |

## Rules

- Day-to-day work: **dev** repo (`origin` → `cc-sessions-coord-dev`).
- **License:** `LICENSE` v1.0 (2026-05-21) — statement of intent; ship on public release only via `publish-public-clean.ps1`.
- Public tree: **one** initial commit on **cc-sessions-coord** — never flip `visibility public` on dev with full history.
- Release: `publish-public-clean.ps1` (then public visibility if not already).

## Local path

**Junction:** `cc-sessions-coord-dev` → same content as `cc-sessions-coord` (both paths valid).

Optional rename (close IDE first): `scripts/finish-local-rename-to-dev.ps1`
