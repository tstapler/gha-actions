#!/usr/bin/env bash
# Unit tests for the shell logic. Plain bash: no test framework to pin or install.
# Usage: test/run.sh   (exit 1 on any failure)
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0 passes=0

ok() { passes=$((passes + 1)); echo "ok   - $1"; }
fail() { fails=$((fails + 1)); echo "FAIL - $1${2:+: $2}"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected '$3' got '$2'"; fi; }
assert_contains() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else fail "$1" "'$3' not in output"; fi; }

# --- gradle-ci-memory/compute.sh -------------------------------------------------------------
compute() { # TOTAL CPUS [extra env as KEY=VAL...] -> prints "gradle kotlin workers"
  local total=$1 cpus=$2; shift 2
  local props="$tmp/props.$RANDOM" outf="$tmp/out.$RANDOM"
  env TOTAL_MB="$total" CPUS="$cpus" PROPS_FILE="$props" GITHUB_OUTPUT="$outf" "$@" \
    bash "$root/gradle-ci-memory/compute.sh" >/dev/null
  local g k w
  g=$(sed -n 's/^gradle-heap-mb=//p' "$outf"); k=$(sed -n 's/^kotlin-heap-mb=//p' "$outf"); w=$(sed -n 's/^workers-max=//p' "$outf")
  echo "$g $k $w"
}

assert_eq "16 GB / 4 cpu matches the hand-tuned stelekit values" "$(compute 15990 4)" "2560 5120 2"
assert_eq "7 GB / 2 cpu" "$(compute 7168 2)" "1152 2304 1"
assert_eq "huge runner is capped by the max inputs" "$(compute 262144 64)" "4096 8192 32"
assert_eq "explicit heaps win, no cap" "$(compute 7168 2 GRADLE_HEAP_MB=3000 KOTLIN_HEAP_MB=6000)" "3000 6000 1"
assert_eq "explicit workers" "$(compute 15990 4 WORKERS_MAX=3)" "2560 5120 3"

# Invariant: derived gradle + kotlin + forks never exceed total RAM, for every size and CPU count.
bad=""
for total in 2048 3072 4096 6144 7168 8192 12288 15990 16384 32768 65536; do
  for cpus in 1 2 4 8 16; do
    read -r g k w <<< "$(compute "$total" "$cpus")"
    if [ $(( g + k + w * 1024 )) -gt "$total" ] && [ "$total" -ge 4096 ]; then bad="$bad $total/$cpus($g,$k,$w)"; fi
  done
done
assert_eq "heaps + forks fit in RAM for RAM>=4 GB across sizes/cpus" "$bad" ""

props="$tmp/p1"; TOTAL_MB=15990 CPUS=4 PROPS_FILE="$props" KOTLIN_DIAG_FLAGS="-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/x" \
  KOTLIN_FALLBACK=disable KOTLIN_BUILD_REPORT_DIR=/r bash "$root/gradle-ci-memory/compute.sh" >/dev/null
content=$(cat "$props")
assert_contains "kotlin daemon args space-joined" "$content" "kotlin.daemon.jvmargs=-Xmx5120m -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/x"
assert_contains "fallback strategy disabled" "$content" "kotlin.daemon.useFallbackStrategy=false"
assert_contains "kotlin build report enabled" "$content" "kotlin.build.report.output=file"
props="$tmp/p2"; TOTAL_MB=15990 CPUS=4 PROPS_FILE="$props" bash "$root/gradle-ci-memory/compute.sh" >/dev/null
assert_eq "no diagnostics -> single -Xmx" "$(grep kotlin.daemon.jvmargs "$props")" "kotlin.daemon.jvmargs=-Xmx5120m"

# --- mem-sampler ---------------------------------------------------------------------------
cls=$(printf '%s\n' \
  '5242880 /usr/bin/java -Xmx5120m -cp x org.jetbrains.kotlin.daemon.KotlinCompileDaemon' \
  '2000000 /usr/bin/java -Xmx2g worker.org.gradle.process.internal.worker.GradleWorkerMain Gradle Test Executor 3' \
  '1000000 /usr/bin/java -Xmx2560m org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.10' \
  '900000 java -Xmx2g -jar /x/install/abc/A-server.jar --foo' \
  '800000 Xvfb :99 -screen 0' \
  '700000 /bin/foo --bar' | "$root/mem-sampler/bin/mem-sampler" --classify)
assert_contains "classifies kotlin daemon" "$cls" "5120M -Xmx5120m kotlin-daemon"
assert_contains "classifies test fork before gradle daemon" "$cls" "gradle-test-fork"
assert_contains "classifies gradle daemon" "$cls" "gradle-daemon"
assert_contains "classifies bazel server" "$cls" "bazel-server"
assert_contains "classifies xvfb" "$cls" "xvfb"
cls2=$(printf '%s\n' \
  '1800000 /opt/hostedtoolcache/go/1.26.6/x64/pkg/tool/linux_amd64/compile -o x.a' \
  '900000 /tmp/go-build/b001/server.test -test.timeout=15m' \
  '800000 /usr/bin/node /x/playwright test' | "$root/mem-sampler/bin/mem-sampler" --classify)
