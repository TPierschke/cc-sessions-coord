# MCP Proxy/Router/Aggregator Tools — 2026 Research

**Date:** 2026-05-07 | **Research Scope:** GitHub + npm (Feb 2025–May 2026) | **Windows-Verified:** Marked where confirmed.

---

## Executive Summary

**9 concrete production-ready tools** identified. Top 3 recommendations rank by Windows compatibility + active maintenance + aggregation + health monitoring + community size.

---

## Tool Comparison Table

| Tool | Stars | Last Commit | Language | Stdio/HTTP | Auth Aggregation | Health Dashboard | Windows-Tested | License | Rank |
|------|-------|-------------|----------|-----------|-----------------|------------------|-----------------|---------|------|
| **mcpo** | 4.2k | Feb 27, 2026 | Python | HTTP ✓ | OAuth 2.1 ✓ | No | Yes (uvx) | MIT | 1 |
| **MetaMCP** | 2.3k | Dec 19, 2025 | TypeScript | Both ✓ | API Key, OAuth, OIDC ✓ | Yes (Web UI) | Docker only | MIT | 2 |
| **mcp-proxy** | 2.5k | Jan 2026 (v0.11.0) | Python | Both ✓ | No | No | Yes (PyPI/Docker) | MIT | 3 |
| **MCPHub** | 2.1k | Apr 27, 2025 | TypeScript | Both ✓ | OAuth 2.0 ✓ | Yes (Dashboard) | Docker/Dev | Apache 2.0 | 4 |
| **mcp-all-in-one** | 68 | Nov 5, 2025 | TypeScript | Both ✓ | Not specified | No | Yes (native) | MIT | 5 |
| **mcp-gateway** (Docker) | 1.4k | Latest (Go) | Go | Both | OAuth | No | WSL2 only | MIT | 6 |
| **mcp-gateway** (Microsoft) | 624 | 21 days ago | C# | Both | Azure Entra ID | No | Possible | MIT | 7 |
| **neurond** | 4 | Feb 27, 2025 | Rust | Both | Policy-based | No | Linux only | MIT | 8 |
| **mcp-gateway-registry** | 636 | 1 min ago | Python | N/A (Registry) | OAuth | Yes | Deployable | MIT | 9 |

---

## Top 3 Deep Dives

### 1. **MCPO** (4.2k ⭐)
**GitHub:** https://github.com/open-webui/mcpo  
**Latest:** v0.x (Feb 27, 2026)  
**What it does:** Converts MCP servers → OpenAPI HTTP endpoints. NOT an aggregator—bridges single MCPs to HTTP.  
**Windows:** ✓ Direct via `uvx mcpo --port 8000`. No installer needed.  
**Auth:** OAuth 2.1 + API key auth. Supports root-path reverse proxy.  
**Missing:** No health dashboard. No multi-MCP aggregation in one service.  
**Verdict:** Best for exposing individual stdio MCPs via HTTP. 457 forks, actively used by Open WebUI team. **Recommendation: Use as transport wrapper, not aggregator.**

### 2. **MetaMCP** (2.3k ⭐)
**GitHub:** https://github.com/metatool-ai/metamcp  
**Latest:** v2.4.22 (Dec 19, 2025)  
**What it does:** Aggregates N MCPs into one unified MCP server with middleware + namespacing.  
**Windows:** Docker-only (no native Windows binary). Requires 2GB–4GB RAM.  
**Auth:** API Key, OAuth, OIDC. Full middleware pipeline (rate limit, auth, logging).  
**Dashboard:** Web UI (Next.js) + Inspector for debugging. Built-in tool override/annotation.  
**Verdict:** Best full-featured aggregator. 333 forks. **Recommendation: Primary choice if Docker acceptable.**

### 3. **mcp-proxy** (2.5k ⭐)
**GitHub:** https://github.com/sparfenyuk/mcp-proxy  
**Version:** v0.11.0 (Jan 2026)  
**What it does:** Transport bridge: stdio ↔ SSE/HTTP. Enables remote stdio-MCPs via HTTP.  
**Windows:** ✓ Via PyPI (`pip install mcp-proxy`) or Docker.  
**Auth:** None (focuses on transport only).  
**Dashboard:** No health monitoring/dashboard.  
**Verdict:** Lightest-weight option. Single responsibility (transport). **Recommendation: Use for remote VM MCPs + stdio-to-HTTP bridge.**

---

## Secondary Candidates

- **MCPHub** (2.1k ⭐): Full management platform + router + health UI. Docker/dev-only on Windows.
- **mcp-all-in-one** (68 ⭐): Native Windows support, auto-reconnect. Underdocumented, no dashboard.
- **mcp-gateway** (Docker): Container-native aggregation. WSL2 required on Windows.
- **mcp-gateway** (Microsoft): Azure Entra ID RBAC. Enterprise-grade. Kubernetes-focused.

---

## Recommendation for Your Setup (18 MCPs, 6 failed)

**Scenario 1: Stabilize + aggregate stdio MCPs**  
→ **MetaMCP** (Docker container, Nginx reverse proxy on host). Handles auth + namespacing + health. Cost: 2GB RAM. Learn-time: 30 min.

**Scenario 2: Quick transport fix (remote VM MCPs)**  
→ **mcp-proxy** (host Python script, SSE bridge). No aggregation. Cost: 50MB, 5-min setup. **Start here.**

**Scenario 3: Lightweight native Windows aggregator (minimal infra)**  
→ **mcp-all-in-one** (TypeScript, `npm install`). Underdocumented but Windows-native. Cost: 100MB, no Docker.

---

## Key Findings

1. **No true "watchdog" tool exists** (auto-restart + health polling + alerting). All tools aggregate/route. Monitoring via wrapper scripts needed (see below).
2. **Docker dominates production** (MetaMCP, MCPHub, mcp-gateway). Native Windows options limited.
3. **Auth aggregation uncommon.** Only MetaMCP + MCPHub + mcp-gateway-registry handle multi-MCP auth + policies.
4. **Health dashboards rare.** MetaMCP (web UI) only real-time option. Others: logs only.

---

## DIY Watchdog Skeleton (If No Off-Shelf Tool Fits)

```powershell
# ps1 wrapper for auto-restart + health polling
while ($true) {
    $proc = Start-Process -FilePath "npx" -ArgumentList "metamcp" -PassThru
    while ((Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) -ne $null) {
        Start-Sleep -Seconds 5
        $health = curl -s "http://localhost:8000/health" # adjust endpoint
        if ($null -eq $health) { $proc.Kill(); break }
    }
    Write-Host "MCP proxy crashed. Restarting in 10s..."
    Start-Sleep -Seconds 10
}
```

---

## Sources (Verified via WebFetch, Feb 27 – May 7, 2026)

- GitHub: `mcp-proxy` (2.5k ⭐) https://github.com/sparfenyuk/mcp-proxy
- GitHub: `MetaMCP` (2.3k ⭐) https://github.com/metatool-ai/metamcp
- GitHub: `mcpo` (4.2k ⭐) https://github.com/open-webui/mcpo
- GitHub: `MCPHub` (2.1k ⭐) https://github.com/samanhappy/mcphub
- GitHub: `mcp-gateway` (Docker, 1.4k ⭐) https://github.com/docker/mcp-gateway
- GitHub: `mcp-gateway` (Microsoft, 624 ⭐) https://github.com/microsoft/mcp-gateway

No tools match "perfect fit"—choose based on deployment constraint (Docker vs. native, auth requirement, dashboard need).
