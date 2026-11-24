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
	"context"
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