assert_contains "classifies go compile" "$cls2" "go-toolchain"
assert_contains "classifies go test binary" "$cls2" "go-test-binary"
assert_contains "classifies node" "$cls2" "node-or-bun"

metrics="$tmp/m.json"
"$root/mem-sampler/bin/mem-sampler" --out "$metrics" --label t --interval 1 --no-summary -- bash -c 'sleep 2; exit 7' >"$tmp/log" 2>&1
assert_eq "exit status passes through" "$?" "7"
assert_contains "sampler logged to stdout" "$(cat "$tmp/log")" "[mem] used="
assert_contains "top lines logged" "$(cat "$tmp/log")" "[mem-top]"
if python3 -I -c "
import json,sys
d=json.load(open('$metrics'))
m={x['name']:x['value'] for x in d['metrics']}
assert d['schema']==1 and m['peak_used']>0 and m['min_available']>0
assert {x['group'] for x in d['metrics']}=={'ci-memory/t'}
"; then ok "metrics JSON is benchdiff-shaped and plausible"; else fail "metrics JSON"; fi
"$root/mem-sampler/bin/mem-sampler" --out "$metrics" --label t --interval 1 --no-summary --warn-avail-mb 99999999 -- true >"$tmp/log" 2>&1
assert_contains "low-headroom warning emitted" "$(cat "$tmp/log")" "::warning title=Low memory headroom (t)"
"$root/mem-sampler/bin/mem-sampler" --label t -- true >/dev/null 2>&1; assert_eq "missing --out is a usage error" "$?" "2"

# --- jvm-diagnostics-upload/collect.sh ------------------------------------------------------
ws="$tmp/ws"; mkdir -p "$ws/mod/build/reports/tests" "$ws/node_modules/x"
echo crash > "$ws/hs_err_pid123.log"; echo r > "$ws/mod/build/reports/tests/index.html"
head -c 2097152 /dev/zero > "$ws/big.hprof"; echo small > "$ws/small.hprof"; echo ignored > "$ws/node_modules/x/hs_err_pid9.log"
out=$(SEARCH_DIRS="$ws" MAX_FILE_MB=1 OUT_DIR="$tmp/collected" GITHUB_OUTPUT="$tmp/go" bash "$root/jvm-diagnostics-upload/collect.sh")
assert_contains "collects hs_err" "$out" "hs_err_pid123.log"
assert_contains "collects small hprof" "$out" "small.hprof | 1 KB | collected"
assert_contains "skips oversized hprof" "$out" "big.hprof | 2 MB | skipped"
assert_contains "collects gradle reports" "$out" "build/reports/tests/index.html"
if printf '%s' "$out" | grep -q "node_modules"; then fail "prunes node_modules"; else ok "prunes node_modules"; fi
assert_eq "count output" "$(sed -n 's/^count=//p' "$tmp/go")" "3"
SEARCH_DIRS="$tmp/empty" OUT_DIR="$tmp/c2" GITHUB_OUTPUT="$tmp/go2" bash "$root/jvm-diagnostics-upload/collect.sh" >/dev/null
assert_eq "empty search -> count 0 and exit 0" "$(sed -n 's/^count=//p' "$tmp/go2")" "0"

# --- bazel-profile ---------------------------------------------------------------------------
fakebin="$tmp/bin"; mkdir -p "$fakebin"
cat > "$fakebin/bazel" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = help ]; then
  echo "  --[no]experimental_collect_resource_estimation (a boolean; default: \"false\")"
  echo "  --[no]experimental_collect_load_average_in_profiler (a boolean; default: \"true\")"
fi
EOF
chmod +x "$fakebin/bazel"
mkdir -p "$tmp/home"; out=$(HOME="$tmp/home" BAZEL="$fakebin/bazel" PROFILE_DIR="$tmp/prof" BAZELRC_MODE=user GITHUB_OUTPUT="$tmp/bo" bash "$root/bazel-profile/setup.sh")
assert_contains "profile flag written" "$out" "build --profile=$tmp/prof/command.profile.gz"
assert_contains "known collect flag written" "$out" "build --experimental_collect_resource_estimation"
if printf '%s' "$out" | grep -q pressure_stall; then fail "unknown flags are omitted"; else ok "unknown flags are omitted"; fi
assert_contains "user bazelrc updated" "$(cat "$tmp/home/.bazelrc")" "build --memory_profile="
out=$(PROFILE_PATH="$tmp/nope.gz" bash "$root/bazel-profile/summarize.sh")
assert_contains "missing profile is a notice, not a failure" "$out" "::notice title=bazel-profile"

