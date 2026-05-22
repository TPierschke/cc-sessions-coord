// -----------------------------------------------------------------------------
// CcSessionsCoord Worker (db-centric architecture).
// Endpoints:  GET /health, GET /dashboard, GET /api/sessions, GET /api/injections.
// Services:   JsonlTailWatcher (slash-commands), PidWatchdog (status='ended').
// -----------------------------------------------------------------------------
using System.Text.Json;
using System.Text.Json.Serialization;
using CcSessionsCoord.Worker;
using CcSessionsCoord.Worker.BackgroundServices;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);

builder.Configuration.AddEnvironmentVariables(prefix: "CC_SESSIONS_COORD_");

builder.Services.ConfigureHttpJsonOptions(o =>
{
    o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower;
    o.SerializerOptions.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
    o.SerializerOptions.PropertyNameCaseInsensitive = true;
});

builder.Services.AddSingleton<NpgsqlDataSource>(sp =>
{
    var connStr = sp.GetRequiredService<IConfiguration>().GetConnectionString("CcSessionsCoord")
                  ?? throw new InvalidOperationException("ConnectionStrings:CcSessionsCoord is not configured.");
    return NpgsqlDataSource.Create(connStr);
});

builder.Services.AddHostedService<JsonlTailWatcher>();
builder.Services.AddHostedService<PidWatchdog>();

var app = builder.Build();

app.MapGet("/health", async (NpgsqlDataSource ds, CancellationToken ct) =>
{
    try
    {
        await using var cmd = ds.CreateCommand("SELECT 1");
        var v = await cmd.ExecuteScalarAsync(ct);
        return Results.Ok(new { ok = true, db = v?.ToString() == "1" });
    }
    catch (Exception ex)
    {
        return Results.Problem(detail: ex.Message, statusCode: 503);
    }
});

app.MapGet("/api/sessions", async (NpgsqlDataSource ds, CancellationToken ct) =>
{
    var list = new List<object>();
    await using var cmd = ds.CreateCommand(@"
        SELECT short_id, session_name, COALESCE(display_name, session_name) AS display_name,
               status, claude_pid, started_at, last_seen, ended_at
          FROM coord.sessions
         ORDER BY (status = 'active') DESC, started_at DESC
         LIMIT 200");
    await using var r = await cmd.ExecuteReaderAsync(ct);
    while (await r.ReadAsync(ct))
    {
        list.Add(new
        {
            short_id      = r.GetString(0),
            session_name  = r.GetString(1),
            display_name  = r.GetString(2),
            status        = r.GetString(3),
            claude_pid    = r.IsDBNull(4) ? (int?)null : r.GetInt32(4),
            started_at    = r.GetDateTime(5),
            last_seen     = r.GetDateTime(6),
            ended_at      = r.IsDBNull(7) ? (DateTime?)null : r.GetDateTime(7),
        });
    }
    return Results.Json(list);
});

app.MapGet("/api/injections", async (NpgsqlDataSource ds, CancellationToken ct) =>
{
    var list = new List<object>();
    await using var cmd = ds.CreateCommand(@"
        SELECT id, source_short_id, target_short_id, inject_text, kind, priority,
               expects_reply, reply_to_injection_id, created_at, delivered_at
          FROM coord.injections
         ORDER BY id DESC
         LIMIT 200");
    await using var r = await cmd.ExecuteReaderAsync(ct);
    while (await r.ReadAsync(ct))
    {
        list.Add(new
        {
            id                    = r.GetInt64(0),
            source_short_id       = r.IsDBNull(1) ? null : r.GetString(1),
            target_short_id       = r.GetString(2),
            inject_text           = r.GetString(3),
            kind                  = r.GetString(4),
            priority              = r.GetInt32(5),
            expects_reply         = r.GetBoolean(6),
            reply_to_injection_id = r.IsDBNull(7) ? (long?)null : r.GetInt64(7),
            created_at            = r.GetDateTime(8),
            delivered_at          = r.IsDBNull(9) ? (DateTime?)null : r.GetDateTime(9),
        });
    }
    return Results.Json(list);
});

app.MapGet("/dashboard", () => Results.Content(Dashboard.Html, "text/html; charset=utf-8"));
app.MapGet("/", () => Results.Redirect("/dashboard"));

app.Run();

public partial class Program;
