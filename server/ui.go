package server

import (
	"crypto/subtle"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
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

var avatarSlugPattern = regexp.MustCompile(`^[a-z0-9_-]{1,64}$`)

// handleUIAvatar serves <slug>.png from the configured avatar directory.
func (s *Server) handleUIAvatar(w http.ResponseWriter, r *http.Request) {
	if !s.uiAuth(w, r) {
		return
	}
	slug := strings.TrimSuffix(r.PathValue("slug"), ".png")
	if s.uiAvatarDir == "" || !avatarSlugPattern.MatchString(slug) {
		http.NotFound(w, r)
		return
	}
	f, err := os.Open(filepath.Join(s.uiAvatarDir, slug+".png"))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer func() { _ = f.Close() }()
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	_, _ = io.Copy(w, f)
}

// uiAgent is one row in the contact column.
type uiAgent struct {
	Slug string `json:"slug"`
	Name string `json:"name"`
}

// handleUIAgents returns the known participants (config agents + archive).
func (s *Server) handleUIAgents(w http.ResponseWriter, r *http.Request) {
	if !s.uiAuth(w, r) {
		return
	}
	seen := make(map[string]uiAgent, 16)
	if s.cfg != nil {
		for _, a := range s.cfg.Agents {
			name := a.Name
			if name == "" {
				name = a.Slug
			}
			seen[a.Slug] = uiAgent{Slug: a.Slug, Name: name}
		}
	}
	for _, slug := range s.archive.Agents() {
		if _, ok := seen[slug]; !ok {
			seen[slug] = uiAgent{Slug: slug, Name: slug}
		}
	}
	out := make([]uiAgent, 0, len(seen))
	for _, a := range seen {
		out = append(out, a)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	writeJSON(w, http.StatusOK, map[string]any{"agents": out})
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
	list := s.archive.Conversations(
		r.URL.Query().Get("q"),
		r.URL.Query().Get("agent"),
		limit,
	)
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
  html, body { height: 100%; }
  body { margin:0; font:14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, "PingFang SC", "Microsoft YaHei", sans-serif; background:#0f1115; color:#e6e6e6; overflow:hidden; }
  header { height:52px; padding:0 18px; border-bottom:1px solid #232833; display:flex; align-items:center; gap:14px; }
  header h1 { font-size:15px; margin:0; font-weight:600; }
  header .stat { color:#8b93a7; font-size:12px; }
  header input { margin-left:auto; background:#171a21; border:1px solid #2a3040; color:#e6e6e6; padding:7px 10px; border-radius:8px; min-width:260px; }
  main { display:grid; grid-template-columns:200px 330px 1fr; height:calc(100% - 52px); }
  .col { overflow:auto; border-right:1px solid #232833; }
  .col:last-child { border-right:none; }
  .col-title { position:sticky; top:0; background:#12151c; padding:9px 12px; font-size:12px; color:#8b93a7; border-bottom:1px solid #1b1f28; z-index:2; }
  .agent { display:flex; align-items:center; gap:9px; padding:9px 12px; cursor:pointer; border-bottom:1px solid #171b23; }
  .agent:hover { background:#171b23; }
  .agent.active { background:#1d2431; }
  .avatar { position:relative; overflow:hidden; width:34px; height:34px; border-radius:50%; background:#2a3550; color:#cfd8ea; display:flex; align-items:center; justify-content:center; font-size:12px; font-weight:600; flex:0 0 34px; }
  .avatar img { position:absolute; inset:0; width:100%; height:100%; object-fit:cover; }
  .agent .name { font-weight:600; }
  .agent .slug { color:#6f7a90; font-size:11px; }
  .thread { padding:9px 12px; border-bottom:1px solid #171b23; cursor:pointer; }
  .thread:hover { background:#171b23; }
  .thread.active { background:#1d2431; }
  .thread .top { display:flex; justify-content:space-between; gap:8px; font-weight:600; }
  .thread .time { color:#8b93a7; font-weight:400; font-size:11px; white-space:nowrap; }
  .thread .preview { color:#9aa3b7; font-size:12px; margin-top:2px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .thread .count { color:#5f6b84; font-size:11px; }
  #chat { display:flex; flex-direction:column; overflow:hidden; }
  #chat .head { padding:10px 16px; border-bottom:1px solid #232833; display:flex; justify-content:space-between; color:#9aa3b7; }
  #chat .head b { color:#e6e6e6; }
  #msgs { flex:1; overflow:auto; padding:18px; display:flex; flex-direction:column; gap:10px; }
  .msg { max-width:70%; padding:8px 12px; border-radius:12px; border:1px solid #222836; }
  .msg .meta { font-size:11px; color:#7f889c; margin-bottom:3px; }
  .msg .body { white-space:pre-wrap; word-break:break-word; }
  .msg.left { align-self:flex-start; background:#171a21; border-top-left-radius:4px; }
  .msg.right { align-self:flex-end; background:#22405e; border-color:#2b4f73; border-top-right-radius:4px; }
  .empty { padding:24px; color:#6b7488; }
</style>
</head>
<body>
<header>
  <h1>A2A 对话记录</h1>
  <span class="stat" id="stat"></span>
  <input id="q" type="search" placeholder="搜索内容 / 名字">
</header>
<main>
  <div class="col" id="agents-col"><div class="col-title">对话人</div><div id="agents"></div></div>
  <div class="col" id="threads-col"><div class="col-title">对话列表</div><div id="threads"></div></div>
  <div class="col" id="chat">
    <div class="head"><span id="chat-title">选择左侧的对话人</span><span id="chat-meta"></span></div>
    <div id="msgs"><div class="empty">还没有选择会话</div></div>
  </div>
</main>
<script>
let agent = null;      // selected contact slug
let conv = null;       // selected conversation id
let agentNames = {};

function esc(s) {
  return (s || "").replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
function fmt(ts) { return ts ? new Date(ts).toLocaleString('zh-CN',{hour12:false}) : ""; }
function initials(s) { return (s || "?").slice(0,2).toUpperCase(); }
function display(slug) { return agentNames[slug] || slug; }

async function loadAgents() {
  const r = await fetch('/api/ui/agents');
  if (!r.ok) return;
  const data = await r.json();
  const box = document.getElementById('agents');
  box.innerHTML = '';
  (data.agents || []).forEach(a => {
    agentNames[a.slug] = a.name;
    const div = document.createElement('div');
    div.className = 'agent' + (agent === a.slug ? ' active' : '');
    div.innerHTML = '<div class="avatar"><span>' + esc(initials(a.name)) + '</span><img src="/ui/avatar/' + encodeURIComponent(a.slug) + '.png" alt="" onerror="this.style.display=\'none\'"></div>'
      + '<div><div class="name">' + esc(a.name) + '</div><div class="slug">' + esc(a.slug) + '</div></div>';
    div.onclick = () => { agent = a.slug; conv = null; loadAgents(); loadThreads(); clearChat(); };
    box.appendChild(div);
  });
  if (!agent && (data.agents || []).length) { agent = data.agents[0].slug; loadAgents(); loadThreads(); }
}

async function loadThreads() {
  if (!agent) return;
  const q = document.getElementById('q').value.trim();
  const r = await fetch('/api/ui/conversations?agent=' + encodeURIComponent(agent) + '&limit=300&q=' + encodeURIComponent(q));
  if (!r.ok) return;
  const data = await r.json();
  document.getElementById('stat').textContent = (data.total || 0) + ' 条归档消息';
  const box = document.getElementById('threads');
  box.innerHTML = '';
  (data.conversations || []).forEach(c => {
    const peer = c.from === agent ? c.to : c.from;
    const div = document.createElement('div');
    div.className = 'thread' + (conv === c.id ? ' active' : '');
    div.innerHTML = '<div class="top"><span>' + esc(display(peer)) + '</span><span class="time">' + fmt(c.last_at) + '</span></div>'
      + '<div class="preview">' + esc(c.last_body).slice(0,90) + '</div>'
      + '<div class="count">' + c.count + ' 条</div>';
    div.onclick = () => { conv = c.id; loadThreads(); loadMessages(); };
    box.appendChild(div);
  });
  if (!(data.conversations || []).length) box.innerHTML = '<div class="empty">没有对话</div>';
}

async function loadMessages() {
  if (!conv) return;
  const r = await fetch('/api/ui/messages?conv=' + encodeURIComponent(conv) + '&limit=500');
  if (!r.ok) return;
  const data = await r.json();
  const box = document.getElementById('msgs');
  box.innerHTML = '';
  (data.messages || []).forEach(m => {
    const mine = m.from === agent;
    const div = document.createElement('div');
    div.className = 'msg ' + (mine ? 'right' : 'left');
    div.innerHTML = '<div class="meta">' + esc(display(m.from)) + ' · ' + fmt(m.created_at) + '</div>'
      + '<div class="body">' + esc(m.body) + '</div>';
    box.appendChild(div);
  });
  box.scrollTop = box.scrollHeight;
}

function clearChat() {
  document.getElementById('msgs').innerHTML = '<div class="empty">还没有选择会话</div>';
  document.getElementById('chat-title').textContent = '选择左侧的对话人';
  document.getElementById('chat-meta').textContent = '';
}

document.getElementById('q').addEventListener('input', loadThreads);
loadAgents();
setInterval(() => { loadThreads(); if (conv) loadMessages(); }, 5000);
</script>
</body>
</html>
`
