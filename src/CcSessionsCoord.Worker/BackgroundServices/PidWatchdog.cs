// -----------------------------------------------------------------------------
// PidWatchdog: every 60s, mark sessions whose claude.exe PID is gone as ended.
// -----------------------------------------------------------------------------
using System.Diagnostics;
using Npgsql;

namespace CcSessionsCoord.Worker.BackgroundServices;

public sealed class PidWatchdog : BackgroundService
{
    private readonly NpgsqlDataSource _ds;
    private readonly ILogger<PidWatchdog> _log;

    public PidWatchdog(NpgsqlDataSource ds, ILogger<PidWatchdog> log) { _ds = ds; _log = log; }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        try { await Task.Delay(TimeSpan.FromSeconds(10), ct); } catch (OperationCanceledException) { return; }
        while (!ct.IsCancellationRequested)
        {
            try { await SweepAsync(ct); }
            catch (Exception ex) { _log.LogWarning(ex, "PidWatchdog sweep failed"); }
            try { await Task.Delay(TimeSpan.FromSeconds(60), ct); }
            catch (OperationCanceledException) { return; }
        }
    }

    private async Task SweepAsync(CancellationToken ct)
    {
        var rows = new List<(string Short, int? Pid, long? StartMs)>();
        await using (var cmd = _ds.CreateCommand(
            "SELECT short_id, claude_pid, claude_pid_start_time FROM coord.sessions WHERE status='active'"))
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct))
            {
                rows.Add((
                    r.GetString(0),
                    r.IsDBNull(1) ? null : r.GetInt32(1),
                    r.IsDBNull(2) ? null : r.GetInt64(2)
                ));
            }
        }

        foreach (var (shortId, pid, startMs) in rows)
        {
            if (pid == null) continue;
            if (IsAlive(pid.Value, startMs))
            {
                await using var u = _ds.CreateCommand(
                    "UPDATE coord.sessions SET last_seen=now() WHERE short_id=$1");
                u.Parameters.AddWithValue(shortId);
                await u.ExecuteNonQueryAsync(ct);
                continue;
            }
            await using var e = _ds.CreateCommand(
                "UPDATE coord.sessions SET status='ended', ended_at=now() WHERE short_id=$1 AND status='active'");
            e.Parameters.AddWithValue(shortId);
            var n = await e.ExecuteNonQueryAsync(ct);
            if (n > 0) _log.LogInformation("session {Short} ended (pid {Pid} gone)", shortId, pid);
        }
    }

    private static bool IsAlive(int pid, long? expectStartMs)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            if (p.HasExited) return false;
            if (expectStartMs.HasValue)
            {
                var actualMs = new DateTimeOffset(p.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds();
                if (Math.Abs(actualMs - expectStartMs.Value) > 2000) return false;
            }
            return true;
        }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
        catch { return true; }
    }
}
