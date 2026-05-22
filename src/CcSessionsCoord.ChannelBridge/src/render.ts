// Render an injection into notifications/claude/channel params (Anthropic contract).
// Reference: fakechat + claude-peers-mcp — only { content, meta } with meta values as strings.
import type { Injection } from './db.js';

export interface ChannelNotificationParams {
  content: string;
  meta: Record<string, string>;
}

interface ParsedInject {
  payload: string;
  dialogId: string;
}

function metaString(value: unknown): string {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value;
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (value instanceof Date) return value.toISOString();
  return String(value);
}

/** If inject_text is JSON, show only payload in channel body (delivery shape unchanged). */
export function parseInjectBody(text: string): ParsedInject {
  const trimmed = text.trim();
  if (!trimmed.startsWith('{')) {
    return { payload: text, dialogId: '' };
  }
  try {
    const parsed = JSON.parse(trimmed) as {
      payload?: unknown;
      dialog_id?: unknown;
    };
    if (typeof parsed.payload === 'string') {
      return {
        payload: parsed.payload,
        dialogId: typeof parsed.dialog_id === 'string' ? parsed.dialog_id : '',
      };
    }
  } catch {
    /* plain text */
  }
  return { payload: text, dialogId: '' };
}

export function renderInjection(inj: Injection): ChannelNotificationParams {
  const parsed = parseInjectBody(inj.inject_text);
  const src = inj.source_short_id ?? '';
  const lines: string[] = [parsed.payload];

  if (inj.expects_reply) {
    lines.push('');
    if (inj.kind === 'pingpong' || inj.kind === 'exec_dialog') {
      const dialogPart = parsed.dialogId ? `, dialog_id="${parsed.dialogId}"` : '';
      lines.push('PONG (reply expected):');
      lines.push(
        `  coord_pong(target="${src}", reply_to_injection_id=${inj.id}, payload="<your text>"${dialogPart})`,
      );
      lines.push('  — or coord_exec_response with the same fields.');
    } else {
      lines.push(
        `(Reply expected — coord_pong or coord_exec_reply, injection_id=${inj.id})`,
      );
    }
  }

  const created =
    inj.created_at instanceof Date ? inj.created_at.toISOString() : String(inj.created_at);

  const meta: Record<string, string> = {
    kind: metaString(inj.kind || 'inject'),
    injection_id: metaString(inj.id),
    source_short_id: src,
    target_short_id: inj.target_short_id,
    expects_reply: metaString(inj.expects_reply),
    created_at: created,
  };
  if (inj.reply_to_injection_id != null) {
    meta.reply_to_injection_id = metaString(inj.reply_to_injection_id);
  }
  if (parsed.dialogId) {
    meta.dialog_id = parsed.dialogId;
  }

  return {
    content: lines.join('\n'),
    meta,
  };
}

export function renderHttpInject(args: {
  content: string;
  injectionId: string;
  kind: string;
  priority: number;
  sourceSessionId: string;
}): ChannelNotificationParams {
  return {
    content: args.content,
    meta: {
      source: 'ccsc-http',
      injection_id: args.injectionId,
      kind: args.kind,
      priority: metaString(args.priority),
      source_session_id: args.sourceSessionId,
    },
  };
}