# --- mem-sampler /proc fallback (containers without procps) ----------------------------------
MEM_SAMPLER_FORCE_PROC=1 "$root/mem-sampler/bin/mem-sampler" --out "$tmp/proc.json" --label proc --interval 1 --no-summary -- sleep 2 >"$tmp/proclog" 2>&1
assert_eq "proc fallback exit status" "$?" "0"
assert_contains "proc fallback logs [mem]" "$(cat "$tmp/proclog")" "[mem] used="
assert_contains "proc fallback logs processes" "$(cat "$tmp/proclog")" "[mem-top]"
assert_contains "proc fallback writes metrics" "$(cat "$tmp/proc.json")" '"name":"peak_used"'

# --- go-diagnostics-upload/summarize.py: real go test -json with gctrace via -exec ------------
if command -v go >/dev/null 2>&1; then
  gomod="$tmp/gomod"; mkdir -p "$gomod"
  printf 'module example.com/probe\n\ngo 1.21\n' > "$gomod/go.mod"
  cat > "$gomod/alloc_test.go" <<'EOF'
package probe

import "testing"

var sink [][]byte

func TestAlloc(t *testing.T) {
	for i := 0; i < 200; i++ {
		sink = append(sink, make([]byte, 1<<20))
	}
	sink = nil
}
EOF
  (cd "$gomod" && go test -json -exec "env GODEBUG=gctrace=1" ./... > "$tmp/go.json" 2>/dev/null)
  gosum=$(python3 -I "$root/go-diagnostics-upload/summarize.py" "$tmp/go.json" 5)
  assert_contains "go summary lists the package" "$gosum" "example.com/probe"
  assert_contains "go summary lists the slowest test" "$gosum" "TestAlloc"
  assert_contains "go summary has gctrace table" "$gosum" "GC pressure per package"
fi
printf '{"Action":"pass","Package":"p","Elapsed":1.5}\nnot json\n' > "$tmp/mini.json"
assert_contains "malformed lines are skipped" "$(python3 -I "$root/go-diagnostics-upload/summarize.py" "$tmp/mini.json")" "| p | 1.5 | ok |"

# --- setup-buf / setup-protoc ----------------------------------------------------------------
url_of() { # ACTION ENVVAR VERSION OS ARCH -> download URL
  env "$2=$3" DRY_RUN=1 UNAME_S="$4" UNAME_M="$5" bash "$root/$1/setup.sh" 2>&1
}
assert_eq "buf linux amd64" "$(url_of setup-buf BUF_VERSION v1.50.0 Linux x86_64)" "https://github.com/bufbuild/buf/releases/download/v1.50.0/buf-Linux-x86_64"
assert_eq "buf linux arm64 (uname says aarch64)" "$(url_of setup-buf BUF_VERSION 1.50.0 Linux aarch64)" "https://github.com/bufbuild/buf/releases/download/v1.50.0/buf-Linux-aarch64"
assert_eq "buf mac arm64" "$(url_of setup-buf BUF_VERSION 1.50.0 Darwin arm64)" "https://github.com/bufbuild/buf/releases/download/v1.50.0/buf-Darwin-arm64"
assert_contains "buf rejects latest" "$(url_of setup-buf BUF_VERSION latest Linux x86_64)" "no 'latest'"
assert_contains "buf rejects unsupported platform" "$(url_of setup-buf BUF_VERSION 1.50.0 Linux riscv64)" "unsupported platform"
assert_eq "protoc linux amd64" "$(url_of setup-protoc PROTOC_VERSION 23.4 Linux x86_64)" "https://github.com/protocolbuffers/protobuf/releases/download/v23.4/protoc-23.4-linux-x86_64.zip"
assert_eq "protoc linux arm64" "$(url_of setup-protoc PROTOC_VERSION v23.4 Linux arm64)" "https://github.com/protocolbuffers/protobuf/releases/download/v23.4/protoc-23.4-linux-aarch_64.zip"
assert_eq "protoc mac arm64" "$(url_of setup-protoc PROTOC_VERSION 23.4 Darwin arm64)" "https://github.com/protocolbuffers/protobuf/releases/download/v23.4/protoc-23.4-osx-aarch_64.zip"
assert_contains "protoc rejects latest" "$(url_of setup-protoc PROTOC_VERSION latest Linux x86_64)" "no 'latest'"
for a in linux-x86_64 linux-aarch_64 osx-x86_64 osx-aarch_64; do
  assert_contains "protoc checksum recorded for $a" "$(cat "$root/setup-protoc/checksums.txt")" "protoc-23.4-$a.zip"
done

