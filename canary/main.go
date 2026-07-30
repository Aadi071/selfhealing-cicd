// Canary — a deliberately breakable service used to build and prove the
// self-healing CI/CD platform. It exposes health probes, Prometheus metrics,
// and two independent fault mechanisms:
//
//   1. Deploy-time fault  (env FAULT_MODE=true)  -> serves errors from startup.
//      Used to prove the PIPELINE catches a bad deploy and rolls back (P2).
//
//   2. Runtime fault       (POST /fault/on)       -> flips to errors on command,
//      AFTER the deploy has already gone green. Used to prove the SELF-HEALING
//      controller rolls back on a live production signal (P4).
//
// Pure stdlib: no external modules, tiny static image, builds offline.
package main

import (
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// ---- config (all via env, with sane defaults) ------------------------------

type config struct {
	port         string
	version      string
	faultStatus  int
	readyDelay   time.Duration
	startFaulted bool
	startRatio   float64
}

func loadConfig() config {
	return config{
		port:         env("PORT", "8080"),
		version:      env("VERSION", "dev"),
		faultStatus:  envInt("FAULT_STATUS", 500),
		readyDelay:   time.Duration(envInt("READY_DELAY_SECONDS", 0)) * time.Second,
		startFaulted: env("FAULT_MODE", "false") == "true",
		startRatio:   envFloat("FAULT_RATIO", 1.0),
	}
}

// ---- fault state (togglable at runtime) ------------------------------------

type faultState struct {
	on    atomic.Bool
	ratio atomic.Value // float64: fraction of requests that error [0..1]
}

func (f *faultState) enable(ratio float64) { f.ratio.Store(clamp01(ratio)); f.on.Store(true) }
func (f *faultState) disable()             { f.on.Store(false) }

// shouldFail decides per-request whether to inject a fault.
func (f *faultState) shouldFail() bool {
	if !f.on.Load() {
		return false
	}
	r, _ := f.ratio.Load().(float64)
	if r >= 1.0 {
		return true
	}
	return rand.Float64() < r
}

// ---- metrics (hand-rolled Prometheus exposition) ---------------------------

type metrics struct {
	mu     sync.Mutex
	counts map[string]int64 // key: path|status
}

func newMetrics() *metrics { return &metrics{counts: map[string]int64{}} }

func (m *metrics) inc(path string, status int) {
	m.mu.Lock()
	m.counts[path+"|"+strconv.Itoa(status)]++
	m.mu.Unlock()
}

func (m *metrics) render(version string, faulted bool) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := "# HELP http_requests_total Total HTTP requests by path and status.\n"
	out += "# TYPE http_requests_total counter\n"
	for k, v := range m.counts {
		var path, status string
		for i := 0; i < len(k); i++ {
			if k[i] == '|' {
				path, status = k[:i], k[i+1:]
				break
			}
		}
		out += fmt.Sprintf("http_requests_total{path=%q,status=%q} %d\n", path, status, v)
	}
	out += "# HELP app_up Whether the app process is serving.\n# TYPE app_up gauge\napp_up 1\n"
	out += "# HELP app_fault_mode Whether fault injection is currently active (0/1).\n"
	out += "# TYPE app_fault_mode gauge\n"
	out += fmt.Sprintf("app_fault_mode %d\n", b2i(faulted))
	out += "# HELP app_build_info Build metadata; value is always 1.\n# TYPE app_build_info gauge\n"
	out += fmt.Sprintf("app_build_info{version=%q} 1\n", version)
	return out
}

// ---- server ----------------------------------------------------------------

func main() {
	cfg := loadConfig()
	faults := &faultState{}
	faults.ratio.Store(cfg.startRatio)
	if cfg.startFaulted {
		faults.enable(cfg.startRatio)
		log.Printf("starting in FAULT_MODE (ratio=%.2f, status=%d)", cfg.startRatio, cfg.faultStatus)
	}
	mtr := newMetrics()

	// readiness flips true after an optional delay (demonstrates readiness gating
	// on rollout: traffic is withheld until the new pod reports ready).
	var ready atomic.Bool
	if cfg.readyDelay <= 0 {
		ready.Store(true)
	} else {
		go func() {
			time.Sleep(cfg.readyDelay)
			ready.Store(true)
			log.Printf("readiness gate open after %s", cfg.readyDelay)
		}()
	}

	mux := http.NewServeMux()

	// Liveness: ALWAYS 200 unless the process is truly wedged. Deliberately does
	// NOT reflect fault mode — a faulted pod must stay alive and keep serving
	// errors so the platform can detect and roll it back, rather than k8s
	// silently restarting it and masking the bad deploy.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		fmt.Fprintln(w, "ok")
	})

	// Readiness: gates traffic during rollout; 503 until ready.
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		if ready.Load() {
			w.WriteHeader(200)
			fmt.Fprintln(w, "ready")
			return
		}
		w.WriteHeader(503)
		fmt.Fprintln(w, "not ready")
	})

	// Metrics for Prometheus.
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		fmt.Fprint(w, mtr.render(cfg.version, faults.on.Load()))
	})

	// Runtime fault control — this is what makes a GREEN deploy go bad on command.
	//   POST /fault/on?ratio=0.5   -> 50% of work requests start failing
	//   POST /fault/off            -> back to healthy
	mux.HandleFunc("/fault/on", func(w http.ResponseWriter, r *http.Request) {
		ratio := 1.0
		if q := r.URL.Query().Get("ratio"); q != "" {
			if v, err := strconv.ParseFloat(q, 64); err == nil {
				ratio = v
			}
		}
		faults.enable(ratio)
		log.Printf("runtime fault ENABLED (ratio=%.2f)", ratio)
		fmt.Fprintf(w, "fault on (ratio=%.2f)\n", ratio)
	})
	mux.HandleFunc("/fault/off", func(w http.ResponseWriter, r *http.Request) {
		faults.disable()
		log.Print("runtime fault DISABLED")
		fmt.Fprintln(w, "fault off")
	})

	// The "real work" route smoke tests hit and Prometheus watches.
	work := func(w http.ResponseWriter, r *http.Request) {
		status := 200
		if faults.shouldFail() {
			status = cfg.faultStatus
		}
		mtr.inc("/work", status)
		w.WriteHeader(status)
		if status == 200 {
			fmt.Fprintf(w, "ok v=%s\n", cfg.version)
		} else {
			fmt.Fprintf(w, "injected fault (status=%d) v=%s\n", status, cfg.version)
		}
	}
	mux.HandleFunc("/work", work)
	mux.HandleFunc("/", work) // root behaves like /work for convenience

	srv := &http.Server{
		Addr:              ":" + cfg.port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("canary v=%s listening on :%s", cfg.version, cfg.port)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

// ---- tiny env helpers ------------------------------------------------------

func env(k, def string) string {
	if v, ok := os.LookupEnv(k); ok {
		return v
	}
	return def
}
func envInt(k string, def int) int {
	if v, ok := os.LookupEnv(k); ok {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
func envFloat(k string, def float64) float64 {
	if v, ok := os.LookupEnv(k); ok {
		if n, err := strconv.ParseFloat(v, 64); err == nil {
			return n
		}
	}
	return def
}
func clamp01(f float64) float64 {
	if f < 0 {
		return 0
	}
	if f > 1 {
		return 1
	}
	return f
}
func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}
