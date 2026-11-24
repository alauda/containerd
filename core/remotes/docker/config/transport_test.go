/*
   Copyright The containerd Authors.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

package config

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"testing"

	"github.com/containerd/log/logtest"
)

type markerRoundTripper struct {
	base   http.RoundTripper
	called bool
}

func (m *markerRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	m.called = true
	return m.base.RoundTrip(req)
}

func TestUpdateClientWrapsMixTransportWhenProxySet(t *testing.T) {
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:9")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:9")
	t.Setenv("NO_PROXY", "")

	var marker *markerRoundTripper
	ctx := logtest.WithT(context.Background(), t)
	resolve := ConfigureHosts(ctx, HostOptions{
		UpdateClient: func(client *http.Client) error {
			marker = &markerRoundTripper{base: client.Transport}
			client.Transport = marker
			return nil
		},
	})

	hosts, err := resolve("ghcr.io")
	if err != nil {
		t.Fatal(err)
	}
	if len(hosts) == 0 || hosts[0].Client == nil {
		t.Fatal("expected a configured host client")
	}
	if hosts[0].Client.Transport != marker {
		t.Fatalf("UpdateClient RoundTripper not in chain, got %T", hosts[0].Client.Transport)
	}
	if _, ok := marker.base.(*MixTransport); !ok {
		t.Fatalf("MixTransport = %T, want it inside the UpdateClient wrapper", marker.base)
	}

	req, err := http.NewRequest(http.MethodGet, "https://ghcr.io/v2/", nil)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = hosts[0].Client.Transport.RoundTrip(req)
	if !marker.called {
		t.Fatal("UpdateClient RoundTripper was not called")
	}
}

func TestMixTransportAuthChallengeNoDirectFallback(t *testing.T) {
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:9")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:9")
	t.Setenv("NO_PROXY", "")

	tests := []struct {
		name       string
		status     int
		header     http.Header
		proxyErr   error
		wantDirect bool
		wantStatus int
	}{
		{
			name:   "401 with authenticate challenge",
			status: http.StatusUnauthorized,
			header: func() http.Header {
				h := make(http.Header)
				h.Set("WWW-Authenticate", `Bearer realm="https://registry.example/token"`)
				return h
			}(),
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "401 without challenge",
			status:     http.StatusUnauthorized,
			wantDirect: true,
			wantStatus: http.StatusOK,
		},
		{
			name:       "500",
			status:     http.StatusInternalServerError,
			wantDirect: true,
			wantStatus: http.StatusOK,
		},
		{
			name:       "connection error",
			proxyErr:   errors.New("dial tcp: connection refused"),
			wantDirect: true,
			wantStatus: http.StatusOK,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var proxyCalls, directCalls int
			mt := &MixTransport{
				proxyTransport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
					proxyCalls++
					if tt.proxyErr != nil {
						return nil, tt.proxyErr
					}
					header := tt.header.Clone()
					if header == nil {
						header = make(http.Header)
					}
					return &http.Response{
						StatusCode: tt.status,
						Header:     header,
						Body:       io.NopCloser(bytes.NewReader(nil)),
						Request:    req,
					}, nil
				}),
				noProxyTransport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
					directCalls++
					return &http.Response{
						StatusCode: http.StatusOK,
						Header:     make(http.Header),
						Body:       io.NopCloser(bytes.NewReader(nil)),
						Request:    req,
					}, nil
				}),
			}

			req, err := http.NewRequest(http.MethodGet, "https://registry.example/v2/", nil)
			if err != nil {
				t.Fatal(err)
			}
			resp, err := mt.RoundTrip(req)
			if err != nil {
				t.Fatal(err)
			}
			resp.Body.Close()
			if proxyCalls != 1 {
				t.Fatalf("proxy calls = %d, want 1", proxyCalls)
			}
			wantDirectCalls := 0
			if tt.wantDirect {
				wantDirectCalls = 1
			}
			if directCalls != wantDirectCalls {
				t.Fatalf("direct calls = %d, want %d", directCalls, wantDirectCalls)
			}
			if resp.StatusCode != tt.wantStatus {
				t.Fatalf("status = %d, want %d", resp.StatusCode, tt.wantStatus)
			}
			if tt.status == http.StatusUnauthorized && tt.header.Get("WWW-Authenticate") != "" {
				if resp.Header.Get("WWW-Authenticate") == "" {
					t.Fatal("authenticate challenge was not returned")
				}
			}
		})
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return f(req)
}
