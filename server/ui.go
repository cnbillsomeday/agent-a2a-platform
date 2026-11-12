package server

import (
	"crypto/subtle"
	"net/http"
	"strconv"
	"time"
)

// uiEnabled reports whether the read-only conversation browser is configured.
func (s *Server) uiEnabled() bool {
	return s != nil && s.archive != nil && s.uiUser != "" && s.uiPass != ""
}

// uiAuth enforces HTTP Basic auth for the UI endpoints.
func (s *Server) uiAuth(w http.ResponseWriter, r *http.Request) bool {
	if !s.uiEnabled() {
		http.NotFound(w, r)
		return false
	}
	user, pass, ok := r.BasicAuth()
	if !ok ||
		subtle.ConstantTimeCompare([]byte(user), []byte(s.uiUser)) != 1 ||
		subtle.ConstantTimeCompare([]byte(pass), []byte(s.uiPass)) != 1 {
		w.Header().Set("WWW-Authenticate", `Basic realm="a2a-history"`)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return false
	}
	return true
}

// handleUIConversations returns the conversation list for the UI.
func (s *Server) handleUIConversations(w http.ResponseWriter, r *http.Request) {
	if !s.uiAuth(w, r) {
		return
	}
	limit := parseIntDefault(r.URL.Query().Get("limit"), 200)
	if limit <= 0 || limit > 2000 {
		limit = 200
	}
	list := s.archive.Conversations(r.URL.Query().Get("q"), limit)
	writeJSON(w, http.StatusOK, map[string]any{
		"conversations": list,
		"total":         s.archive.Count(),
	})
}

// handleUIMessages returns one conversation's messages for the UI.
func (s *Server) handleUIMessages(w http.ResponseWriter, r *http.Request) {
	if !s.uiAuth(w, r) {
		return
	}
	conv := r.URL.Query().Get("conv")
	if conv == "" {
		http.Error(w, "conv is required", http.StatusBadRequest)
		return
	}
	limit := parseIntDefault(r.URL.Query().Get("limit"), 500)
	if limit <= 0 || limit > 5000 {
		limit = 500
	}
	var before time.Time
	if raw := r.URL.Query().Get("before"); raw != "" {
		if ts, err := time.Parse(time.RFC3339Nano, raw); err == nil {
			before = ts
		}
	}
	msgs := s.archive.Messages(conv, limit, before)
	writeJSON(w, http.StatusOK, map[string]any{"messages": msgs})
}

func parseIntDefault(raw string, def int) int {
	if raw == "" {
		return def
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		return def
	}
	return n
}


// handleUI serves the single-page conversation browser.
func (s *Server) handleUI(w http.ResponseWriter, r *http.Request) {
	if !s.uiAuth(w, r) {
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(uiHTML))
}

