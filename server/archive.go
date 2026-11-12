package server

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Archive is an append-only JSONL log of every message that the store has
// accepted. It exists because the live store keeps only a short retention
// window (24h by default); the archive lets the web UI show older rounds.
type Archive struct {
	mu   sync.Mutex
	path string
	msgs []*Message
}

// OpenArchive loads an existing archive file (if any) and returns a handle
// ready for appends. A missing file is not an error.
func OpenArchive(path string) (*Archive, error) {
	a := &Archive{path: path}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return a, nil
		}
		return nil, err
	}
	defer func() { _ = f.Close() }()

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var m Message
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			continue // tolerate a torn line from a crash
		}
		a.msgs = append(a.msgs, &m)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	sort.SliceStable(a.msgs, func(i, j int) bool {
		return a.msgs[i].CreatedAt.Before(a.msgs[j].CreatedAt)
	})
	return a, nil
}

// Append persists one message. Best effort: the caller keeps serving even if
// the archive write fails.
func (a *Archive) Append(m *Message) error {
	if a == nil || m == nil {
		return nil
	}
	a.mu.Lock()
	defer a.mu.Unlock()

	if err := os.MkdirAll(filepath.Dir(a.path), 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(a.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()

	body, err := json.Marshal(m)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(body, '\n')); err != nil {
		return err
	}
	// Keep the in-memory index in sync so the UI sees the message immediately.
	a.msgs = append(a.msgs, m)
	return nil
}

// Count returns the number of archived messages.
func (a *Archive) Count() int {
	if a == nil {
		return 0
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	return len(a.msgs)
}

// UIConversation is one row in the UI conversation list.
type UIConversation struct {
	ID        string    `json:"id"`
	From      string    `json:"from"`
	To        string    `json:"to"`
	Count     int       `json:"count"`
	LastBody  string    `json:"last_body"`
	LastAt    time.Time `json:"last_at"`
	FirstAt   time.Time `json:"first_at"`
	LastMsgID string    `json:"last_msg_id"`
	Unread    int       `json:"unread"`
}

// Conversations groups archived messages by conversation, newest first.
func (a *Archive) Conversations(query, agent string, limit int) []UIConversation {
	if a == nil {
		return []UIConversation{}
	}
	a.mu.Lock()
	defer a.mu.Unlock()

	query = strings.ToLower(strings.TrimSpace(query))
	index := make(map[string]*UIConversation, 64)
	order := make([]string, 0, 64)
	for _, m := range a.msgs {
		if agent != "" && m.From != agent && m.To != agent {
			continue
		}
		if query != "" {
			hay := strings.ToLower(m.From + " " + m.To + " " + m.Body)
			if !strings.Contains(hay, query) {
				continue
			}
		}
		c, ok := index[m.ConvID]
		if !ok {
			c = &UIConversation{ID: m.ConvID, From: m.From, To: m.To, FirstAt: m.CreatedAt}
			index[m.ConvID] = c
			order = append(order, m.ConvID)
		}
		c.Count++
		c.LastBody = m.Body
		c.LastAt = m.CreatedAt
		c.LastMsgID = m.ID
	}

	out := make([]UIConversation, 0, len(order))
	for _, id := range order {
		out = append(out, *index[id])
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].LastAt.After(out[j].LastAt) })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out
}

// MessageByID returns an archived message by id, or nil.
func (a *Archive) MessageByID(id string) *Message {
	if a == nil || id == "" {
		return nil
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, m := range a.msgs {
		if m.ID == id {
			return m
		}
	}
	return nil
}

// HasBefore reports whether the hot window holds anything older than t.
func (a *Archive) HasBefore(conv string, t time.Time) bool {
	if a == nil || conv == "" || t.IsZero() {
		return false
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, m := range a.msgs {
		if m.ConvID == conv && m.CreatedAt.Before(t) {
			return true
		}
	}
	return false
}

// UnreadAfter counts messages in conv newer than the given read position.
func (a *Archive) UnreadAfter(conv string, after time.Time) int {
	if a == nil || conv == "" {
		return 0
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	n := 0
	for _, m := range a.msgs {
		if m.ConvID == conv && m.CreatedAt.After(after) {
			n++
		}
	}
	return n
}

// Agents returns every participant seen in the archive, sorted.
func (a *Archive) Agents() []string {
	if a == nil {
		return []string{}
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	seen := make(map[string]struct{}, 16)
	for _, m := range a.msgs {
		seen[m.From] = struct{}{}
		seen[m.To] = struct{}{}
	}
	out := make([]string, 0, len(seen))
	for name := range seen {
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}

// Messages returns archived messages for one conversation, oldest first.
// limit > 0 keeps the newest N; before (if non-zero) keeps only messages
// created strictly before that instant.
func (a *Archive) Messages(convID string, limit int, before time.Time) []*Message {
	if a == nil {
		return []*Message{}
	}
	a.mu.Lock()
	defer a.mu.Unlock()

	out := make([]*Message, 0, 64)
	for _, m := range a.msgs {
		if convID != "" && m.ConvID != convID {
			continue
		}
		if !before.IsZero() && !m.CreatedAt.Before(before) {
			continue
		}
		out = append(out, m)
	}
	if limit > 0 && len(out) > limit {
		out = out[len(out)-limit:]
	}
	return out
}
