// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// metrics.go adds a minimal Prometheus endpoint to the frontend.
//
// Challenge note: upstream leaves initStats() as a TODO, so no service in
// Online Boutique exposes Prometheus metrics. This file fills that gap for the
// frontend only, using the standard library alone so that go.mod/go.sum stay
// untouched (smaller diff from upstream, no new supply-chain dependencies).
// In a real product you would use github.com/prometheus/client_golang or the
// OpenTelemetry metrics SDK instead; see docs/challenge/architecture.md.
//
// Metrics are served on a separate port (METRICS_PORT, default 9090) so that
// they are never exposed through the public Gateway/HTTPRoute.

package main

import (
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// version is injected at build time: -ldflags "-X main.version=1.1.0".
var version = "dev"

var latencyBuckets = []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}

// knownRoutes keeps label cardinality bounded: every unknown path is "other".
var knownRoutes = map[string]bool{
	"/": true, "/cart": true, "/cart/empty": true, "/cart/checkout": true,
	"/setCurrency": true, "/logout": true, "/assistant": true, "/bot": true,
	"/robots.txt": true, "/_healthz": true,
}

type requestKey struct {
	method, route, code string
}

type histogram struct {
	counts []uint64 // cumulative per bucket, len(latencyBuckets)
	sum    float64
	count  uint64
}

type httpMetrics struct {
	mu        sync.Mutex
	requests  map[requestKey]uint64
	latencies map[string]*histogram // by route
	inFlight  int64
	started   time.Time
}

func newHTTPMetrics() *httpMetrics {
	return &httpMetrics{
		requests:  map[requestKey]uint64{},
		latencies: map[string]*histogram{},
		started:   time.Now(),
	}
}

// routeLabel maps a raw URL path to a low-cardinality route template.
func routeLabel(base, path string) string {
	p := strings.TrimPrefix(path, base)
	if p == "" {
		p = "/"
	}
	switch {
	case knownRoutes[p]:
		return p
	case strings.HasPrefix(p, "/product/"):
		return "/product/{id}"
	case strings.HasPrefix(p, "/product-meta/"):
		return "/product-meta/{ids}"
	case strings.HasPrefix(p, "/static/"):
		return "/static"
	default:
		return "other"
	}
}

func (m *httpMetrics) observe(method, route string, code int, d time.Duration) {
	secs := d.Seconds()
	m.mu.Lock()
	defer m.mu.Unlock()
	m.requests[requestKey{method, route, strconv.Itoa(code)}]++
	h, ok := m.latencies[route]
	if !ok {
		h = &histogram{counts: make([]uint64, len(latencyBuckets))}
		m.latencies[route] = h
	}
	for i, b := range latencyBuckets {
		if secs <= b {
			h.counts[i]++
		}
	}
	h.sum += secs
	h.count++
}

// statusWriter records the status code written by the wrapped handler.
type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	if w.status == 0 {
		w.status = code
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	return w.ResponseWriter.Write(b)
}

// middleware instruments every request and adds the X-App-Version header,
// which makes a rollout visible with a plain `curl -I`.
func (m *httpMetrics) middleware(base string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		atomic.AddInt64(&m.inFlight, 1)
		defer atomic.AddInt64(&m.inFlight, -1)

		w.Header().Set("X-App-Version", version)
		sw := &statusWriter{ResponseWriter: w}
		next.ServeHTTP(sw, r)
		if sw.status == 0 {
			sw.status = http.StatusOK
		}
		m.observe(r.Method, routeLabel(base, r.URL.Path), sw.status, time.Since(start))
	})
}

func fmtFloat(f float64) string { return strconv.FormatFloat(f, 'g', -1, 64) }

// ServeHTTP renders the Prometheus text exposition format (version 0.0.4).
func (m *httpMetrics) ServeHTTP(w http.ResponseWriter, _ *http.Request) {
	m.mu.Lock()
	keys := make([]requestKey, 0, len(m.requests))
	for k := range m.requests {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		a, b := keys[i], keys[j]
		if a.route != b.route {
			return a.route < b.route
		}
		if a.method != b.method {
			return a.method < b.method
		}
		return a.code < b.code
	})
	routes := make([]string, 0, len(m.latencies))
	for r := range m.latencies {
		routes = append(routes, r)
	}
	sort.Strings(routes)

	var sb strings.Builder
	sb.WriteString("# HELP boutique_frontend_http_requests_total Total HTTP requests handled by the frontend.\n")
	sb.WriteString("# TYPE boutique_frontend_http_requests_total counter\n")
	for _, k := range keys {
		fmt.Fprintf(&sb, "boutique_frontend_http_requests_total{method=%q,route=%q,code=%q} %d\n",
			k.method, k.route, k.code, m.requests[k])
	}
	sb.WriteString("# HELP boutique_frontend_http_request_duration_seconds HTTP request latency.\n")
	sb.WriteString("# TYPE boutique_frontend_http_request_duration_seconds histogram\n")
	for _, r := range routes {
		h := m.latencies[r]
		for i, b := range latencyBuckets {
			fmt.Fprintf(&sb, "boutique_frontend_http_request_duration_seconds_bucket{route=%q,le=%q} %d\n",
				r, fmtFloat(b), h.counts[i])
		}
		fmt.Fprintf(&sb, "boutique_frontend_http_request_duration_seconds_bucket{route=%q,le=\"+Inf\"} %d\n", r, h.count)
		fmt.Fprintf(&sb, "boutique_frontend_http_request_duration_seconds_sum{route=%q} %s\n", r, fmtFloat(h.sum))
		fmt.Fprintf(&sb, "boutique_frontend_http_request_duration_seconds_count{route=%q} %d\n", r, h.count)
	}
	m.mu.Unlock()

	sb.WriteString("# HELP boutique_frontend_http_requests_in_flight Requests currently being served.\n")
	sb.WriteString("# TYPE boutique_frontend_http_requests_in_flight gauge\n")
	fmt.Fprintf(&sb, "boutique_frontend_http_requests_in_flight %d\n", atomic.LoadInt64(&m.inFlight))
	sb.WriteString("# HELP boutique_frontend_build_info Build information; value is always 1.\n")
	sb.WriteString("# TYPE boutique_frontend_build_info gauge\n")
	fmt.Fprintf(&sb, "boutique_frontend_build_info{version=%q} 1\n", version)
	sb.WriteString("# HELP boutique_frontend_start_time_seconds Process start time (unix seconds).\n")
	sb.WriteString("# TYPE boutique_frontend_start_time_seconds gauge\n")
	fmt.Fprintf(&sb, "boutique_frontend_start_time_seconds %d\n", m.started.Unix())

	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_, _ = w.Write([]byte(sb.String()))
}

// serveMetrics starts the metrics listener on its own port.
func serveMetrics(m *httpMetrics, addr, port string, logf func(string, ...interface{})) {
	mux := http.NewServeMux()
	mux.Handle("/metrics", m)
	srv := &http.Server{Addr: addr + ":" + port, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	logf("starting metrics server on %s:%s", addr, port)
	if err := srv.ListenAndServe(); err != nil {
		logf("metrics server stopped: %v", err)
	}
}
