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

	"github.com/containerd/log/logtest"
)

func TestStarHostDockerIOMapping(t *testing.T) {
	ctx := logtest.WithT(context.Background(), t)

	tests := []struct {
		name      string
		toml      string
		host      string
		wantHosts []string
	}{
		{
			name: "docker.io without server rewrites star to registry-1",
			toml: `
[host."*"]
  capabilities = ["pull"]
`,
			host:      "docker.io",
			wantHosts: []string{"registry-1.docker.io", "registry-1.docker.io"},
		},
		{
			name: "explicit server does not rewrite star",
			toml: `
server = "https://mirror.example.com"

[host."*"]
  capabilities = ["pull"]
`,
			host:      "docker.io",
			wantHosts: []string{"docker.io", "mirror.example.com"},
		},
		{
			name: "non-docker host is unchanged",
			toml: `
[host."*"]
  capabilities = ["pull"]
`,
			host:      "ghcr.io",
			wantHosts: []string{"ghcr.io", "ghcr.io"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			if err := os.WriteFile(filepath.Join(dir, "hosts.toml"), []byte(tt.toml), 0o644); err != nil {
				t.Fatal(err)
			}
			resolve := ConfigureHosts(ctx, HostOptions{
				HostDir: func(string) (string, error) {
					return dir, nil
				},
			})
			hosts, err := resolve(tt.host)
			if err != nil {
				t.Fatal(err)
			}
			got := make([]string, 0, len(hosts))
			for _, h := range hosts {
				if h.Host == "*" {
					t.Fatalf("host %q left unresolved: %#v", tt.host, hosts)
				}
				got = append(got, h.Host)
			}
			if len(got) != len(tt.wantHosts) {
				t.Fatalf("hosts = %v, want %v", got, tt.wantHosts)
			}
			for i := range tt.wantHosts {
				if got[i] != tt.wantHosts[i] {
					t.Fatalf("hosts = %v, want %v", got, tt.wantHosts)
				}
			}
		})
	}
}
