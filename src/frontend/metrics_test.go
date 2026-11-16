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

package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRouteLabel(t *testing.T) {
	cases := map[string]string{
		"/":                     "/",
		"/product/OLJCESPC7Z":   "/product/{id}",
		"/product-meta/a,b":     "/product-meta/{ids}",
		"/static/img/logo.svg":  "/static",
		"/cart/checkout":        "/cart/checkout",
		"/_healthz":             "/_healthz",
		"/wp-admin/install.php": "other",
	}
	for in, want := range cases {
		if got := routeLabel("", in); got != want {
			t.Errorf("routeLabel(%q) = %q, want %q", in, got, want)
		}
	}
	if got := routeLabel("/shop", "/shop"); got != "/" {
		t.Errorf("base url root: got %q", got)
	}
	if got := routeLabel("/shop", "/shop/cart"); got != "/cart" {
		t.Errorf("base url route: got %q", got)
	}
}

func TestMiddlewareCountsAndExposes(t *testing.T) {
	m := newHTTPMetrics()
	h := m.middleware("", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/cart/checkout" {
			http.Error(w, "boom", http.StatusInternalServerError)
			return
		}
		_, _ = w.Write([]byte("ok"))
	}))

	for _, p := range []string{"/", "/", "/product/X", "/cart/checkout"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, p, nil))
		if rec.Header().Get("X-App-Version") != version {
			t.Fatalf("missing X-App-Version header on %s", p)
		}
	}

	rec := httptest.NewRecorder()
	m.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := rec.Body.String()

	for _, want := range []string{
		`boutique_frontend_http_requests_total{method="GET",route="/",code="200"} 2`,
		`boutique_frontend_http_requests_total{method="GET",route="/product/{id}",code="200"} 1`,
		`boutique_frontend_http_requests_total{method="GET",route="/cart/checkout",code="500"} 1`,
		`boutique_frontend_http_request_duration_seconds_count{route="/"} 2`,
		`boutique_frontend_http_request_duration_seconds_bucket{route="/",le="+Inf"} 2`,
		`boutique_frontend_build_info{version="dev"} 1`,
		`boutique_frontend_http_requests_in_flight 0`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("metrics output missing %q\n---\n%s", want, body)
		}
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/plain; version=0.0.4") {
		t.Errorf("unexpected content type %q", ct)
	}
}