# --- setup-bazel / setup-git-cliff / checksum verification ----------------------------------------
assert_eq "bazelisk linux amd64" "$(url_of setup-bazel BAZELISK_VERSION 1.30.0 Linux x86_64)" "https://github.com/bazelbuild/bazelisk/releases/download/v1.30.0/bazelisk-linux-amd64"
assert_eq "bazelisk linux arm64" "$(url_of setup-bazel BAZELISK_VERSION v1.30.0 Linux aarch64)" "https://github.com/bazelbuild/bazelisk/releases/download/v1.30.0/bazelisk-linux-arm64"
assert_eq "bazelisk mac arm64" "$(url_of setup-bazel BAZELISK_VERSION 1.30.0 Darwin arm64)" "https://github.com/bazelbuild/bazelisk/releases/download/v1.30.0/bazelisk-darwin-arm64"
assert_contains "bazelisk rejects latest" "$(url_of setup-bazel BAZELISK_VERSION latest Linux x86_64)" "no 'latest'"
assert_contains "bazelisk rejects unsupported platform" "$(url_of setup-bazel BAZELISK_VERSION 1.30.0 Linux riscv64)" "unsupported platform"
for a in linux-amd64 linux-arm64 darwin-arm64; do
  assert_contains "bazelisk checksum recorded for $a" "$(cat "$root/setup-bazel/checksums.txt")" "bazelisk-$a"
done
assert_eq "git-cliff linux amd64" "$(url_of setup-git-cliff GIT_CLIFF_VERSION 2.14.2 Linux x86_64)" "https://github.com/orhun/git-cliff/releases/download/v2.14.2/git-cliff-2.14.2-x86_64-unknown-linux-gnu.tar.gz"
assert_eq "git-cliff mac arm64" "$(url_of setup-git-cliff GIT_CLIFF_VERSION v2.14.2 Darwin arm64)" "https://github.com/orhun/git-cliff/releases/download/v2.14.2/git-cliff-2.14.2-aarch64-apple-darwin.tar.gz"
assert_contains "git-cliff rejects latest" "$(url_of setup-git-cliff GIT_CLIFF_VERSION latest Linux x86_64)" "no 'latest'"
for t in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu aarch64-apple-darwin; do
  assert_contains "git-cliff checksum recorded for $t" "$(cat "$root/setup-git-cliff/checksums.txt")" "git-cliff-2.14.2-$t.tar.gz"
done

