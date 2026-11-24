package config

import (
	"bytes"
	"io"
	"net/http"
	"os"
	"regexp"

	"golang.org/x/net/http/httpproxy"
)

var pushReg = regexp.MustCompile(`/v2/.*/blobs/uploads/.*`)

func NewMixTransport(t *http.Transport) http.RoundTripper {
	noPorxy := t.Clone()
	noPorxy.Proxy = nil
	return &MixTransport{
		t,
		noPorxy,
	}
}

type MixTransport struct {
	proxyTransport   http.RoundTripper
	noProxyTransport http.RoundTripper
}

func HasProxy() bool {
	if proxyConfig := httpproxy.FromEnvironment(); proxyConfig.HTTPProxy != "" || proxyConfig.HTTPSProxy != "" {
		return true
	}
	return false
}

func (t *MixTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	var hasProxy bool
	url, err := http.ProxyFromEnvironment(req)
	if err == nil && url != nil {
		hasProxy = true
	}
	var f *os.File
	var reader io.ReadCloser
	if hasProxy && req.Body != nil {
		if pushReg.MatchString(req.URL.Path) {
			f, err = os.CreateTemp("", "mixtransport*")
			if err != nil {
				return nil, err
			}
			defer func() {
				f.Close()
				os.Remove(f.Name())
			}()
			io.Copy(f, req.Body)
			req.Body.Close()
			f.Seek(0, io.SeekStart)
			req.Body = io.NopCloser(f)
		} else {
			b, _ := io.ReadAll(req.Body)
			req.Body.Close()
			req.Body = io.NopCloser(bytes.NewBuffer(b))
			reader = io.NopCloser(bytes.NewBuffer(b))
		}
	}
	resp, err := t.proxyTransport.RoundTrip(req)
	if hasProxy && shouldFallbackDirect(resp, err) {
		if f != nil {
			f.Seek(0, io.SeekStart)
			req.Body = io.NopCloser(f)
		} else if reader != nil {
			req.Body = reader
		}
		resp, err = t.noProxyTransport.RoundTrip(req)
	}

	return resp, err
}

// shouldFallbackDirect reports whether a proxy response should be retried
// without the proxy. A 401 that carries WWW-Authenticate is an auth challenge
// for the caller, not a failed proxy hop.
func shouldFallbackDirect(resp *http.Response, err error) bool {
	if err != nil {
		return true
	}
	if resp == nil {
		return false
	}
	if resp.StatusCode == http.StatusUnauthorized && resp.Header.Get("WWW-Authenticate") != "" {
		return false
	}
	return resp.StatusCode > 399
}
