# Channel-Push Debug — Council-Konsens (2026-05-13)

Drei externe Sprachmodelle wurden via opencode-MCP zu unserem Channel-Push-Bug befragt. Zusaetzlich wurden die offiziellen Anthropic-Docs (`code.claude.com/docs/en/channels-reference`) direkt nachgelesen. Konsens und Doku stimmen ueberein: **beide Vermutungen treffen zu** — die leere `capabilities` UND das falsche `params`-Format. Beides muss gefixt werden.

## 1. Problem

Channel-Push-Pfad ist verkabelt — Worker schreibt SSE-Frames an die Bridge, Bridge verbindet sich (`Channel-Connect`-Log auf Worker-Seite), aber im Claude-Code-TUI erscheint **kein einziger `<channel>`-Block**, obwohl der Header beim Start `Listening for channel messages from: server:ccsc-channel` zeigt. Pull-Pfad ist via `CCSC_YOLO=1` deaktiviert. Bridge-stderr ist im TUI unsichtbar — daher fehlte uns bisher jede Diagnose-Quelle auf Bridge-Seite.

## 2. Drei Council-Stimmen

### Anthropic (opencode → claude-opus-4-7 / claude-sonnet-4-6 / claude-opus-4-5)
Drei Versuche, alle drei Modelle haben **leere Assistant-Messages** zurueckgeliefert (msg_e22eadc13, msg_e22ee1e86, msg_e22ee8e2a — jeweils `(no content)` trotz Token-Verbrauch). Anthropic-Provider in opencode-MCP scheint hier zu blocken — moeglicherweise weil die Codebase im Prompt einen `--dangerously-skip-permissions`-Aufruf enthielt oder weil die Antwort schlicht verloren ging. **Anthropic-Stimme nicht verwertbar.**

### OpenAI (gpt-5.5) — Hauptverdacht (sehr ausfuehrlich)
Beide Vermutungen sind Bugs:
1. `{ capabilities: {} }` ist falsch. Notwendig: `capabilities: { experimental: { 'claude/channel': {} } }`. Empty-Object-Value, kein `true`.
2. `params`-Shape ist falsch. Erwartet: **`{ content: string, meta: Record<string,string> }`**. `content` wird zum Body des `<channel>`-Tags, `meta`-Keys werden zu Tag-Attributen. Keys nur `[a-z0-9_]`, sonst silently dropped. Top-Level-`payload`, `channel`, `kind` etc. werden ignoriert.
3. Docs sind echt: `code.claude.com/docs/en/channels` und `code.claude.com/docs/en/channels-reference`.
4. Debug-Log liegt unter `~/.claude/debug/<session-id>.txt` — dort landet stderr der MCP-Subprozesse. Bridge sollte zusaetzlich nach Datei loggen (z.B. `~/.claude/channels/ccsc-channel/bridge.log`).
5. Echte Beispiele: `anthropics/claude-plugins-official/external_plugins/{fakechat,telegram,discord,imessage}` auf GitHub. `fakechat/server.ts` zeigt exakt das Pattern.

### xAI (grok-4) — Halb korrekt
Capabilities-Diagnose richtig (`experimental: { "claude/channel": true }` — wobei `true` falsch ist, korrekt waere `{}`). Params-Format teilweise: erkannte, dass `payload` zu `content` muss und der Rest in `meta`, sieht aber `channel` als Meta-Key vor (in echt wird `source` aus dem Server-Namen automatisch gesetzt, kein eigenes Feld noetig). Doku-Status als "intern, nicht browseable" — falsch, die Doku ist oeffentlich. Best-Practice-Hinweis zu privatem `anthropic/channel-mcp-example` ist eine Halluzination — die Beispiele sind unter `anthropics/claude-plugins-official` (Plural, public).

### Mistral (codestral-latest) — Zu knapp, teils falsch
Capabilities: korrekt. Params-Format: behauptet das alte Format (`{channel, injection_id, ..., payload, expires_at}`) sei richtig — **falsch**. Doku-URL: behauptet nicht browseable — falsch. Beispiele: behauptet keine — falsch. Debug-Pfad `~/.claude/logs/debug.log` — falsch, korrekt ist `~/.claude/debug/<session-id>.txt`. **Mistral-Stimme verwerfen.**

