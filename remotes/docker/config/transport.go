package config

import (
	"bytes"
	"io"
	"net/http"
	"os"
	"regexp"
)

var pushReg = regexp.MustCompile(`/v2/.*/blobs/uploads/.*`)

func NewMixTransport(proxy http.RoundTripper, noProxy http.RoundTripper) http.RoundTripper {
	return &MixTransport{
		proxy,
		noProxy,
	}
}

type MixTransport struct {
	proxyTransport   http.RoundTripper
	noProxyTransport http.RoundTripper
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
			f, err = os.CreateTemp("/tmp", "mixtransport*")
			defer func() {
				f.Close()
				os.Remove(f.Name())
			}()
			if err != nil {
				return nil, err
			}
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
	if hasProxy && (err != nil || resp.StatusCode > 399) {
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
