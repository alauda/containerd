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
	"os"
	"path/filepath"
	"testing"

	"github.com/containerd/errdefs"
	"github.com/containerd/log/logtest"
)

func TestHostDirFromRootCIDR(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"10.0.0.0_8", "192.168.1.0_24", "10.1.2.3"} {
		if err := os.Mkdir(filepath.Join(root, name), 0o755); err != nil {
			t.Fatal(err)
		}
	}

	lookup := HostDirFromRoot(root)
	tests := []struct {
		name     string
		host     string
		wantDir  string
		notFound bool
	}{
		{name: "ip in slash-eight", host: "10.9.8.7", wantDir: "10.0.0.0_8"},
		{name: "ip in twenty-four", host: "192.168.1.10", wantDir: "192.168.1.0_24"},
		{name: "port stripped before match", host: "192.168.1.10:5000", wantDir: "192.168.1.0_24"},
		{name: "exact host dir wins over cidr", host: "10.1.2.3", wantDir: "10.1.2.3"},
		{name: "no matching cidr", host: "172.16.0.1", notFound: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := lookup(tt.host)
			if tt.notFound {
				if !errdefs.IsNotFound(err) {
					t.Fatalf("lookup(%q) err = %v, want not found", tt.host, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("lookup(%q) err = %v", tt.host, err)
			}
			if got != filepath.Join(root, tt.wantDir) {
				t.Fatalf("lookup(%q) = %q, want dir %q", tt.host, got, tt.wantDir)
			}
		})
	}
}

func TestStarHostResolvesToRequestedHost(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "hosts.toml"), []byte(`
[host."*"]
  capabilities = ["pull"]
`), 0o644); err != nil {
		t.Fatal(err)
	}

	ctx := logtest.WithT(context.Background(), t)
	resolve := ConfigureHosts(ctx, HostOptions{
		HostDir: func(string) (string, error) {
			return dir, nil
		},
	})

	tests := []struct {
		host     string
		wantHost string
	}{
		{host: "ghcr.io", wantHost: "ghcr.io"},
		{host: "quay.io", wantHost: "quay.io"},
	}
	for _, tt := range tests {
		t.Run(tt.host, func(t *testing.T) {
			hosts, err := resolve(tt.host)
			if err != nil {
				t.Fatal(err)
			}
			var matched bool
			for _, h := range hosts {
				if h.Host == "*" {
					t.Fatalf("host %q left unresolved", tt.host)
				}
				if h.Host == tt.wantHost {
					matched = true
				}
			}
			if !matched {
				t.Fatalf("resolve(%q) hosts = %#v, want a host %q", tt.host, hosts, tt.wantHost)
			}
		})
	}
}