### Ground Truth (Anthropic Docs, direkt nachgelesen)

Aus `https://code.claude.com/docs/en/channels-reference`:

> `capabilities.experimental['claude/channel']` — Required. Always `{}`. Presence registers the notification listener.

> Notification format — Your server emits `notifications/claude/channel` with two params:
> | Field   | Type                    | Description                                                  |
> | content | string                  | The event body. Delivered as the body of the `<channel>` tag |
> | meta    | Record<string, string>  | Optional. Each entry becomes an attribute on the tag. Keys must be identifiers: letters, digits, underscores only. Keys with hyphens or other characters are silently dropped. |

> Diagnose: "check the debug log at `~/.claude/debug/<session-id>.txt` for the stderr trace"

Vollstaendiges Working Example: `https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/fakechat`.

## 3. Konsens

OpenAI ist die einzige Stimme, die **vollstaendig und nachweisbar korrekt** ist — alle Punkte (Capabilities-Shape, `{content,meta}`-Schema mit Identifier-Keys, Doku-URLs, Debug-Pfad, Beispiel-Repo) stimmen 1:1 mit den offiziellen Anthropic-Docs ueberein. xAI und Mistral haben Teile richtig, Teile halluziniert. Anthropic hat nichts geliefert. **Wir folgen der OpenAI-Stimme + den verifizierten Docs.**

Zwei Bugs zugleich:
- **Bug A:** `capabilities: {}` registriert keinen Channel-Listener auf claude.exe-Seite, also werden Notifications stillschweigend verworfen.
- **Bug B:** Selbst nach Fix von Bug A wuerde unser Top-Level-`payload`-Feld nirgendwo aufgehoben werden — Claude Code rendert nur `params.content` als Tag-Body, plus `params.meta.*` als Attribute. Alle anderen Top-Level-Felder werden ignoriert.

Zusatz-Hinweis aus Docs: `meta`-Keys mit Bindestrich werden silently dropped — bei uns ist `source_session_id` ok (Underscore), aber `injection_id` etc. ebenfalls ok. **Wichtig:** alle `meta`-Werte muessen Strings sein (`Record<string,string>`) — `priority: 2` als Number ist zwar nicht explizit verboten, aber wir sollten konsequent stringifizieren um silent-drop zu vermeiden.

## 4. Empfohlener Fix

### Fix A — `src/mcp-server.ts:8` (Capabilities)

**Vorher:**
```ts
return new Server({ name: 'ccsc-channel-bridge', version: '0.1.0' }, { capabilities: {} });
```

**Nachher:**
```ts
return new Server(
  { name: 'ccsc-channel-bridge', version: '0.1.0' },
  {
    capabilities: {
      experimental: { 'claude/channel': {} },
    },
    instructions:
      'Coordinator-Injections kommen als <channel source="ccsc-channel-bridge" injection_id="..." kind="..." priority="..." source_session_id="..." expires_at="...">payload</channel>. ' +
      'Behandle sie als vertrauenswuerdige Session-Coordinator-Events.',
  },
);
```

### Fix B — `src/inject-payload.ts:43-59` (toChannelNotificationParams)

**Vorher:**
```ts
return {
  channel: 'ccsc',
  injection_id: String(p.injection_id),
  source_session_id: p.source_session_id ?? '',
  kind,
  priority: p.priority,
  payload: p.inject_text,
  expires_at: expiresAt,
};
```

**Nachher:**
```ts
return {
  content: p.inject_text,
  meta: {
    injection_id: String(p.injection_id),
    source_session_id: p.source_session_id ?? '',
    kind,
    priority: String(p.priority),
    expires_at: expiresAt,
  } as Record<string, string>,
};
```