# A fake release served over file://: the install verifies, then installs; a wrong hash must fail and install nothing.
rel="$tmp/release"; mkdir -p "$rel"
printf '#!/bin/sh\necho fake-bazelisk\n' > "$rel/bazelisk-linux-amd64"
good=$(sha256sum "$rel/bazelisk-linux-amd64" | cut -d' ' -f1)
printf '%s  bazelisk-linux-amd64\n' "$good" > "$tmp/sums-good.txt"
printf '%s  bazelisk-linux-amd64\n' "$(printf 0%.0s {1..64})" > "$tmp/sums-bad.txt"
: > "$tmp/sums-empty.txt"
bz() { # SUMS_FILE [env...] -> output of setup-bazel against the fake release
  local sums=$1; shift
  env UNAME_S=Linux UNAME_M=x86_64 BAZELISK_VERSION=1.30.0 DOWNLOAD_BASE="file://$rel" CHECKSUMS_FILE="$sums" \
    RUNNER_TOOL_CACHE="$tmp/toolcache.$RANDOM" HOME="$tmp/home" GITHUB_OUTPUT="$tmp/bz.out" GITHUB_ENV="$tmp/bz.vars" \
    GITHUB_PATH="$tmp/bz.path" BAZELRC="$tmp/bz.bazelrc" "$@" bash "$root/setup-bazel/setup.sh" 2>&1
}
mkdir -p "$tmp/proj"; printf '# pinned\n7.4.1\n' > "$tmp/proj/.bazelversion"
out=$(bz "$tmp/sums-bad.txt") && rc=0 || rc=$?
assert_eq "bazelisk: a bad checksum fails" "$rc" "1"
assert_contains "bazelisk: the bad checksum message names the asset" "$out" "checksum mismatch for bazelisk-linux-amd64"
out=$(bz "$tmp/sums-empty.txt") && rc=0 || rc=$?
assert_eq "bazelisk: an unrecorded asset fails" "$rc" "1"
assert_contains "bazelisk: unrecorded asset message" "$out" "no recorded checksum"
assert_eq "bazelisk: nothing written to PATH after a failure" "$(cat "$tmp/bz.path" 2>/dev/null)" ""
out=$(bz "$tmp/sums-good.txt" WORKDIR="$tmp/proj" REMOTE_CACHE=http://127.0.0.1:9090/cache REMOTE_UPLOAD=false DISK_CACHE=true REPO_CACHE=true CACHE_ROOT="$tmp/cr") && rc=0 || rc=$?
assert_eq "bazelisk: a good checksum installs" "$rc" "0"
assert_contains "bazelisk: reports the bazel version" "$out" "Bazel 7.4.1"
assert_eq "bazelisk: USE_BAZEL_VERSION read from .bazelversion (comments skipped)" "$(cat "$tmp/bz.vars")" "USE_BAZEL_VERSION=7.4.1"
assert_eq "bazelisk: installed as bazel and runnable" "$("$(cat "$tmp/bz.path")/bazel")" "fake-bazelisk"
assert_eq "bazelisk: bazelrc has cache and remote lines" "$(tr '\n' '|' < "$tmp/bz.bazelrc")" "build --disk_cache=$tmp/cr/bazel-disk-cache|common --repository_cache=$tmp/cr/bazel-repository-cache|build --remote_cache=http://127.0.0.1:9090/cache|build --remote_upload_local_results=false|"
rm -f "$tmp/bz.vars"
bz "$tmp/sums-good.txt" BAZEL_VERSION=8.0.0 WORKDIR="$tmp/proj" >/dev/null
assert_eq "bazelisk: bazel-version input wins over .bazelversion" "$(cat "$tmp/bz.vars")" "USE_BAZEL_VERSION=8.0.0"
rm -f "$tmp/bz.vars"
bz "$tmp/sums-good.txt" WORKDIR="$tmp/nowhere" >/dev/null
assert_eq "bazelisk: no .bazelversion sets nothing" "$(cat "$tmp/bz.vars" 2>/dev/null)" ""
out=$(bz "$tmp/sums-good.txt" BAZEL_VERSION='1;rm -rf /') && rc=0 || rc=$?
assert_eq "bazelisk: an odd Bazel version is refused" "$rc" "1"

mkdir -p "$tmp/cliff-src/git-cliff-2.14.2" "$tmp/cliff-rel"
printf '#!/bin/sh\necho git-cliff 2.14.2\n' > "$tmp/cliff-src/git-cliff-2.14.2/git-cliff"; chmod +x "$tmp/cliff-src/git-cliff-2.14.2/git-cliff"
tar -czf "$tmp/cliff-rel/git-cliff-2.14.2-x86_64-unknown-linux-gnu.tar.gz" -C "$tmp/cliff-src" git-cliff-2.14.2
printf '%s  git-cliff-2.14.2-x86_64-unknown-linux-gnu.tar.gz\n' "$(sha256sum "$tmp/cliff-rel/git-cliff-2.14.2-x86_64-unknown-linux-gnu.tar.gz" | cut -d' ' -f1)" > "$tmp/cliff-good.txt"
printf '%s  git-cliff-2.14.2-x86_64-unknown-linux-gnu.tar.gz\n' "$(printf 1%.0s {1..64})" > "$tmp/cliff-bad.txt"
cl() { env UNAME_S=Linux UNAME_M=x86_64 GIT_CLIFF_VERSION=2.14.2 DOWNLOAD_BASE="file://$tmp/cliff-rel" CHECKSUMS_FILE="$1" RUNNER_TOOL_CACHE="$tmp/cliff-tc.$RANDOM" GITHUB_OUTPUT="$tmp/cl.out" GITHUB_PATH="$tmp/cl.path" bash "$root/setup-git-cliff/setup.sh" 2>&1; }
out=$(cl "$tmp/cliff-bad.txt") && rc=0 || rc=$?
assert_eq "git-cliff: a bad checksum fails" "$rc" "1"
assert_contains "git-cliff: mismatch message" "$out" "checksum mismatch"
out=$(cl "$tmp/cliff-good.txt") && rc=0 || rc=$?
assert_eq "git-cliff: a good checksum installs" "$rc" "0"
assert_contains "git-cliff: runs after install" "$out" "git-cliff 2.14.2"

# --- bazel-rust-package ----------------------------------------------------------------------
pk="$root/bazel-rust-package/package.sh"
mkdir -p "$tmp/fakeb" "$tmp/exec/bazel-out/bin/crates/cli" "$tmp/ws-pkg"
cat > "$tmp/fakeb/bazel" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$tmp/bazel.log"
case "\$1" in
  cquery) echo "bazel-out/bin/crates/cli/dunnage" ;;
  info) echo "$tmp/exec" ;;
esac
EOF
chmod +x "$tmp/fakeb/bazel"
printf 'binary-bytes' > "$tmp/exec/bazel-out/bin/crates/cli/dunnage"
printf '# readme\n' > "$tmp/ws-pkg/README.md"; printf 'MIT\n' > "$tmp/ws-pkg/LICENSE-MIT"; printf 'note\n' > "$tmp/ws-pkg/NOTES.txt"
pkg() { env BAZEL="$tmp/fakeb/bazel" TARGET=//crates/cli:dunnage BINARY_NAME=dunnage TARGET_TRIPLE=aarch64-apple-darwin VERSION=v1.2.3 \
  SOURCE_DIR="$tmp/ws-pkg" OUTPUT_DIR="$tmp/dist" GITHUB_OUTPUT="$tmp/pkg.out" "$@" bash "$pk" 2>&1; }
