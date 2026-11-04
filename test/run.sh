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

echo
echo "$passes passed, $fails failed"
[ "$fails" -eq 0 ]