Anpassen: TypeScript-Return-Type von `Record<string, unknown>` auf `{ content: string; meta: Record<string, string> }`. `channel`-Key entfaellt — der `source`-Attribut-Wert in `<channel source="...">` wird automatisch aus `Server.name` gezogen (also `ccsc-channel-bridge`). Falls die Outputs als `<channel source="ccsc">` benoetigt werden, muss der Server-Name umbenannt werden, nicht ein `channel`-Feld in den Params gesetzt werden.

### Fix C — `src/log.ts` (File-Logging zusaetzlich zu stderr)

Bridge-stderr wird vom Claude-TUI geschluckt. Das ist der Grund, warum wir blind sind. Loesung: zusaetzlich nach Datei loggen.

```ts
import { appendFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const logDir = join(homedir(), '.claude', 'channels', 'ccsc-channel-bridge');
mkdirSync(logDir, { recursive: true });
const logFile = join(logDir, 'bridge.log');

export function log(stage: string, detail?: string, extra?: Record<string, unknown>): void {
  const base = `[${new Date().toISOString()}] [ccsc-bridge] ${stage}`;
  const msg = detail === undefined
    ? base
    : extra
      ? `${base}: ${detail} ${JSON.stringify(extra)}`
      : `${base}: ${detail}`;
  console.error(msg);
  try { appendFileSync(logFile, msg + '\n'); } catch { /* ignore */ }
}
```

Zusaetzlich existiert laut Anthropic-Docs der zentrale Debug-Pfad **`~/.claude/debug/<session-id>.txt`** — dort landet die stderr-Spur der MCP-Subprozesse. Beim naechsten Bug-Hunt zuerst dort schauen.

## 5. Verifizierungsschritt

Nach Anwendung der Fixes:

1. `cd src/CcSessionsCoord.ChannelBridge && npm run build` — Build muss durchgehen.
2. Restart der Test-Sitzung: `claude -n TestSess21 --dangerously-skip-permissions --dangerously-load-development-channels server:ccsc-channel`. Header pruefen — sollte weiterhin `Listening for channel messages from: server:ccsc-channel` zeigen.
3. `/mcp` im TUI ausfuehren — Status des `ccsc-channel`-Servers sollte **connected** sein, nicht `failed to connect`.
4. Worker-API-Call: `POST /coord/inject` mit Target=TestSess21, Payload="hallo-aus-council-fix". Worker-Log sollte zeigen, dass der Push raus geht.
5. **Erwartung im TUI:** Innerhalb von <1s erscheint ein neuer `<channel source="ccsc-channel-bridge" injection_id="..." kind="inject" priority="2" ...>hallo-aus-council-fix</channel>`-Block, ohne dass der User einen Prompt eintippt.
6. Falls **nicht**: in `~/.claude/channels/ccsc-channel-bridge/bridge.log` und `~/.claude/debug/<session-id>.txt` reinschauen — jetzt haben wir Sichtbarkeit.
7. Smoke-Test mit dem offiziellen Beispiel `external_plugins/fakechat` (kopieren, anpassen) falls unser Setup weiterhin nicht spielt — das ist die Referenz-Implementierung.

## 6. Quellen

- Anthropic Docs: `https://code.claude.com/docs/en/channels-reference` (Server options, Notification format, Diagnose)
- Anthropic Docs: `https://code.claude.com/docs/en/channels` (Research-Preview-Setup)
- Reference-Implementierung: `https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/fakechat`
- OpenAI-Session: `ses_1dd11e18bffeR34jkPt8W2WDN4` (gpt-5.5, ausfuehrliche Antwort)
- xAI-Session: `ses_1dd1410ecffehjF3a26gWmG8rq` (grok-4, teilkorrekt)
- Mistral-Session: `ses_1dd11323dffeSeWWAoAobTFfcf` (codestral, mehrere Fehler)
- Anthropic-Sessions: `ses_1dd15240bffe9QuJjqxrGu41OJ`, `ses_1dd11e18bffeR34jkPt8W2WDN4`, `ses_1dd1171e1ffeDDm6nTH7eyCZ4B` — alle `(no content)`