: > "$tmp/bazel.log"; : > "$tmp/pkg.out"
out=$(pkg CONFIGS="release  opt" BAZEL_ARGS=$'--stamp\n--compilation_mode=opt' EXTRA_FILES="$tmp/ws-pkg/NOTES.txt") && rc=0 || rc=$?
assert_eq "package: succeeds" "$rc" "0"
arch="$tmp/dist/dunnage-1.2.3-aarch64-apple-darwin.tar.gz"
assert_eq "package: archive named <name>-<version>-<triple>.tar.gz (v stripped)" "$([ -f "$arch" ] && echo yes)" "yes"
assert_eq "package: build, cquery and info get the same flags" "$(tr '\n' '|' < "$tmp/bazel.log")" "build --config=release --config=opt --stamp --compilation_mode=opt -- //crates/cli:dunnage|cquery --config=release --config=opt --stamp --compilation_mode=opt --output=files -- //crates/cli:dunnage|info --config=release --config=opt --stamp --compilation_mode=opt execution_root|"
listing=$(tar -tzf "$arch" | LC_ALL=C sort | tr '\n' ' ')
assert_eq "package: one top-level dir with binary, README, LICENSE and extras" "$listing" "dunnage-1.2.3-aarch64-apple-darwin/ dunnage-1.2.3-aarch64-apple-darwin/LICENSE-MIT dunnage-1.2.3-aarch64-apple-darwin/NOTES.txt dunnage-1.2.3-aarch64-apple-darwin/README.md dunnage-1.2.3-aarch64-apple-darwin/dunnage "
x="$tmp/extract"; mkdir -p "$x"; tar -xzf "$arch" -C "$x"
xbin="$x/dunnage-1.2.3-aarch64-apple-darwin/dunnage"
assert_eq "package: binary content and mode" "$(cat "$xbin")$([ -x "$xbin" ] && echo ' +x')" "binary-bytes +x"
assert_eq "package: .sha256 verifies with sha256sum -c" "$(cd "$tmp/dist" && sha256sum -c dunnage-1.2.3-aarch64-apple-darwin.tar.gz.sha256 2>&1)" "dunnage-1.2.3-aarch64-apple-darwin.tar.gz: OK"
assert_eq "package: sha256 output matches the file" "$(sed -n 's/^sha256=//p' "$tmp/pkg.out")" "$(sha256sum "$arch" | cut -d' ' -f1)"
assert_contains "package: archive-path output" "$(cat "$tmp/pkg.out")" "archive-path=$tmp/dist/dunnage-1.2.3-aarch64-apple-darwin.tar.gz"
out=$(pkg VERSION=latest) && rc=0 || rc=$?
assert_eq "package: non-semver version fails" "$rc" "1"
out=$(pkg TARGET='crates/cli:dunnage') && rc=0 || rc=$?
assert_contains "package: bad label fails" "$out" "not a Bazel label"
out=$(pkg TARGET_TRIPLE='x86 64') && rc=0 || rc=$?
assert_contains "package: bad triple fails" "$out" "not a target triple"
out=$(pkg BINARY_NAME='../evil') && rc=0 || rc=$?
assert_contains "package: bad binary name fails" "$out" "unsupported characters"
out=$(pkg BINARY_PATH="$tmp/nope") && rc=0 || rc=$?
assert_contains "package: missing binary fails" "$out" "does not exist"
: > "$tmp/bazel.log"
out=$(pkg BINARY_PATH="$tmp/exec/bazel-out/bin/crates/cli/dunnage" VERSION=2.0.0-rc.1) && rc=0 || rc=$?
assert_eq "package: binary-path skips bazel entirely" "$(cat "$tmp/bazel.log")" ""
assert_eq "package: prerelease version is accepted" "$([ -f "$tmp/dist/dunnage-2.0.0-rc.1-aarch64-apple-darwin.tar.gz" ] && echo yes)" "yes"

