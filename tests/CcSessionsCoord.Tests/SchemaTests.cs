// -----------------------------------------------------------------------------
// SchemaTests — exercises ccsc_register_session, ccsc_claim_batch and ccsc_reply
// against a local Postgres instance. Reads the connection string from the env var
// CCSC_TEST_DB_URL (default: postgres://postgres:<pw>@localhost:5432/cc_sessions_coord_test)
// so the tests don't trash the dev database.
//
// These tests are skipped if no connection string is configured or the DB is not
// reachable (returns "Inconclusive" via Assert.Skip — gracefully degrades in CI).
// -----------------------------------------------------------------------------
using Npgsql;

namespace CcSessionsCoord.Tests;

public sealed class SchemaTests : IAsyncLifetime
{
    private NpgsqlDataSource? _ds;

    public async Task InitializeAsync()
    {
        var url = Environment.GetEnvironmentVariable("CCSC_TEST_DB_URL");
        if (string.IsNullOrWhiteSpace(url))
        {
            Console.WriteLine("[SchemaTests] CCSC_TEST_DB_URL not set");
            return;
        }
        try
        {
            _ds = NpgsqlDataSource.Create(ConvertConnString(url));
            await using var cmd = _ds.CreateCommand("SELECT 1");
            _ = await cmd.ExecuteScalarAsync();
            await using var clean = _ds.CreateCommand(
                "TRUNCATE coord.activities, coord.hook_messages, coord.injections, coord.sessions CASCADE");
            await clean.ExecuteNonQueryAsync();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[SchemaTests] init failed: {ex.Message}");
            _ds = null;
        }
    }

    /// <summary>
    /// Convert a postgres:// URL to Npgsql connection string format.
    /// </summary>
    private static string ConvertConnString(string url)
    {
        if (!url.StartsWith("postgres://", StringComparison.OrdinalIgnoreCase) &&
            !url.StartsWith("postgresql://", StringComparison.OrdinalIgnoreCase))
            return url;
        var u = new Uri(url);
        var user = Uri.UnescapeDataString(u.UserInfo.Split(':')[0]);
        var pw   = u.UserInfo.Contains(':') ? Uri.UnescapeDataString(u.UserInfo.Split(':', 2)[1]) : "";
        var db   = u.AbsolutePath.TrimStart('/');
        return $"Host={u.Host};Port={(u.Port > 0 ? u.Port : 5432)};Database={db};Username={user};Password={pw}";
    }

    public Task DisposeAsync()
    {
        _ds?.Dispose();
        return Task.CompletedTask;
    }

    private void Skip()
    {
        if (_ds == null) throw new SkipException("Test DB not configured");
    }

    [Fact]
    public async Task RegisterSession_AssignsShortId()
    {
        Skip();
        await using var c = _ds!.CreateCommand(
            "SELECT coord.ccsc_register_session($1,$2,$3,$4,$5,$6,$7,$8,$9)");
        c.Parameters.AddWithValue("UnitTestA");
        c.Parameters.AddWithValue(1001);
        c.Parameters.AddWithValue(1000L);
        c.Parameters.AddWithValue(9001);
        c.Parameters.AddWithValue(DBNull.Value);
        c.Parameters.AddWithValue("C:/tmp");
        c.Parameters.AddWithValue(DBNull.Value);
        c.Parameters.AddWithValue("C:/tmp");
        c.Parameters.AddWithValue("localhost");
        var v = await c.ExecuteScalarAsync();
        var shortId = v?.ToString()?.Trim();
        Assert.NotNull(shortId);
        Assert.Matches("^[0-9a-f]{8}$", shortId);
    }

    [Fact]
    public async Task RegisterSession_SupersedesPriorActiveWithSameName()
    {
        Skip();
        var first = await Register("SupersedeTest");
        var second = await Register("SupersedeTest");
        Assert.NotEqual(first, second);

        await using var c = _ds!.CreateCommand(
            "SELECT status FROM coord.sessions WHERE short_id = $1::char(8)");
        c.Parameters.AddWithValue(first);
        var firstStatus = (string)(await c.ExecuteScalarAsync())!;
        Assert.Equal("ended", firstStatus);
    }

    [Fact]
    public async Task ClaimBatch_IsAtomic()
    {
        Skip();
        var a = await Register("ClaimA");
        var b = await Register("ClaimB");

        await using (var i = _ds!.CreateCommand(
            "INSERT INTO coord.injections(source_short_id, target_short_id, inject_text) VALUES ($1,$2,$3)"))
        {
            i.Parameters.AddWithValue(a);
            i.Parameters.AddWithValue(b);
            i.Parameters.AddWithValue("hello");
            await i.ExecuteNonQueryAsync();
        }

        await using var claim = _ds!.CreateCommand("SELECT id FROM coord.ccsc_claim_batch($1::char(8), 32)");
        claim.Parameters.AddWithValue(b);
        await using var r = await claim.ExecuteReaderAsync();
        var count = 0;
        while (await r.ReadAsync()) count++;
        Assert.Equal(1, count);
    }

    [Fact]
    public async Task Reply_LinksOriginal()
    {
        Skip();
        var a = await Register("ReplyA");
        var b = await Register("ReplyB");

        long origId;
        await using (var i = _ds!.CreateCommand(
            "INSERT INTO coord.injections(source_short_id, target_short_id, inject_text, expects_reply) VALUES ($1,$2,$3,$4) RETURNING id"))
        {
            i.Parameters.AddWithValue(a);
            i.Parameters.AddWithValue(b);
            i.Parameters.AddWithValue("ping");
            i.Parameters.AddWithValue(true);
            origId = (long)(await i.ExecuteScalarAsync())!;
        }

        // claim from B to mark delivered
        await using (var claim = _ds!.CreateCommand("SELECT id FROM coord.ccsc_claim_batch($1::char(8), 32)"))
        {
            claim.Parameters.AddWithValue(b);
            await using var r = await claim.ExecuteReaderAsync();
            while (await r.ReadAsync()) { }
        }

        long replyId;
        await using (var rep = _ds!.CreateCommand("SELECT coord.ccsc_reply($1::char(8), $2::bigint, $3)"))
        {
            rep.Parameters.AddWithValue(b);
            rep.Parameters.AddWithValue(origId);
            rep.Parameters.AddWithValue("pong");
            replyId = (long)(await rep.ExecuteScalarAsync())!;
        }

        await using var verify = _ds!.CreateCommand(
            "SELECT source_short_id, target_short_id, kind, reply_to_injection_id FROM coord.injections WHERE id=$1");
        verify.Parameters.AddWithValue(replyId);
        await using var vr = await verify.ExecuteReaderAsync();
        Assert.True(await vr.ReadAsync());
        Assert.Equal(b,      vr.GetString(0));
        Assert.Equal(a,      vr.GetString(1));
        Assert.Equal("reply",vr.GetString(2));
        Assert.Equal(origId, vr.GetInt64(3));
    }

    private async Task<string> Register(string name)
    {
        await using var c = _ds!.CreateCommand(
            "SELECT coord.ccsc_register_session($1,NULL,NULL,NULL,NULL,$2,NULL,$3,'localhost')");
        c.Parameters.AddWithValue(name);
        c.Parameters.AddWithValue("C:/tmp");
        c.Parameters.AddWithValue("C:/tmp");
        var v = await c.ExecuteScalarAsync();
        return v!.ToString()!.Trim();
    }
}

internal sealed class SkipException : Exception { public SkipException(string m) : base(m) { } }
