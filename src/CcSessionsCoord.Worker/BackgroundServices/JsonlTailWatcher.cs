// -----------------------------------------------------------------------------
// JsonlTailWatcher: Polls all active sessions every 15s, tails their JSONL,
// and applies slash-command updates back to coord.sessions.
//
// Currently supported:
//   /rename <new name>         -> UPDATE session_name + display_name
//   /coord-rename <new name>   -> same
// Generic — easy to extend with more dispatcher entries.
// -----------------------------------------------------------------------------
using System.Text.Json;
using Npgsql;

namespace CcSessionsCoord.Worker.BackgroundServices;

public sealed class JsonlTailWatcher : BackgroundService
{
    private readonly NpgsqlDataSource _ds;
    private readonly ILogger<JsonlTailWatcher> _log;
    private readonly Dictionary<string, long> _offsets = new();

    public JsonlTailWatcher(NpgsqlDataSource ds, ILogger<JsonlTailWatcher> log)
    {
        _ds = ds; _log = log;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        try { await Task.Delay(TimeSpan.FromSeconds(5), ct); } catch (OperationCanceledException) { return; }

        while (!ct.IsCancellationRequested)
        {
            try { await ScanOnceAsync(ct); }
            catch (Exception ex) { _log.LogWarning(ex, "JsonlTailWatcher iteration failed"); }
            try { await Task.Delay(TimeSpan.FromSeconds(15), ct); }
            catch (OperationCanceledException) { return; }
        }
    }

    private async Task ScanOnceAsync(CancellationToken ct)
    {
        var sessions = new List<(string Short, string Jsonl)>();
        await using (var cmd = _ds.CreateCommand(
            "SELECT short_id, jsonl_path FROM coord.sessions WHERE status='active' AND jsonl_path IS NOT NULL"))
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct))
                sessions.Add((r.GetString(0), r.GetString(1)));
        }

        foreach (var (shortId, path) in sessions)
        {
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) continue;
            try { await TailOneAsync(shortId, path, ct); }
            catch (Exception ex) { _log.LogDebug(ex, "tail failed {Short} {Path}", shortId, path); }
        }
    }

    private async Task TailOneAsync(string shortId, string path, CancellationToken ct)
    {
        var fi = new FileInfo(path);
        if (!fi.Exists) return;
        _offsets.TryGetValue(path, out var offset);
        if (offset > fi.Length) offset = 0;
        if (offset == fi.Length) return;

        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        fs.Seek(offset, SeekOrigin.Begin);
        using var sr = new StreamReader(fs);
        string? line;
        while ((line = await sr.ReadLineAsync(ct)) != null)
            await ProcessLineAsync(shortId, line, ct);
        _offsets[path] = fs.Position;
    }

    private async Task ProcessLineAsync(string shortId, string line, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(line)) return;
        if (!line.Contains("\"role\":\"user\"", StringComparison.Ordinal)) return;

        string? content = null;
        try
        {
            using var doc = JsonDocument.Parse(line);
            var root = doc.RootElement;
            if (!root.TryGetProperty("message", out var msg)) return;
            if (!msg.TryGetProperty("role", out var role) || role.GetString() != "user") return;
            if (!msg.TryGetProperty("content", out var cc)) return;
            content = cc.ValueKind switch
            {
                JsonValueKind.String => cc.GetString(),
                JsonValueKind.Array  => string.Join(" ", cc.EnumerateArray()
                                            .Where(e => e.ValueKind == JsonValueKind.Object && e.TryGetProperty("text", out _))
                                            .Select(e => e.GetProperty("text").GetString() ?? "")),
                _ => null
            };
        }
        catch (JsonException) { return; }

        if (string.IsNullOrWhiteSpace(content)) return;
        content = content.TrimStart();

        foreach (var prefix in new[] { "/coord-rename ", "/rename " })
        {
            if (content.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                var newName = content.Substring(prefix.Length).Trim();
                if (string.IsNullOrEmpty(newName)) continue;
                await using var u = _ds.CreateCommand(
                    "UPDATE coord.sessions SET session_name=$2, display_name=$2, last_seen=now() " +
                    "WHERE short_id=$1 AND (session_name IS DISTINCT FROM $2 OR display_name IS DISTINCT FROM $2)");
                u.Parameters.AddWithValue(shortId);
                u.Parameters.AddWithValue(newName);
                var rows = await u.ExecuteNonQueryAsync(ct);
                if (rows > 0) _log.LogInformation("rename {Short} -> {Name}", shortId, newName);
                return;
            }
        }
    }
}
