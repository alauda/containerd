#!/usr/bin/env bash
# Acceptance run for an Alauda containerd build.
#
# usage: acceptance.sh <bin-dir> <runc> <crictl> <critest> <result-dir>
#
# CNI plugins must already be in $CNI_BIN_DIR (default /opt/cni/bin):
# bridge and host-local are required. portmap is used for host-port cases.
#
# ACCEPTANCE_CASES is a comma list: startup,critest,c1,c2
#   2.3: default (all). 2.2: startup,critest,c2
# FAKEREGISTRY is the fakeregistry binary (default: next to this script).
# Build it before running:
#   CGO_ENABLED=0 go build -o alauda/test/fakeregistry alauda/test/fakeregistry.go
# A failed step keeps its logs under the result directory.

set -u
set -o pipefail

if [ "$#" -ne 5 ]; then
	echo "usage: $0 <bin-dir> <runc> <crictl> <critest> <result-dir>" >&2
	exit 2
fi

BIN_DIR=$1
RUNC=$2
CRICTL=$3
CRITEST=$4
RESULT=$5
CNI_BIN_DIR=${CNI_BIN_DIR:-/opt/cni/bin}
CASES=${ACCEPTANCE_CASES:-startup,critest,c1,c2}
FAKEREGISTRY=${FAKEREGISTRY:-"$(cd "$(dirname "$0")" && pwd)/fakeregistry"}
ROOT=${ACCEPTANCE_ROOT:-/var/lib/ctrd-accept}
SOCK=${ROOT}/containerd.sock
CERTS=${ROOT}/certs.d
SKIP_RE='[Aa]pp[Aa]rmor|[Ss][Ee][Ll]inux'

mkdir -p "$RESULT" /etc/cni/net.d
SUMMARY=$RESULT/summary.txt
: >"$SUMMARY"
PIDS=()

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$RESULT/run.log"; }
record() { printf '%s %s\n' "$1" "$2" | tee -a "$SUMMARY"; }
want() { case ",$CASES," in *,"$1",*) return 0 ;; *) return 1 ;; esac; }

cleanup_pids() {
	local pid
	for pid in "${PIDS[@]:-}"; do
		kill "$pid" 2>/dev/null || true
	done
	if [ -f "$ROOT/containerd.pid" ]; then
		kill "$(cat "$ROOT/containerd.pid")" 2>/dev/null || true
	fi
}
trap cleanup_pids EXIT

stop_containerd() {
	if [ -f "$ROOT/containerd.pid" ]; then
		kill "$(cat "$ROOT/containerd.pid")" 2>/dev/null || true
		wait "$(cat "$ROOT/containerd.pid")" 2>/dev/null || true
		rm -f "$ROOT/containerd.pid"
	fi
	rm -f "$SOCK"
}

ensure_overlay_backing() {
	# Nested containers often sit on overlayfs, which cannot be an overlay
	# upper/work dir. Put containerd root on a loop ext4 (or tmpfs) so the
	# snapshotter can mount.
	mkdir -p "$ROOT"
	local probe="$ROOT/.ovprobe"
	mkdir -p "$probe"/{l,u,w,m}
	if mount -t overlay overlay -o "lowerdir=$probe/l,upperdir=$probe/u,workdir=$probe/w,index=off" "$probe/m" 2>/dev/null; then
		umount "$probe/m"
		rm -rf "$probe"
		return 0
	fi
	rm -rf "$probe"
	if mountpoint -q "$ROOT"; then
		return 0
	fi
	local img="${ROOT}.img"
	if command -v mkfs.ext4 >/dev/null 2>&1; then
		log "mounting 8G ext4 loop at $ROOT for overlay snapshotter"
		dd if=/dev/zero of="$img" bs=1M count=8192 status=none
		mkfs.ext4 -q "$img"
		mount -o loop "$img" "$ROOT"
		return 0
	fi
	log "mounting tmpfs at $ROOT for overlay snapshotter"
	mount -t tmpfs -o size=8G tmpfs "$ROOT"
}

