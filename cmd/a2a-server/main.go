// a2a-server runs the standalone private A2A messaging server.
//
// It is NOT the standard a2a-protocol.org service: it is the self-hosted
// private messaging platform (Bearer token + Ed25519 signatures).
//
//	picoclaw/a2a-server                        run the server (flags below)
//	a2a-server init   -dir DIR -domain DOMAIN -agents alice,bob
//	a2a-server add-agent -dir DIR -agents carol
//	a2a-server check  -dir DIR [-json]
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/cnbillsomeday/agent-a2a-platform/server"
)

const (
	defaultAddr      = "127.0.0.1:21220"
	defaultDir       = "./data"
	defaultDomain    = "localhost"
	defaultRetention = 24 * time.Hour
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "init":
			os.Exit(runInit(os.Args[2:]))
		case "add-agent":
			os.Exit(runAddAgent(os.Args[2:]))
		case "check":
			os.Exit(runCheck(os.Args[2:]))
		case "help", "-h", "--help":
			usage()
			return
		}
	}
	os.Exit(runServer(os.Args[1:]))
}

func usage() {
	fmt.Fprintf(os.Stderr, `a2a-server — private A2A messaging server (not a2a-protocol.org)

Usage:
  a2a-server [flags]                    run the server
  a2a-server init -dir DIR -domain DOMAIN -agents a,b
  a2a-server add-agent -dir DIR -agents c
  a2a-server check -dir DIR [-json]     read-only self check

Run flags:
  -addr string        listen address (env A2A_ADDR; default %s)
  -dir string         state directory (env A2A_DIR; default %s)
  -domain string      public domain for did:web (env A2A_DOMAIN; default %s)
  -retention duration message retention (env A2A_RETENTION; default %s)
  -sign-mode string   off | warn | strict (env A2A_SIGN_MODE)
  -allow-default-agents  allow the built-in demo agents
`, defaultAddr, defaultDir, defaultDomain, defaultRetention)
}

func runServer(args []string) int {
	fs := flag.NewFlagSet("a2a-server", flag.ExitOnError)
	addr := fs.String("addr", envOr("A2A_ADDR", defaultAddr), "listen address")
	dir := fs.String("dir", envOr("A2A_DIR", defaultDir), "state directory")
	domain := fs.String("domain", envOr("A2A_DOMAIN", defaultDomain), "public domain for did:web")
	retention := fs.Duration("retention", envDuration("A2A_RETENTION", defaultRetention), "message retention")
	signMode := fs.String("sign-mode", os.Getenv("A2A_SIGN_MODE"), "off|warn|strict")
	allowDefault := fs.Bool("allow-default-agents", false, "allow built-in demo agents")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	logger := log.New(os.Stderr, "a2a ", log.LstdFlags|log.LUTC)
	inst, err := server.New(server.Options{
		Listen:             strings.TrimSpace(*addr),
		DataDir:            expandHome(strings.TrimSpace(*dir)),
		Domain:             strings.TrimSpace(*domain),
		Retention:          *retention,
		SignMode:           strings.TrimSpace(*signMode),
		AllowDefaultAgents: *allowDefault,
		Logger:             logger,
	})
	if err != nil {
		logger.Printf("start: %v", err)
		return 1
	}
	if err := inst.Start(); err != nil {
		_ = inst.Stop(context.Background())
		logger.Printf("start: %v", err)
		return 1
	}
	logger.Printf("listening on %s", inst.Addr())

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	<-ctx.Done()
	stopCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = inst.Stop(stopCtx)
	return 0
}

func runInit(args []string) int {
	fs := flag.NewFlagSet("init", flag.ExitOnError)
	dir := fs.String("dir", os.Getenv("A2A_DIR"), "state directory")
	domain := fs.String("domain", envOr("A2A_DOMAIN", defaultDomain), "public domain for did:web")
	agents := fs.String("agents", "", "comma-separated agent slugs to create")
	addAgents := fs.String("add-agents", "", "comma-separated agent slugs to append")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	res, err := server.InitData(server.InitOptions{
		DataDir:   expandHome(strings.TrimSpace(*dir)),
		Domain:    strings.TrimSpace(*domain),
		Agents:    splitCSV(*agents),
		AddAgents: splitCSV(*addAgents),
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "init:", err)
		return 1
	}
	fmt.Printf("data dir: %s\n", res.DataDir)
	for _, slug := range res.Added {
		fmt.Printf("%s %s\n", slug, res.Tokens[slug])
	}
	return 0
}

func runAddAgent(args []string) int {
	fs := flag.NewFlagSet("add-agent", flag.ExitOnError)
	dir := fs.String("dir", os.Getenv("A2A_DIR"), "state directory")
	agents := fs.String("agents", "", "comma-separated agent slugs to append")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	res, err := server.InitData(server.InitOptions{
		DataDir:   expandHome(strings.TrimSpace(*dir)),
		AddAgents: splitCSV(*agents),
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "add-agent:", err)
		return 1
	}
	for _, slug := range res.Added {
		fmt.Printf("%s %s\n", slug, res.Tokens[slug])
	}
	return 0
}

func runCheck(args []string) int {
	fs := flag.NewFlagSet("check", flag.ExitOnError)
	dir := fs.String("dir", os.Getenv("A2A_DIR"), "state directory")
	listen := fs.String("addr", envOr("A2A_ADDR", defaultAddr), "listen address to check")
	domain := fs.String("domain", envOr("A2A_DOMAIN", defaultDomain), "public domain")
	signMode := fs.String("sign-mode", os.Getenv("A2A_SIGN_MODE"), "off|warn|strict")
	asJSON := fs.Bool("json", false, "print JSON")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	report := server.CheckData(server.CheckOptions{
		DataDir:  expandHome(strings.TrimSpace(*dir)),
		Listen:   strings.TrimSpace(*listen),
		Domain:   strings.TrimSpace(*domain),
		SignMode: strings.TrimSpace(*signMode),
	})
	if *asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(report)
	} else {
		fmt.Printf("data dir: %s\nok: %v\n", report.DataDir, report.OK)
		for _, e := range report.Errors {
			fmt.Printf("error: %s\n", e)
		}
		for _, w := range report.Warnings {
			fmt.Printf("warning: %s\n", w)
		}
	}
	if !report.OK {
		return 1
	}
	return 0
}

func splitCSV(raw string) []string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func envOr(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}

func envDuration(key string, fallback time.Duration) time.Duration {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return fallback
	}
	d, err := time.ParseDuration(raw)
	if err != nil || d <= 0 {
		return fallback
	}
	return d
}

func expandHome(path string) string {
	if path == "" || path[0] != '~' {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return path
	}
	if path == "~" {
		return home
	}
	if strings.HasPrefix(path, "~/") {
		return filepath.Join(home, path[2:])
	}
	return path
}
