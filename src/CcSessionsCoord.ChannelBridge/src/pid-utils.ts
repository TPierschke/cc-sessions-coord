// -----------------------------------------------------------------------------
// Walk parent process tree until claude.exe is found (Win32_Process via PowerShell).
// -----------------------------------------------------------------------------
import { spawn } from 'node:child_process';

export interface ProcessProbe {
  name: string;
  parentPid: number;
  startMs: number;
  commandLine?: string | null;
}

function runPowerShell(script: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    const child = spawn(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
      { windowsHide: true }
    );
    child.stdout.on('data', d => out.push(Buffer.from(d)));
    child.stderr.on('data', d => err.push(Buffer.from(d)));
    child.on('error', reject);
    child.on('close', code => {
      if (code !== 0) {
        reject(new Error(`pwsh exit ${code}: ${Buffer.concat(err).toString('utf8')}`));
        return;
      }
      resolve(Buffer.concat(out).toString('utf8').trim());
    });
  });
}

export async function probeProcess(pid: number): Promise<ProcessProbe | null> {
  const script = `
$ErrorActionPreference='Stop'
$p = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=${pid}" -ErrorAction SilentlyContinue
if (-not $p) { '{}' ; exit 0 }
$name=[string]$p.Name
$ppid=[int]$p.ParentProcessId
$start=[DateTimeOffset]::new(([DateTime]$p.CreationDate).ToUniversalTime()).ToUnixTimeMilliseconds()
$cmd=[string]$p.CommandLine
@{ name=$name; parentPid=$ppid; startMs=$start; commandLine=$cmd } | ConvertTo-Json -Compress
`.trim();
  try {
    const raw = await runPowerShell(script);
    if (!raw || raw === '{}') return null;
    const o = JSON.parse(raw) as { name?: string; parentPid?: number; startMs?: number; commandLine?: string };
    if (!o.name || typeof o.parentPid !== 'number' || typeof o.startMs !== 'number') return null;
    return { name: o.name, parentPid: o.parentPid, startMs: o.startMs, commandLine: o.commandLine ?? null };
  } catch {
    return null;
  }
}

const ClaudeRe = /claude\.exe/i;

export async function resolveClaudePidAndStartMs(
  startPid: number,
  maxHops = 8,
): Promise<{ pid: number; startMs: number } | null> {
  let pid = startPid;
  for (let hop = 0; hop < maxHops; hop++) {
    const p = await probeProcess(pid);
    if (!p) break;
    if (ClaudeRe.test(p.name)) return { pid, startMs: p.startMs };
    if (!p.parentPid || p.parentPid === pid) break;
    pid = p.parentPid;
  }
  return null;
}

function extractNameArg(commandLine: string | null | undefined): string | null {
  if (!commandLine) return null;
  const m = /--name\s+("([^"]+)"|'([^']+)'|([^\s]+))/i.exec(commandLine);
  if (!m) return null;
  const v = (m[2] || m[3] || m[4] || '').trim();
  return v.length > 0 ? v : null;
}

export async function resolveClaudeNameFromParent(
  startPid: number,
  maxHops = 8,
): Promise<string | null> {
  let pid = startPid;
  for (let hop = 0; hop < maxHops; hop++) {
    const p = await probeProcess(pid);
    if (!p) break;
    if (ClaudeRe.test(p.name)) return extractNameArg(p.commandLine);
    if (!p.parentPid || p.parentPid === pid) break;
    pid = p.parentPid;
  }
  return null;
}