# --- generate-homebrew-formula ---------------------------------------------------------------
gen="$root/generate-homebrew-formula/generate.py"
sums_url=https://github.com/tstapler/dunnage/releases/download/v0.1.0
gen_env=(NAME=dunnage VERSION=v0.1.0 DESC="Find and clean up disk space safely" HOMEPAGE=https://github.com/tstapler/dunnage LICENSE_ID="MIT OR Apache-2.0")
archives_lines="aarch64-apple-darwin $sums_url/dunnage-0.1.0-aarch64-apple-darwin.tar.gz 1111111111111111111111111111111111111111111111111111111111111111
x86_64-unknown-linux-gnu $sums_url/dunnage-0.1.0-x86_64-unknown-linux-gnu.tar.gz 2222222222222222222222222222222222222222222222222222222222222222
aarch64-unknown-linux-gnu $sums_url/dunnage-0.1.0-aarch64-unknown-linux-gnu.tar.gz 3333333333333333333333333333333333333333333333333333333333333333"
env "${gen_env[@]}" OUTPUT="$tmp/f1.rb" ARCHIVES="$archives_lines" python3 -I "$gen" >/dev/null
if diff -u "$root/test/golden/dunnage.rb" "$tmp/f1.rb" >"$tmp/f1.diff"; then ok "formula: matches the golden file"; else fail "formula: matches the golden file" "$(head -20 "$tmp/f1.diff")"; fi
printf '%s  dunnage-0.1.0-aarch64-apple-darwin.tar.gz\n%s  dunnage-0.1.0-x86_64-unknown-linux-gnu.tar.gz\n%s  dunnage-0.1.0-aarch64-unknown-linux-gnu.tar.gz\n%s  unrelated-9.9.9-x86_64-unknown-linux-gnu.tar.gz\n' \
  "$(printf 1%.0s {1..64})" "$(printf 2%.0s {1..64})" "$(printf 3%.0s {1..64})" "$(printf 4%.0s {1..64})" > "$tmp/SHA256SUMS"
env "${gen_env[@]}" OUTPUT="$tmp/f2.rb" SUMS_FILE="$tmp/SHA256SUMS" URL_BASE="$sums_url/" python3 -I "$gen" >/dev/null
if diff -q "$root/test/golden/dunnage.rb" "$tmp/f2.rb" >/dev/null; then ok "formula: SHA256SUMS + url-base gives the same formula"; else fail "formula: SHA256SUMS + url-base gives the same formula"; fi
if command -v ruby >/dev/null 2>&1; then
  if ruby -c "$root/test/golden/dunnage.rb" >/dev/null 2>&1; then ok "formula: golden file is valid Ruby"; else fail "formula: golden file is valid Ruby"; fi
fi
assert_contains "formula: macOS arm-only gets depends_on arch" "$(cat "$tmp/f1.rb")" "depends_on arch: :arm64"
assert_contains "formula: install block" "$(cat "$tmp/f1.rb")" 'bin.install "dunnage"'
assert_contains "formula: test runs --version" "$(cat "$tmp/f1.rb")" 'shell_output("#{bin}/dunnage --version")'
gen_err() { env "${gen_env[@]}" OUTPUT="$tmp/f3.rb" "$@" python3 -I "$gen" 2>&1; }
assert_contains "formula: unsupported triple fails" "$(gen_err ARCHIVES="riscv64-unknown-linux-gnu $sums_url/x.tar.gz $(printf 1%.0s {1..64})")" "unsupported target triple"
assert_contains "formula: http URL fails" "$(gen_err ARCHIVES="aarch64-apple-darwin http://x/y.tar.gz $(printf 1%.0s {1..64})")" "must be https://"
assert_contains "formula: short sha fails" "$(gen_err ARCHIVES="aarch64-apple-darwin $sums_url/y.tar.gz abc")" "64 lowercase hex"
assert_contains "formula: no archives fails" "$(gen_err ARCHIVES="")" "no archives"
assert_contains "formula: bad name fails" "$(gen_err NAME=Bad_Name ARCHIVES="$archives_lines")" "must be lowercase"
env "${gen_env[@]}" NAME=my-cool_tool VERSION=1.0.0-rc.1 DESC='say "hi" #{x}' LICENSE_ID=MIT OUTPUT="$tmp/f4.rb" ARCHIVES="x86_64-unknown-linux-gnu $sums_url/my-cool_tool-1.0.0-rc.1-x86_64-unknown-linux-gnu.tar.gz $(printf a%.0s {1..64})" python3 -I "$gen" >/dev/null
assert_contains "formula: class name is CamelCase of the name" "$(cat "$tmp/f4.rb")" "class MyCoolTool < Formula"
assert_contains "formula: strings are escaped for Ruby" "$(cat "$tmp/f4.rb")" 'desc "say \"hi\" \#{x}"'
assert_contains "formula: prerelease keeps an explicit version" "$(cat "$tmp/f4.rb")" 'version "1.0.0-rc.1"'
assert_contains "formula: linux intel-only gets depends_on arch" "$(cat "$tmp/f4.rb")" "depends_on arch: :x86_64"
if command -v ruby >/dev/null 2>&1; then
  if ruby -c "$tmp/f4.rb" >/dev/null 2>&1; then ok "formula: escaped formula is valid Ruby"; else fail "formula: escaped formula is valid Ruby"; fi
fi

# --- publish-homebrew-formula ----------------------------------------------------------------
pub="$root/publish-homebrew-formula"
mkrepo() { # NAME -> bare repo with an initial commit on main under $tmp/remotes/OWNER/NAME.git
  local bare="$tmp/remotes/o/$1.git" seed="$tmp/seed-$1"
  git init -q --bare -b main "$bare"
  git clone -q "$bare" "$seed" 2>/dev/null
  (cd "$seed" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init && git push -q origin HEAD:main)
}
publish() { # extra env as KEY=VAL...; uses FILES/REPOSITORIES from caller env
  # No global git identity or config, like a runner: this is what exposed the rebase-needs-identity bug.
  env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null URL_BASE="file://$tmp/remotes" COMMIT_MESSAGE="update x" "$@" bash "$pub/publish.sh" 2>&1
}
tapfile() { git -C "$tmp/remotes/o/$1.git" show "main:$2" 2>/dev/null; }

mkrepo tap1; mkrepo tap2
mkdir -p "$tmp/work/Formula" && cd "$tmp/work" || exit 1
printf 'class Tool\n  version "1"\nend\n' > Formula/tool.rb
printf 'cask "tool"\n' > tool-cask.rb
out=$(publish FILES=$'Formula/tool.rb:Formula/tool.rb\ntool-cask.rb:Casks/tool.rb' REPOSITORIES=$'o/tap1\no/tap2')
assert_contains "publishes to the first tap" "$out" "o/tap1: published"
assert_contains "publishes to the second tap" "$out" "o/tap2: published"
assert_eq "formula landed in tap1" "$(tapfile tap1 Formula/tool.rb | head -2 | tail -1)" '  version "1"'
assert_eq "cask landed in a subdirectory of tap2" "$(tapfile tap2 Casks/tool.rb)" 'cask "tool"'

out=$(publish FILES=Formula/tool.rb:Formula/tool.rb REPOSITORIES=o/tap1)
assert_contains "unchanged file makes no commit" "$out" "already up to date"
assert_eq "tap1 history has just init + one publish" "$(git -C "$tmp/remotes/o/tap1.git" rev-list --count main)" "2"

printf 'class Tool\n  version "2"\nend\n' > Formula/tool.rb
publish FILES=Formula/tool.rb:Formula/tool.rb REPOSITORIES=o/tap1 >/dev/null
assert_eq "update replaces the file" "$(tapfile tap1 Formula/tool.rb | sed -n 2p)" '  version "2"'

# a competing publisher pushes between our clone and our push: the retry must rebase and win
mkrepo racy
racer="$tmp/racer"; git clone -q "$tmp/remotes/o/racy.git" "$racer" 2>/dev/null
hook="$tmp/remotes/o/racy.git/hooks/pre-receive"
printf '#!/bin/sh\nrm -f "%s"\nunset GIT_DIR GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES\ncd "%s" && echo other > other.txt && git add other.txt && git -c user.name=o -c user.email=o@o commit -q -m other && git push -q origin HEAD:main --no-verify 2>/dev/null\nexit 1\n' "$hook" "$racer" > "$hook"
chmod +x "$hook"
out=$(publish FILES=Formula/tool.rb:Formula/tool.rb REPOSITORIES=o/racy)
assert_contains "lost race is retried" "$out" "o/racy: published"
assert_eq "both the racer's file and ours are on main" "$(tapfile racy other.txt)$(tapfile racy Formula/tool.rb | sed -n 2p)" 'other  version "2"'

out=$(publish FILES=missing.rb:Formula/x.rb REPOSITORIES=o/tap1) || true
assert_contains "missing source file is an error" "$out" "does not exist"
out=$(publish FILES=Formula/tool.rb:../escape.rb REPOSITORIES=o/tap1) || true
assert_contains "DEST with .. is rejected" "$out" "without '..'"
out=$(publish FILES=Formula/tool.rb:Formula/tool.rb REPOSITORIES=o/nonexistent) || true
assert_contains "uncloneable repo is an error" "$out" "cannot clone o/nonexistent"
out=$(TOKEN="" env -u TOKEN URL_BASE=https://github.com COMMIT_MESSAGE=x FILES=Formula/tool.rb:Formula/tool.rb REPOSITORIES=o/tap1 bash "$pub/publish.sh" 2>&1) || true
assert_contains "no token over https fails with guidance" "$out" "no token"

pr() { REPOSITORIES="$1" GITHUB_OUTPUT="$tmp/ghout.$RANDOM" bash "$pub/parse-repositories.sh" 2>&1; }
assert_contains "parse rejects mixed owners" "$(pr $'a/x\nb/y')" "share one owner"
assert_contains "parse rejects junk" "$(pr 'not a repo')" "not owner/name"
o="$tmp/ghout.parse"; REPOSITORIES=$'tstapler/homebrew-tap@main\ntstapler/other' GITHUB_OUTPUT="$o" bash "$pub/parse-repositories.sh"
assert_eq "parse strips branches and lists names" "$(tr '\n' ' ' < "$o")" "owner=tstapler names<<EOF homebrew-tap other EOF "
cd "$root" || exit 1

echo
echo "$passes passed, $fails failed"
[ "$fails" -eq 0 ]
