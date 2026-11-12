package server

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"encoding/json"
)

func TestReadStatePersistsAndNoRewind(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ui-read.json")
	r, err := openReadState(path)
	if err != nil {
		t.Fatal(err)
	}
	t1 := time.Now().UTC().Add(-time.Minute)
	t2 := t1.Add(30 * time.Second)
	if err := r.mark("c1", t1); err != nil {
		t.Fatal(err)
	}
	if err := r.mark("c1", t2); err != nil {
		t.Fatal(err)
	}
	if got := r.get("c1"); !got.Equal(t2) {
		t.Fatalf("mark = %v, want %v", got, t2)
	}
	if err := r.mark("c1", t1); err != nil {
		t.Fatal(err)
	}
	if got := r.get("c1"); !got.Equal(t2) {
		t.Fatalf("mark moved backwards to %v", got)
	}

	reloaded, err := openReadState(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := reloaded.get("c1"); !got.Equal(t2) {
		t.Fatalf("reloaded mark = %v, want %v", got, t2)
	}
}

func TestArchiveUnreadAfter(t *testing.T) {
	a, err := OpenArchive(filepath.Join(t.TempDir(), "archive.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	for i, at := range []time.Time{now.Add(-3 * time.Minute), now.Add(-2 * time.Minute), now.Add(-1 * time.Minute)} {
		m := &Message{ID: "m" + string(rune('1'+i)), ConvID: "c1", From: "alice", To: "bob", Body: "x", CreatedAt: at}
		if err := a.Append(m); err != nil {
			t.Fatal(err)
		}
	}
	if got := a.UnreadAfter("c1", now.Add(-150*time.Second)); got != 2 {
		t.Fatalf("unread = %d, want 2", got)
	}
	if got := a.UnreadAfter("c1", time.Time{}); got != 3 {
		t.Fatalf("unread all = %d, want 3", got)
	}
	if m := a.MessageByID("m1"); m == nil || m.ConvID != "c1" {
		t.Fatalf("MessageByID = %+v", m)
	}
}

func TestUIReadEndpointAdvancesPosition(t *testing.T) {
	a, err := OpenArchive(filepath.Join(t.TempDir(), "archive.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	if err := a.Append(&Message{ID: "m1", ConvID: "c1", From: "alice", To: "bob", Body: "one", CreatedAt: now.Add(-time.Minute)}); err != nil {
		t.Fatal(err)
	}
	if err := a.Append(&Message{ID: "m2", ConvID: "c1", From: "bob", To: "alice", Body: "two", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	rs, err := openReadState(filepath.Join(t.TempDir(), "ui-read.json"))
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{archive: a, uiUser: "admin", uiPass: "secret", readState: rs}

	if got := a.UnreadAfter("c1", rs.get("c1")); got != 2 {
		t.Fatalf("before read unread = %d, want 2", got)
	}

	body := `{"conv":"c1","last_id":"m1"}`
	req := httptest.NewRequest(http.MethodPost, "/api/ui/read", strings.NewReader(body))
	req.SetBasicAuth("admin", "secret")
	rec := httptest.NewRecorder()
	s.handleUIRead(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("read endpoint = %d, want 200", rec.Code)
	}
	if got := a.UnreadAfter("c1", rs.get("c1")); got != 1 {
		t.Fatalf("after read unread = %d, want 1", got)
	}

	// Unauthenticated writes are rejected.
	req = httptest.NewRequest(http.MethodPost, "/api/ui/read", strings.NewReader(body))
	rec = httptest.NewRecorder()
	s.handleUIRead(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("no auth = %d, want 401", rec.Code)
	}
}

func TestUIConversationsIncludeUnread(t *testing.T) {
	a, err := OpenArchive(filepath.Join(t.TempDir(), "archive.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	if err := a.Append(&Message{ID: "m1", ConvID: "c1", From: "alice", To: "bob", Body: "x", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	rs, _ := openReadState(filepath.Join(t.TempDir(), "ui-read.json"))
	s := &Server{archive: a, uiUser: "admin", uiPass: "secret", readState: rs}

	req := httptest.NewRequest(http.MethodGet, "/api/ui/conversations", nil)
	req.SetBasicAuth("admin", "secret")
	rec := httptest.NewRecorder()
	s.handleUIConversations(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	var resp struct {
		Conversations []UIConversation `json:"conversations"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Conversations) != 1 || resp.Conversations[0].Unread != 1 {
		t.Fatalf("unexpected response: %+v", resp)
	}
}
