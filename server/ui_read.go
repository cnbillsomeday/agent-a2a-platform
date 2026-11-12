package server

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// readState remembers, per conversation, the newest message the owner has
// actually looked at. Anything newer counts as unread.
type readState struct {
	mu    sync.Mutex
	path  string
	marks map[string]time.Time
}

func openReadState(path string) (*readState, error) {
	r := &readState{path: path, marks: make(map[string]time.Time)}
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return r, nil
		}
		return nil, err
	}
	if err := json.Unmarshal(b, &r.marks); err != nil {
		// A corrupt file must not take the UI down; start clean.
		r.marks = make(map[string]time.Time)
	}
	return r, nil
}

func (r *readState) get(conv string) time.Time {
	if r == nil {
		return time.Time{}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.marks[conv]
}

// mark advances the read position for conv, never moving it backwards.
func (r *readState) mark(conv string, at time.Time) error {
	if r == nil || conv == "" || at.IsZero() {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if cur, ok := r.marks[conv]; ok && !at.After(cur) {
		return nil
	}
	r.marks[conv] = at.UTC()
	return r.saveLocked()
}

func (r *readState) saveLocked() error {
	if err := os.MkdirAll(filepath.Dir(r.path), 0o700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(r.marks, "", "  ")
	if err != nil {
		return err
	}
	tmp := r.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, r.path)
}
