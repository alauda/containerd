// fakeregistry serves the tiny registry and proxies used by acceptance.sh.
package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "usage: fakeregistry <serve|proxy401|auth|stall|forward>\n")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "serve":
		runRegistry(os.Args[2:], false)
	case "stall":
		runRegistry(os.Args[2:], true)
	case "proxy401":
		runProxy401(os.Args[2:])
	case "auth":
		runAuth(os.Args[2:])
	case "forward":
		runForward(os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "unknown mode %q\n", os.Args[1])
		os.Exit(2)
	}
}

func runRegistry(args []string, stallBlob bool) {
	fs := flag.NewFlagSet("registry", flag.ExitOnError)
	addr := fs.String("addr", ":5000", "listen address")
	logPath := fs.String("log", "", "request log")
	fs.Parse(args)
	marker := "plain"
	if stallBlob {
		marker = "stall"
	}
	blobs := newImage(marker)
	log.Fatal(http.ListenAndServe(*addr, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		appendLog(*logPath, r)
		serveRegistry(w, r, blobs, stallBlob)
	})))
}

func runProxy401(args []string) {
	fs := flag.NewFlagSet("proxy401", flag.ExitOnError)
	addr := fs.String("addr", ":8888", "listen address")
	realm := fs.String("realm", "http://127.0.0.1:8890/token", "WWW-Authenticate realm")
	logPath := fs.String("log", "", "request log")
	fs.Parse(args)
	log.Fatal(http.ListenAndServe(*addr, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		appendLog(*logPath, r)
		w.Header().Set("WWW-Authenticate", fmt.Sprintf(`Bearer realm=%q,service="accept.registry"`, *realm))
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	})))
}

func runAuth(args []string) {
	fs := flag.NewFlagSet("auth", flag.ExitOnError)
	addr := fs.String("addr", ":8890", "listen address")
	logPath := fs.String("log", "", "request log")
	fs.Parse(args)
	log.Fatal(http.ListenAndServe(*addr, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		appendLog(*logPath, r)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"token":"acceptance-token"}`))
	})))
}

func runForward(args []string) {
	fs := flag.NewFlagSet("forward", flag.ExitOnError)
	addr := fs.String("addr", ":8887", "listen address")
	logPath := fs.String("log", "", "request log")
	fs.Parse(args)
	client := &http.Client{Transport: &http.Transport{Proxy: nil}}
	log.Fatal(http.ListenAndServe(*addr, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		appendLog(*logPath, r)
		target := r.URL.String()
		if !r.URL.IsAbs() {
			target = "http://" + r.Host + r.URL.RequestURI()
		}
		out, err := http.NewRequest(r.Method, target, r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		out.Header = r.Header.Clone()
		resp, err := client.Do(out)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		for k, vs := range resp.Header {
			for _, v := range vs {
				w.Header().Add(k, v)
			}
		}
		w.WriteHeader(resp.StatusCode)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		_, _ = io.Copy(w, resp.Body)
	})))
}

type imageBlobs struct {
	config   []byte
	configD  string
	layer    []byte
	layerD   string
	manifest []byte
	manifD   string
}

func newImage(marker string) imageBlobs {
	var rawTar bytes.Buffer
	tw := tar.NewWriter(&rawTar)
	hdr := &tar.Header{Name: marker, Mode: 0o644, Size: int64(len(marker))}
	if err := tw.WriteHeader(hdr); err != nil {
		panic(err)
	}
	if _, err := tw.Write([]byte(marker)); err != nil {
		panic(err)
	}
	if err := tw.Close(); err != nil {
		panic(err)
	}
	var gzBuf bytes.Buffer
	zw := gzip.NewWriter(&gzBuf)
	if _, err := zw.Write(rawTar.Bytes()); err != nil {
		panic(err)
	}
	if err := zw.Close(); err != nil {
		panic(err)
	}
	diffID := digest(rawTar.Bytes())
	cfg := []byte(fmt.Sprintf(`{"architecture":"arm64","os":"linux","config":{},"rootfs":{"type":"layers","diff_ids":[%q]}}`, diffID))
	layer := gzBuf.Bytes()
	layerD := digest(layer)
	configD := digest(cfg)
	manifest := map[string]any{
		"schemaVersion": 2,
		"mediaType":     "application/vnd.docker.distribution.manifest.v2+json",
		"config": map[string]any{
			"mediaType": "application/vnd.docker.container.image.v1+json",
			"size":      len(cfg),
			"digest":    configD,
		},
		"layers": []map[string]any{{
			"mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
			"size":      len(layer),
			"digest":    layerD,
		}},
	}
	raw, err := json.Marshal(manifest)
	if err != nil {
		panic(err)
	}
	return imageBlobs{config: cfg, configD: configD, layer: layer, layerD: layerD, manifest: raw, manifD: digest(raw)}
}

func digest(b []byte) string {
	sum := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(sum[:])
}

func serveRegistry(w http.ResponseWriter, r *http.Request, blobs imageBlobs, stallBlob bool) {
	path := r.URL.Path
	switch {
	case path == "/v2/" || path == "/v2":
		w.WriteHeader(http.StatusOK)
	case strings.Contains(path, "/manifests/"):
		w.Header().Set("Content-Type", "application/vnd.docker.distribution.manifest.v2+json")
		w.Header().Set("Docker-Content-Digest", blobs.manifD)
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(blobs.manifest)))
		_, _ = w.Write(blobs.manifest)
	case strings.Contains(path, "/blobs/"):
		body, media := blobFor(path, blobs)
		if body == nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", media)
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
		if stallBlob && strings.HasSuffix(path, blobs.layerD) {
			w.WriteHeader(http.StatusOK)
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
			time.Sleep(10 * time.Minute)
			return
		}
		_, _ = w.Write(body)
	default:
		http.NotFound(w, r)
	}
}

func blobFor(path string, blobs imageBlobs) ([]byte, string) {
	switch {
	case strings.HasSuffix(path, blobs.configD):
		return blobs.config, "application/vnd.docker.container.image.v1+json"
	case strings.HasSuffix(path, blobs.layerD):
		return blobs.layer, "application/vnd.docker.image.rootfs.diff.tar.gzip"
	default:
		return nil, ""
	}
}

func appendLog(path string, r *http.Request) {
	if path == "" {
		return
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		log.Printf("log: %v", err)
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s %s\n", time.Now().UTC().Format(time.RFC3339), r.Method, r.URL.RequestURI())
}
