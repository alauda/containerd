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

package images

import (
	"context"
	"crypto/tls"
	"net/http"
	"reflect"
	"testing"
	"unsafe"
)

func TestLegacyMixTransportDirectFallbackUsesTLS(t *testing.T) {
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:9")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:9")
	t.Setenv("NO_PROXY", "")

	hosts, err := (&CRIImageService{}).registryHosts(context.Background(), nil, nil)("127.0.0.1:5000")
	if err != nil {
		t.Fatal(err)
	}
	if len(hosts) == 0 || hosts[0].Client == nil || hosts[0].Client.Transport == nil {
		t.Fatal("expected a legacy registry host transport")
	}

	cfg := directFallbackTLS(hosts[0].Client.Transport)
	if cfg == nil || !cfg.InsecureSkipVerify {
		t.Fatalf("direct fallback TLS = %#v, want InsecureSkipVerify", cfg)
	}
}

func directFallbackTLS(rt http.RoundTripper) *tls.Config {
	v := reflect.ValueOf(rt)
	if v.Kind() != reflect.Pointer || v.IsNil() {
		return nil
	}
	field := v.Elem().FieldByName("noProxyTransport")
	if !field.IsValid() {
		return nil
	}
	inner := reflect.NewAt(field.Type(), unsafe.Pointer(field.UnsafeAddr())).Elem().Interface()
	tr, ok := inner.(*http.Transport)
	if !ok {
		return nil
	}
	return tr.TLSClientConfig
}
