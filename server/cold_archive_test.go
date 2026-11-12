package server

import (
	"compress/gzip"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writeColdFile(t *testing.T, dir string, msgs []*Message) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(filepath.Join(dir, "20261101-0000.jsonl.gz"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	zw := gzip.NewWriter(f)
	for _, m := range msgs {
		b, err := json.Marshal(m)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := zw.Write(append(b, '\n')); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestColdArchiveIndexAndMessages(t *testing.T) {
	dir := t.TempDir()
	base := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	msgs := []*Message{
		{ID: "c1", ConvID: "conv-a", From: "alice", To: "bob", Body: "old one", CreatedAt: base},
		{ID: "c2", ConvID: "conv-a", From: "bob", To: "alice", Body: "old two", CreatedAt: base.Add(time.Minute)},
		{ID: "c3", ConvID: "conv-b", From: "carol", To: "dave", Body: "other", CreatedAt: base.Add(2 * time.Minute)},
	}
	writeColdFile(t, dir, msgs)

	c, err := OpenColdArchive(dir)
	if err != nil {
		t.Fatal(err)
	}
	convs := c.Conversations()
	if len(convs) != 2 {
		t.Fatalf("conversations = %d, want 2", len(convs))
	}
	var a UIConversation
	for _, cv := range convs {
		if cv.ID == "conv-a" {
			a = cv
		}
	}
	if a.Count != 2 || a.LastBody != "old two" {
		t.Fatalf("conv-a = %+v", a)
	}

	got := c.Messages("conv-a", time.Time{}, 0)
	if len(got) != 2 || got[0].ID != "c1" {
		t.Fatalf("messages = %+v", got)
	}
	if got := c.Messages("conv-a", base.Add(30*time.Second), 0); len(got) != 1 || got[0].ID != "c1" {
		t.Fatalf("before filter = %+v", got)
	}
	if got := c.Messages("conv-a", time.Time{}, 1); len(got) != 1 || got[0].ID != "c2" {
		t.Fatalf("limit = %+v", got)
	}
	if !c.HasBefore("conv-a", base.Add(time.Hour)) || c.HasBefore("conv-a", base) {
		t.Fatal("HasBefore is wrong")
	}
}

func TestUIMessagePageMergesHotAndCold(t *testing.T) {
	dir := t.TempDir()
	base := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	writeColdFile(t, filepath.Join(dir, "archive"), []*Message{
		{ID: "old1", ConvID: "conv-a", From: "alice", To: "bob", Body: "cold", CreatedAt: base},
	})

	hot, err := OpenArchive(filepath.Join(dir, "archive.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if err := hot.Append(&Message{ID: "new1", ConvID: "conv-a", From: "bob", To: "alice", Body: "hot", CreatedAt: base.Add(48 * time.Hour)}); err != nil {
		t.Fatal(err)
	}
	cold, err := OpenColdArchive(filepath.Join(dir, "archive"))
	if err != nil {
		t.Fatal(err)
	}
	rs, _ := openReadState(filepath.Join(dir, "ui-read.json"))
	s := &Server{archive: hot, cold: cold, readState: rs, uiUser: "admin", uiPass: "secret"}

	// Initial page: only the hot message, but it advertises more history.
	page, hasMore := s.uiMessagePage("conv-a", 500, time.Time{})
	if len(page) != 1 || page[0].ID != "new1" {
		t.Fatalf("initial page = %+v", page)
	}
	if !hasMore {
		t.Fatal("hasMore should be true: cold history exists")
	}

	// Load older: the cold message comes back.
	older, more := s.uiMessagePage("conv-a", 200, page[0].CreatedAt)
	if len(older) != 1 || older[0].ID != "old1" {
		t.Fatalf("older page = %+v", older)
	}
	if more {
		t.Fatal("hasMore should be false after the oldest page")
	}

	// A conversation that only exists on disk is still reachable.
	writeColdFile(t, filepath.Join(dir, "archive"), []*Message{
		{ID: "coldonly", ConvID: "conv-z", From: "carol", To: "dave", Body: "hi", CreatedAt: base},
	})
	cold2, _ := OpenColdArchive(filepath.Join(dir, "archive"))
	s.cold = cold2
	page, hasMore = s.uiMessagePage("conv-z", 500, time.Time{})
	if len(page) != 1 || page[0].ID != "coldonly" || hasMore {
		t.Fatalf("cold-only page = %+v hasMore=%v", page, hasMore)
	}
}
