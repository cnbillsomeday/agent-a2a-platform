package server

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"
)

func TestArchiveAppendAndQuery(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "archive.jsonl")
	a, err := OpenArchive(path)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	msgs := []*Message{
		{ID: "m1", ConvID: "c1", From: "fa", To: "vu", Body: "hello", CreatedAt: now.Add(-2 * time.Minute)},
		{ID: "m2", ConvID: "c1", From: "vu", To: "fa", Body: "hi there", CreatedAt: now.Add(-1 * time.Minute)},
		{ID: "m3", ConvID: "c2", From: "wei", To: "ao", Body: "ping", CreatedAt: now},
	}
	for _, m := range msgs {
		if err := a.Append(m); err != nil {
			t.Fatal(err)
		}
	}
	if a.Count() != 3 {
		t.Fatalf("count = %d, want 3", a.Count())
	}

	convs := a.Conversations("", 10)
	if len(convs) != 2 {
		t.Fatalf("conversations = %d, want 2", len(convs))
	}
	if convs[0].ID != "c2" || convs[1].ID != "c1" || convs[1].Count != 2 {
		t.Fatalf("unexpected conversation order/counts: %+v", convs)
	}

	got := a.Messages("c1", 10, time.Time{})
	if len(got) != 2 || got[0].ID != "m1" {
		t.Fatalf("messages = %+v", got)
	}
	if limited := a.Messages("c1", 1, time.Time{}); len(limited) != 1 || limited[0].ID != "m2" {
		t.Fatalf("limit = %+v", limited)
	}
	if filtered := a.Messages("", 10, now.Add(-90*time.Second)); len(filtered) != 1 || filtered[0].ID != "m1" {
		t.Fatalf("before filter = %+v", filtered)
	}

	// Reopening must load the persisted lines.
	b, err := OpenArchive(path)
	if err != nil {
		t.Fatal(err)
	}
	if b.Count() != 3 {
		t.Fatalf("reloaded count = %d, want 3", b.Count())
	}
}

func TestUIConversationsRequireAuth(t *testing.T) {
	a := &Archive{}
	_ = a.Append(&Message{ID: "m1", ConvID: "c1", From: "fa", To: "vu", Body: "hello", CreatedAt: time.Now().UTC()})
	s := &Server{archive: a, uiUser: "zlin", uiPass: "secret"}

	req := httptest.NewRequest(http.MethodGet, "/api/ui/conversations", nil)
	rec := httptest.NewRecorder()
	s.handleUIConversations(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("no auth = %d, want 401", rec.Code)
	}

	req = httptest.NewRequest(http.MethodGet, "/api/ui/conversations", nil)
	req.SetBasicAuth("zlin", "wrong")
	rec = httptest.NewRecorder()
	s.handleUIConversations(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("wrong password = %d, want 401", rec.Code)
	}

	req = httptest.NewRequest(http.MethodGet, "/api/ui/conversations", nil)
	req.SetBasicAuth("zlin", "secret")
	rec = httptest.NewRecorder()
	s.handleUIConversations(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("valid auth = %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct == "" || ct[:16] != "application/json" {
		t.Fatalf("content type = %q", ct)
	}

	// UI disabled when credentials are missing.
	s2 := &Server{archive: a}
	req = httptest.NewRequest(http.MethodGet, "/ui", nil)
	rec = httptest.NewRecorder()
	s2.handleUI(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("disabled UI = %d, want 404", rec.Code)
	}
}
