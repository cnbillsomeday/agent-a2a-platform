package server

import (
	"bufio"
	"compress/gzip"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// coldArchive reads rotated archives (*.jsonl.gz) straight from disk. Only a
// tiny per-conversation index (counts + first/last timestamps) stays in memory,
// so years of history cost a few kilobytes of RAM.
type coldArchive struct {
	dir string

	mu       sync.Mutex
	index    map[string]UIConversation
	loaded   bool
	loadedAt time.Time
}

// OpenColdArchive prepares a reader for dir. A missing directory is fine: the
// UI then behaves as if there were no rotated history.
func OpenColdArchive(dir string) (*coldArchive, error) {
	c := &coldArchive{dir: dir, index: make(map[string]UIConversation)}
	if err := c.refreshLocked(); err != nil {
		return c, err
	}
	return c, nil
}

// Refresh rescans the directory when it is older than maxAge.
func (c *coldArchive) Refresh(maxAge time.Duration) {
	if c == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.loaded && time.Since(c.loadedAt) < maxAge {
		return
	}
	_ = c.refreshLocked()
}

func (c *coldArchive) files() []string {
	entries, err := os.ReadDir(c.dir)
	if err != nil {
		return nil
	}
	out := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".jsonl.gz") {
			continue
		}
		out = append(out, filepath.Join(c.dir, e.Name()))
	}
	sort.Strings(out)
	return out
}

func (c *coldArchive) refreshLocked() error {
	index := make(map[string]UIConversation)
	for _, path := range c.files() {
		err := scanGzipLines(path, func(m *Message) {
			cv, ok := index[m.ConvID]
			if !ok {
				cv = UIConversation{
					ID:      m.ConvID,
					From:    m.From,
					To:      m.To,
					FirstAt: m.CreatedAt,
				}
			}
			cv.Count++
			if m.CreatedAt.Before(cv.FirstAt) {
				cv.FirstAt = m.CreatedAt
			}
			if m.CreatedAt.After(cv.LastAt) {
				cv.LastAt = m.CreatedAt
				cv.LastBody = m.Body
				cv.LastMsgID = m.ID
			}
			index[m.ConvID] = cv
		})
		if err != nil {
			return err
		}
	}
	c.index = index
	c.loaded = true
	c.loadedAt = time.Now()
	return nil
}

// Conversations returns the cold index, newest first.
func (c *coldArchive) Conversations() []UIConversation {
	if c == nil {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]UIConversation, 0, len(c.index))
	for _, cv := range c.index {
		out = append(out, cv)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].LastAt.After(out[j].LastAt) })
	return out
}

// HasBefore reports whether the archive holds anything older than t.
func (c *coldArchive) HasBefore(conv string, t time.Time) bool {
	if c == nil || conv == "" || t.IsZero() {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	cv, ok := c.index[conv]
	return ok && cv.FirstAt.Before(t)
}

// Messages returns the newest limit messages of conv created before t.
// limit <= 0 means "all matching". The scan is streamed from disk and only the
// matching page is kept in memory.
func (c *coldArchive) Messages(conv string, before time.Time, limit int) []*Message {
	if c == nil || conv == "" {
		return nil
	}
	var out []*Message
	for _, path := range c.files() {
		err := scanGzipLines(path, func(m *Message) {
			if m.ConvID != conv {
				return
			}
			if !before.IsZero() && !m.CreatedAt.Before(before) {
				return
			}
			out = append(out, m)
		})
		if err != nil {
			continue
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	if limit > 0 && len(out) > limit {
		out = out[len(out)-limit:]
	}
	return out
}

func scanGzipLines(path string, each func(*Message)) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	zr, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	defer func() { _ = zr.Close() }()

	sc := bufio.NewScanner(zr)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var m Message
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			continue
		}
		each(&m)
	}
	return sc.Err()
}