const uiHTML = `<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>A2A 对话记录</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, "PingFang SC", "Microsoft YaHei", sans-serif; background:#0f1115; color:#e6e6e6; }
  header { padding: 14px 18px; border-bottom: 1px solid #232833; display:flex; gap:12px; align-items:center; flex-wrap:wrap; }
  header h1 { font-size: 16px; margin: 0; font-weight: 600; }
  header .hint { color:#8b93a7; font-size:12px; }
  input[type=search] { background:#171a21; border:1px solid #2a3040; color:#e6e6e6; padding:7px 10px; border-radius:8px; min-width:240px; }
  main { display:flex; height: calc(100vh - 57px); }
  #list { width: 360px; border-right:1px solid #232833; overflow:auto; }
  .conv { padding:10px 14px; border-bottom:1px solid #1b1f28; cursor:pointer; }
  .conv:hover { background:#171b23; }
  .conv.active { background:#1d2431; }
  .conv .top { display:flex; justify-content:space-between; gap:8px; font-weight:600; }
  .conv .time { color:#8b93a7; font-weight:400; font-size:12px; white-space:nowrap; }
  .conv .preview { color:#9aa3b7; font-size:12px; margin-top:3px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .conv .count { color:#5f6b84; font-size:11px; margin-top:2px; }
  #pane { flex:1; display:flex; flex-direction:column; overflow:hidden; }
  #pane .head { padding:10px 16px; border-bottom:1px solid #232833; color:#9aa3b7; display:flex; justify-content:space-between; }
  #pane .head b { color:#e6e6e6; }
  #msgs { flex:1; overflow:auto; padding:16px; display:flex; flex-direction:column; gap:10px; }
  .msg { max-width: 760px; padding:9px 12px; border-radius:10px; background:#171a21; border:1px solid #222836; }
  .msg .meta { font-size:11px; color:#7f889c; margin-bottom:4px; display:flex; gap:8px; }
  .msg .body { white-space:pre-wrap; word-break:break-word; }
  .msg.from-other { background:#141a22; }
  .empty { padding:24px; color:#6b7488; }
</style>
</head>
<body>
<header>
  <h1>A2A 对话记录</h1>
  <input id="q" type="search" placeholder="搜索：名字 / 内容">
  <span class="hint" id="stat"></span>
</header>
<main>
  <div id="list"></div>
  <div id="pane">
    <div class="head"><span id="pane-title">选择左侧一个会话</span><span id="pane-meta"></span></div>
    <div id="msgs"><div class="empty">还没有选择会话</div></div>
  </div>
</main>
<script>
let current = null;
let timer = null;

function esc(s) {
  return (s || "").replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
function fmt(ts) {
  if (!ts) return "";
  const d = new Date(ts);
  return d.toLocaleString('zh-CN', {hour12:false});
}

async function loadList() {
  const q = document.getElementById('q').value.trim();
  const r = await fetch('/api/ui/conversations?limit=300&q=' + encodeURIComponent(q));
  if (!r.ok) { document.getElementById('stat').textContent = '加载失败 ' + r.status; return; }
  const data = await r.json();
  document.getElementById('stat').textContent = (data.total || 0) + ' 条归档消息';
  const list = document.getElementById('list');
  list.innerHTML = '';
  (data.conversations || []).forEach(c => {
    const div = document.createElement('div');
    div.className = 'conv' + (current === c.id ? ' active' : '');
    div.innerHTML = '<div class="top"><span>' + esc(c.from) + ' ⇄ ' + esc(c.to) + '</span><span class="time">' + fmt(c.last_at) + '</span></div>'
      + '<div class="preview">' + esc(c.last_body).slice(0, 80) + '</div>'
      + '<div class="count">' + c.count + ' 条</div>';
    div.onclick = () => selectConv(c);
    list.appendChild(div);
  });
  if (!(data.conversations || []).length) list.innerHTML = '<div class="empty">没有记录</div>';
}

async function selectConv(c) {
  current = c.id;
  document.querySelectorAll('.conv').forEach(el => el.classList.remove('active'));
  document.getElementById('pane-title').innerHTML = '<b>' + esc(c.from) + ' ⇄ ' + esc(c.to) + '</b>';
  document.getElementById('pane-meta').textContent = fmt(c.first_at) + ' 起';
  const r = await fetch('/api/ui/messages?conv=' + encodeURIComponent(c.id) + '&limit=500');
  if (!r.ok) { document.getElementById('msgs').textContent = '加载失败 ' + r.status; return; }
  const data = await r.json();
  const box = document.getElementById('msgs');
  box.innerHTML = '';
  (data.messages || []).forEach(m => {
    const div = document.createElement('div');
    div.className = 'msg';
    div.innerHTML = '<div class="meta"><b>' + esc(m.from) + '</b><span>' + fmt(m.created_at) + '</span></div>'
      + '<div class="body">' + esc(m.body) + '</div>';
    box.appendChild(div);
  });
  box.scrollTop = box.scrollHeight;
}

document.getElementById('q').addEventListener('input', () => { loadList(); });
loadList();
timer = setInterval(() => { loadList(); if (current) { /* keep list fresh */ } }, 5000);
</script>
</body>
</html>
`