write_cni() {
	cat > /etc/cni/net.d/10-bridge.conflist <<'EOF'
{
  "cniVersion": "1.0.0",
  "name": "bridge",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": true,
      "promiscMode": true,
      "ipam": {
        "type": "host-local",
        "ranges": [[{"subnet": "10.88.0.0/16"}]],
        "routes": [{"dst": "0.0.0.0/0"}]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true}
    }
  ]
}
EOF
}

write_config() {
	local timeout=$1
	local local_pull=$2
	cat > "$ROOT/config.toml" <<EOF
version = 3

[plugins.'io.containerd.cri.v1.images']
  snapshotter = 'overlayfs'
  image_pull_progress_timeout = '${timeout}'
  use_local_image_pull = ${local_pull}

  [plugins.'io.containerd.cri.v1.images'.registry]
    config_path = '${CERTS}'

[plugins.'io.containerd.cri.v1.runtime']
  enable_selinux = false
  disable_apparmor = true

  [plugins.'io.containerd.cri.v1.runtime'.cni]
    bin_dirs = ['${CNI_BIN_DIR}']
    conf_dir = '/etc/cni/net.d'

  [plugins.'io.containerd.cri.v1.runtime'.containerd]
    default_runtime_name = 'runc'

    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
      runtime_type = 'io.containerd.runc.v2'

      [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
        BinaryName = '${RUNC}'
        SystemdCgroup = false

[plugins.'io.containerd.snapshotter.v1.overlayfs']
  slow_chown = true
EOF
}

start_containerd() {
	local phase=$1
	local timeout=$2
	local local_pull=$3
	local proxy=${4:-}
	stop_containerd
	write_cni
	write_config "$timeout" "$local_pull"
	local logf=$RESULT/containerd-${phase}.log
	local -a envargs=(env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u NO_PROXY -u no_proxy)
	if [ -n "$proxy" ]; then
		envargs=(env "HTTP_PROXY=$proxy" "HTTPS_PROXY=$proxy" "http_proxy=$proxy" "https_proxy=$proxy" "NO_PROXY=localhost,127.0.0.1,::1" "no_proxy=localhost,127.0.0.1,::1")
	fi
	"${envargs[@]}" "$BIN_DIR/containerd" \
		--config "$ROOT/config.toml" \
		--root "$ROOT/root" \
		--state "$ROOT/state" \
		--address "$SOCK" \
		--log-level info >>"$logf" 2>&1 &
	echo $! >"$ROOT/containerd.pid"
	local i
	for i in $(seq 1 30); do
		if "$CRICTL" --runtime-endpoint "unix://${SOCK}" info >"$RESULT/crictl-info-${phase}.txt" 2>"$RESULT/crictl-info-${phase}.err"; then
			return 0
		fi
		sleep 1
	done
	log "containerd did not become ready for ${phase}"
	return 1
}

cri() { "$CRICTL" --runtime-endpoint "unix://${SOCK}" "$@"; }

host_ip() {
	ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

cidr_dir() {
	local ip=$1
	local a b c d
	IFS=. read -r a b c d <<<"$ip"
	printf '%s.%s.%s.0_24' "$a" "$b" "$c"
}

write_hosts() {
	local ip=$1 port=$2
	local dir=$CERTS/$(cidr_dir "$ip")
	mkdir -p "$dir"
	cat >"$dir/hosts.toml" <<EOF
server = "http://${ip}:${port}"

[host."http://${ip}:${port}"]
  capabilities = ["pull", "resolve"]
EOF
	printf '%s\n' "$dir"
}

count_log() {
	local file=$1 needle=$2
	if [ ! -f "$file" ]; then
		echo 0
		return
	fi
	grep -c -- "$needle" "$file" || true
}

step_startup() {
	log "startup"
	{
		echo "containerd: $("$BIN_DIR/containerd" --version 2>&1)"
		echo "runc: $("$RUNC" --version 2>&1 | head -1)"
	} >"$RESULT/versions.txt"
	if start_containerd startup 5m0s false; then
		{
			echo "crictl info:"
			cat "$RESULT/crictl-info-startup.txt"
		} >>"$RESULT/versions.txt"
		record startup PASS
	else
		record startup FAIL
		return 1
	fi
}

step_critest() {
	log "critest"
	mkdir -p "$RESULT/critest"
	local skip_file=$RESULT/critest-skipped.txt
	{
		echo "skip regex: ${SKIP_RE}"
		echo "reason: AppArmor and SELinux are not available in this privileged container"
	} >"$skip_file"
	set +e
	"$CRITEST" \
		--runtime-endpoint "unix://${SOCK}" \
		--ginkgo.skip="$SKIP_RE" \
		--ginkgo.v \
		--report-dir "$RESULT/critest" \
		>"$RESULT/critest.log" 2>&1
	local rc=$?
	set -e
	# ginkgo prints skipped specs as "skipped" / "[SKIPPED]".
	grep -E 'SKIPPED|skipped' "$RESULT/critest.log" >>"$skip_file" || true
	local summary
	summary=$(grep -E 'SUCCESS!|FAIL!' "$RESULT/critest.log" | tail -1 || true)
	echo "$summary" >"$RESULT/critest-summary.txt"
	if [ "$rc" -eq 0 ]; then
		record critest "PASS ${summary}"
	else
		record critest "FAIL ${summary}"
	fi
	return 0
}

step_c1() {
	log "c1"
	local ip port dir
	ip=$(host_ip)
	port=15000
	if [ -z "$ip" ] || [ "$ip" = "127.0.0.1" ]; then
		record c1 FAIL
		echo "no non-loopback IPv4" >"$RESULT/c1.txt"
		return 0
	fi
	dir=$(write_hosts "$ip" "$port")
	: >"$RESULT/c1-registry.log"
	"$FAKEREGISTRY" serve --addr "${ip}:${port}" --log "$RESULT/c1-registry.log" >>"$RESULT/c1-fakeregistry.err" 2>&1 &
	PIDS+=($!)
	sleep 0.3
	local ref="${ip}:${port}/accept/only:c1"
	set +e
	cri pull "$ref" >"$RESULT/c1-pull.txt" 2>&1
	local rc=$?
	set -e
	local hits
	hits=$(count_log "$RESULT/c1-registry.log" "/v2/accept/only/manifests/c1")
	{
		echo "ip=$ip cidr_dir=$dir ref=$ref pull_rc=$rc hits=$hits"
	} >"$RESULT/c1.txt"
	if [ "$rc" -eq 0 ] && [ "$hits" -ge 1 ]; then
		record c1 PASS
	else
		record c1 FAIL
	fi
}

step_c2() {
	local ip
	ip=$(host_ip)
	if [ -z "$ip" ]; then
		record c2a FAIL
		record c2b FAIL
		record c2c FAIL
		echo "no non-loopback IPv4" >"$RESULT/c2.txt"
		return 0
	fi
	c2a "$ip"
	c2b "$ip"
	c2c "$ip"
}

c2a() {
	local ip=$1 port=15010
	log "c2a dead proxy fallback"
	write_hosts "$ip" "$port" >/dev/null
	: >"$RESULT/c2a-registry.log"
	"$FAKEREGISTRY" serve --addr "${ip}:${port}" --log "$RESULT/c2a-registry.log" >>"$RESULT/c2a-fakeregistry.err" 2>&1 &
	PIDS+=($!)
	sleep 0.3
	if ! start_containerd c2a 5m0s false "http://127.0.0.1:1"; then
		record c2a FAIL
		return 0
	fi
	local ref="${ip}:${port}/accept/only:c2a"
	set +e
	cri pull "$ref" >"$RESULT/c2a-pull.txt" 2>&1
	local rc=$?
	set -e
	local hits
	hits=$(count_log "$RESULT/c2a-registry.log" "/v2/accept/only/manifests/c2a")
	echo "pull_rc=$rc registry_hits=$hits" >"$RESULT/c2a.txt"
	if [ "$rc" -eq 0 ] && [ "$hits" -ge 1 ]; then
		record c2a PASS
	else
		record c2a FAIL
	fi
}

c2b() {
	local ip=$1 port=15020
	log "c2b 401 challenge does not fall back"
	write_hosts "$ip" "$port" >/dev/null
	: >"$RESULT/c2b-registry.log"
	: >"$RESULT/c2b-proxy.log"
	: >"$RESULT/c2b-auth.log"
	"$FAKEREGISTRY" serve --addr "${ip}:${port}" --log "$RESULT/c2b-registry.log" >>"$RESULT/c2b-fakeregistry.err" 2>&1 &
	PIDS+=($!)
	"$FAKEREGISTRY" proxy401 --addr "127.0.0.1:18888" --realm "http://127.0.0.1:18890/token" --log "$RESULT/c2b-proxy.log" >>"$RESULT/c2b-proxy.err" 2>&1 &
	PIDS+=($!)
	"$FAKEREGISTRY" auth --addr "127.0.0.1:18890" --log "$RESULT/c2b-auth.log" >>"$RESULT/c2b-auth.err" 2>&1 &
	PIDS+=($!)
	sleep 0.3
	if ! start_containerd c2b 5m0s false "http://127.0.0.1:18888"; then
		record c2b FAIL
		return 0
	fi
	local ref="${ip}:${port}/accept/only:c2b"
	set +e
	cri pull "$ref" >"$RESULT/c2b-pull.txt" 2>&1
	local rc=$?
	set -e
	local reg_hits auth_hits proxy_hits
	reg_hits=$(count_log "$RESULT/c2b-registry.log" "/v2/accept/only/manifests/c2b")
	auth_hits=$(count_log "$RESULT/c2b-auth.log" "/token")
	proxy_hits=$(count_log "$RESULT/c2b-proxy.log" " ")
	echo "pull_rc=$rc registry_hits=$reg_hits auth_hits=$auth_hits proxy_hits=$proxy_hits" >"$RESULT/c2b.txt"
	# Pull must not succeed via a direct retry. Auth realm must be contacted.
	if [ "$rc" -ne 0 ] && [ "$reg_hits" -eq 0 ] && [ "$auth_hits" -ge 1 ] && [ "$proxy_hits" -ge 1 ]; then
		record c2b PASS
	else
		record c2b FAIL
	fi
}

c2c() {
	local ip=$1 port=15030
	log "c2c pull progress timeout with proxy"
	write_hosts "$ip" "$port" >/dev/null
	: >"$RESULT/c2c-stall.log"
	: >"$RESULT/c2c-proxy.log"
	"$FAKEREGISTRY" stall --addr "${ip}:${port}" --log "$RESULT/c2c-stall.log" >>"$RESULT/c2c-stall.err" 2>&1 &
	PIDS+=($!)
	"$FAKEREGISTRY" forward --addr "127.0.0.1:18887" --log "$RESULT/c2c-proxy.log" >>"$RESULT/c2c-proxy.err" 2>&1 &
	PIDS+=($!)
	sleep 0.3
	if ! start_containerd c2c 5s true "http://127.0.0.1:18887"; then
		record c2c FAIL
		return 0
	fi
	local ref="${ip}:${port}/accept/stall:c2c"
	local start end elapsed rc
	start=$(date +%s)
	set +e
	timeout 25 "$CRICTL" --runtime-endpoint "unix://${SOCK}" pull "$ref" >"$RESULT/c2c-pull.txt" 2>&1
	rc=$?
	set -e
	end=$(date +%s)
	elapsed=$((end - start))
	echo "pull_rc=$rc elapsed=${elapsed}s" >"$RESULT/c2c.txt"
	# 124 is timeout(1): the pull hung past 25s. A real progress timeout fails sooner.
	if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$elapsed" -le 20 ]; then
		record c2c PASS
	else
		record c2c FAIL
	fi
}

main() {
	ensure_overlay_backing
	mkdir -p "$ROOT" "$CERTS"
	# runc re-execs itself via /proc/self/fd. A virtiofs/noexec mount returns
	# EPERM; the copy on the ext4 loop does not.
	install -m 0755 "$RUNC" "$ROOT/runc"
	RUNC=$ROOT/runc
	log "cases=$CASES result=$RESULT"
	"$BIN_DIR/containerd" --version | tee "$RESULT/containerd-version.txt"
	"$RUNC" --version | head -1 | tee "$RESULT/runc-version.txt"
	if want startup; then
		step_startup || true
	fi
	if want critest; then
		step_critest || true
	fi
	if want c1; then
		step_c1 || true
	fi
	if want c2; then
		step_c2 || true
	fi
	log "summary:"
	cat "$SUMMARY" | tee -a "$RESULT/run.log"
}

main
