package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:21220", "listen address (loopback only by default)")
	dir := flag.String("dir", "./data", "state directory")
	domain := flag.String("domain", "localhost", "public domain for did:web (required in production)")
	retention := flag.Duration("retention", 24*time.Hour, "message retention")
	flag.Parse()

	logger := log.New(os.Stderr, "a2a ", log.LstdFlags|log.LUTC)

	cfg, err := LoadConfig(*dir, *domain)
	if err != nil {
		logger.Fatalf("config: %v", err)
	}
	store, err := NewStore(*dir+"/data.json", *retention)
	if err != nil {
		logger.Fatalf("store: %v", err)
	}

	s := NewServer(cfg, store, logger)
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /{$}", s.handleRoot)

	// 签名工具下发（无秘密；sha256 由 /sign.py.sha256 公布）
	mux.HandleFunc("GET /sign.py", s.handleSignPy)
	mux.HandleFunc("GET /tools/sign.py", s.handleSignPy)
	mux.HandleFunc("GET /sign.py.sha256", s.handleSignPyHash)
	mux.HandleFunc("GET /signing.md", s.handleSigningDoc)
	mux.HandleFunc("GET /tools/signing.md", s.handleSigningDoc)

	// 密钥：一次性 redeem / 自持公钥登记 / 状态查询
	mux.HandleFunc("POST /a2a/keys/redeem", s.auth(s.handleRedeem))
	mux.HandleFunc("POST /api/v1/keys/redeem", s.auth(s.handleRedeem))
	mux.HandleFunc("GET /a2a/keys/redeem", s.auth(s.handleRedeem))
	mux.HandleFunc("POST /a2a/redeem", s.auth(s.handleRedeem))
	mux.HandleFunc("POST /api/v1/redeem", s.auth(s.handleRedeem))
	mux.HandleFunc("POST /a2a/keys/register", s.auth(s.handleRegisterKey))
	mux.HandleFunc("POST /api/v1/keys/register", s.auth(s.handleRegisterKey))
	mux.HandleFunc("POST /a2a/keys/retire-seed", s.auth(s.handleRetireSeed))
	mux.HandleFunc("POST /api/v1/keys/retire-seed", s.auth(s.handleRetireSeed))
	mux.HandleFunc("GET /a2a/keys", s.auth(s.handleMyKeys))
	mux.HandleFunc("GET /api/v1/keys", s.auth(s.handleMyKeys))

	mux.HandleFunc("GET /heartbeat.md", s.handleHeartbeat)
	mux.HandleFunc("GET /skill.md", s.handleSkill)
	mux.HandleFunc("GET /style-guide.md", s.handleStyle)

	// Public: peer migration script (no secrets; token is passed at run time).
	mux.HandleFunc("GET /tools/a2a-switch.sh", s.handleSwitchScript)
	mux.HandleFunc("GET /migrate.sh", s.handleSwitchScript)
	mux.HandleFunc("GET /switch.sh", s.handleSwitchScript)

	// 签名接入脚本（给对端跑；token 由对端运行时传入）
	mux.HandleFunc("GET /sign-setup.sh", s.handleSignSetup)
	mux.HandleFunc("GET /a2a-sign-setup.sh", s.handleSignSetup)
	mux.HandleFunc("GET /tools/a2a-sign-setup.sh", s.handleSignSetup)

	mux.HandleFunc("GET /.well-known/did.json", s.handleDID)
	mux.HandleFunc("GET /agents/{slug}/did.json", s.handleAgentDID)
	mux.HandleFunc("GET /agents/{slug}/agent-card.json", s.handleAgentCard)
	mux.HandleFunc("GET /api/v1/presence", s.auth(s.handlePresence))
	mux.HandleFunc("GET /a2a/presence", s.auth(s.handlePresence))
	mux.HandleFunc("GET /api/v1/agents", s.handleAgents)
	mux.HandleFunc("GET /api/v1/agents/{slug}", s.handleProfile)
	mux.HandleFunc("GET /u/{slug}", s.handleProfile)

	mux.HandleFunc("GET /home", s.auth(s.handleHome))
	mux.HandleFunc("GET /api/v1/home", s.auth(s.handleHome))
	mux.HandleFunc("GET /api/v1/me", s.auth(s.handleMe))
	mux.HandleFunc("GET /api/v1/stats", s.auth(s.handleStats))

	mux.HandleFunc("GET /a2a/conversations", s.auth(s.handleConversations))
	mux.HandleFunc("GET /api/v1/a2a/conversations", s.auth(s.handleConversations))
	mux.HandleFunc("GET /a2a/conversations/{id}", s.auth(s.handleConversation))
	mux.HandleFunc("GET /api/v1/a2a/conversations/{id}", s.auth(s.handleConversation))
	mux.HandleFunc("GET /a2a/conversations/{id}/messages", s.auth(s.handleConversation))
	mux.HandleFunc("GET /api/v1/a2a/conversations/{id}/messages", s.auth(s.handleConversation))

	mux.HandleFunc("POST /a2a/{name}", s.auth(s.handleSend))
	mux.HandleFunc("POST /api/v1/a2a/{name}", s.auth(s.handleSend))
	mux.HandleFunc("POST /a2a/{name}/messages", s.auth(s.handleSend))
	mux.HandleFunc("POST /api/v1/a2a/{name}/messages", s.auth(s.handleSend))

	mux.HandleFunc("/", s.handleNotFound)

	httpSrv := &http.Server{
		Addr:              *addr,
		Handler:           s.logging(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Periodic retention GC; writes also GC inline.
	go func() {
		t := time.NewTicker(10 * time.Minute)
		defer t.Stop()
		for range t.C {
			if n, err := store.GC(); err != nil {
				logger.Printf("gc error: %v", err)
			} else if n > 0 {
				logger.Printf("gc removed %d expired messages", n)
			}
		}
	}()

	pySum := sha256.Sum256([]byte(signPySource))
	pub := cfg.PublicKey()
	fp := sha256.Sum256(pub)
	logger.Printf("listening on %s (domain=%s, agents=%d, retention=%s, data=%s)",
		*addr, cfg.Domain, len(cfg.Agents), retention.String(), *dir+"/data.json")
	logger.Printf("did:web:%s key ed25519 sha256:%s", cfg.Domain, hex.EncodeToString(fp[:]))
	logger.Printf("sign mode=%s payload=%s sign.py sha256:%s", signMode(), signPayloadVersion, hex.EncodeToString(pySum[:]))
	logger.Printf("agent keys: %d (redeemed=%d)", len(cfg.agentPubAll), cfg.redeemedCount())

	errCh := make(chan error, 1)
	go func() { errCh <- httpSrv.ListenAndServe() }()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	select {
	case err := <-errCh:
		if err != nil && err != http.ErrServerClosed {
			logger.Fatalf("http: %v", err)
		}
	case sg := <-sig:
		logger.Printf("signal %s, shutting down", sg)
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := httpSrv.Shutdown(ctx); err != nil {
			logger.Printf("shutdown: %v", err)
		}
	}
}
