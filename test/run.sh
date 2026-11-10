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

# --- publish-homebrew-formula ----------------------------------------------------------------
pub="$root/publish-homebrew-formula"
mkrepo() { # NAME -> bare repo with an initial commit on main under $tmp/remotes/OWNER/NAME.git
  local bare="$tmp/remotes/o/$1.git" seed="$tmp/seed-$1"
  git init -q --bare -b main "$bare"
  git clone -q "$bare" "$seed" 2>/dev/null
  (cd "$seed" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init && git push -q origin HEAD:main)
}
publish() { # extra env as KEY=VAL...; uses FILES/REPOSITORIES from caller env
  env URL_BASE="file://$tmp/remotes" COMMIT_MESSAGE="update x" "$@" bash "$pub/publish.sh" 2>&1
}
tapfile() { git -C "$tmp/remotes/o/$1.git" show "main:$2" 2>/dev/null; }

mkrepo tap1; mkrepo tap2
mkdir -p "$tmp/work/Formula" && cd "$tmp/work"
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
cd "$root"

echo
echo "$passes passed, $fails failed"
[ "$fails" -eq 0 ]
