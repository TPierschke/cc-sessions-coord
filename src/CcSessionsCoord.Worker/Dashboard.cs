// -----------------------------------------------------------------------------
// Static HTML dashboard. JS polls /api/sessions and /api/injections every 3s.
// -----------------------------------------------------------------------------
namespace CcSessionsCoord.Worker;

public static class Dashboard
{
    public const string Html = """
<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8" />
  <title>cc-sessions-coord — Dashboard</title>
  <style>
    body { font-family: Consolas, monospace; margin: 1rem; background: #1c1c1c; color: #ddd; }
    h1 { color: #88f; font-size: 1.2rem; }
    h2 { color: #f88; font-size: 1rem; margin-top: 1.5rem; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 1rem; }
    th, td { padding: 4px 8px; text-align: left; border-bottom: 1px solid #333; font-size: 0.85rem; }
    th { background: #333; color: #aaf; }
    tr.active td { color: #6f6; }
    tr.ended td { color: #888; }
    tr.delivered td { color: #6f6; }
    tr.pending td { color: #fc6; }
    .reply { color: #faa; }
    .refresh { float: right; color: #888; font-size: 0.75rem; }
  </style>
</head>
<body>
  <h1>cc-sessions-coord <span class="refresh" id="lastRefresh"></span></h1>
  <h2>Sessions</h2>
  <table id="sessions"><thead><tr>
    <th>short</th><th>name</th><th>display</th><th>status</th><th>pid</th><th>started</th><th>last seen</th>
  </tr></thead><tbody></tbody></table>
  <h2>Recent Injections</h2>
  <table id="injections"><thead><tr>
    <th>id</th><th>src</th><th>tgt</th><th>kind</th><th>text</th><th>reply?</th><th>reply&rarr;</th><th>created</th><th>delivered</th>
  </tr></thead><tbody></tbody></table>
  <script>
    function fmt(d){ if(!d) return ''; try{ return new Date(d).toLocaleTimeString(); }catch{ return d; } }
    function esc(s){ return (s==null?'':s).toString().replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
    async function refresh(){
      try{
        const [s, i] = await Promise.all([
          fetch('/api/sessions').then(r=>r.json()),
          fetch('/api/injections').then(r=>r.json())
        ]);
        const stb = document.querySelector('#sessions tbody');
        stb.innerHTML = s.map(x => `<tr class="${x.status}">
          <td>${esc(x.short_id)}</td>
          <td>${esc(x.session_name)}</td>
          <td>${esc(x.display_name)}</td>
          <td>${esc(x.status)}</td>
          <td>${x.claude_pid || ''}</td>
          <td>${fmt(x.started_at)}</td>
          <td>${fmt(x.last_seen)}</td>
        </tr>`).join('');
        const itb = document.querySelector('#injections tbody');
        itb.innerHTML = i.map(x => `<tr class="${x.delivered_at?'delivered':'pending'}">
          <td>${x.id}</td>
          <td>${esc(x.source_short_id||'-')}</td>
          <td>${esc(x.target_short_id)}</td>
          <td>${esc(x.kind)}${x.kind==='reply'?' <span class="reply">&#8617;</span>':''}</td>
          <td>${esc(x.inject_text).slice(0,80)}</td>
          <td>${x.expects_reply?'<span class="reply">yes</span>':''}</td>
          <td>${x.reply_to_injection_id||''}</td>
          <td>${fmt(x.created_at)}</td>
          <td>${fmt(x.delivered_at)}</td>
        </tr>`).join('');
        document.getElementById('lastRefresh').textContent = 'refreshed ' + new Date().toLocaleTimeString();
      }catch(e){
        document.getElementById('lastRefresh').textContent = 'error: ' + e;
      }
    }
    refresh();
    setInterval(refresh, 3000);
  </script>
</body>
</html>
""";
}
