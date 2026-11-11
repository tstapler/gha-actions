#!/usr/bin/env python3
"""Render a Homebrew formula for prebuilt release archives.

Environment:
  NAME         formula name, e.g. dunnage                                  (required)
  VERSION      release version, leading v optional                         (required)
  DESC         one-line description                                        (required)
  HOMEPAGE     homepage URL                                                (required)
  LICENSE_ID   SPDX license expression, e.g. MIT OR Apache-2.0             (required)
  ARCHIVES     lines of `TRIPLE URL SHA256`
  SUMS_FILE    sha256sum-style file (`HASH  FILE`); with URL_BASE it adds one archive per
               `<BINARY_NAME>-<VERSION>-<triple>.tar.gz` line
  URL_BASE     download directory URL used with SUMS_FILE
  BINARY_NAME  executable to install (default NAME)
  CLASS_NAME   Ruby class name (default: NAME in CamelCase, as Homebrew derives it)
  OUTPUT       file to write (default NAME.rb)
  TEST_ARGS    arguments for the test block (default --version)
Stdlib only. Writes the formula path to GITHUB_OUTPUT as `formula-path`.
"""
import os
import re
import sys

# triple -> (on_macos|on_linux, on_arm|on_intel)
PLATFORMS = {
    "aarch64-apple-darwin": ("macos", "arm"),
    "x86_64-apple-darwin": ("macos", "intel"),
    "aarch64-unknown-linux-gnu": ("linux", "arm"),
    "aarch64-unknown-linux-musl": ("linux", "arm"),
    "x86_64-unknown-linux-gnu": ("linux", "intel"),
    "x86_64-unknown-linux-musl": ("linux", "intel"),
}
DEPENDS_ARCH = {"arm": ":arm64", "intel": ":x86_64"}


def die(msg):
    print(f"generate-homebrew-formula: {msg}", file=sys.stderr)
    sys.exit(1)


def rb(s):
    """Ruby double-quoted string literal."""
    if "\n" in s or "\r" in s:
        die("values must be single-line")
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("#{", "\\#{") + '"'


def license_literal(expr):
    """Homebrew spells SPDX OR/AND as any_of/all_of, not as a string."""
    has_or, has_and = " OR " in expr, " AND " in expr
    if has_or and has_and:
        die("license mixes OR and AND; write it as one level or edit the formula")
    if has_or or has_and:
        ids = [x.strip() for x in re.split(r" (?:OR|AND) ", expr)]
        if not all(re.fullmatch(r"[A-Za-z0-9.+-]+", i) for i in ids):
            die(f"license '{expr}' is not a plain SPDX OR/AND list")
        return f"{'any_of' if has_or else 'all_of'}: [{', '.join(rb(i) for i in ids)}]"
    return rb(expr)


def class_name(name):
    return "".join(p[:1].upper() + p[1:] for p in re.split(r"[-_.]", name) if p)


def read_archives(env, version, binary):
    found = {}
    for line in env.get("ARCHIVES", "").splitlines():
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) != 3:
            die(f"archive line '{line}' is not 'TRIPLE URL SHA256'")
        found[parts[0]] = (parts[1], parts[2])
    sums = env.get("SUMS_FILE", "")
    if sums:
        base = env.get("URL_BASE", "").rstrip("/")
        if not base:
            die("SUMS_FILE needs URL_BASE")
        with open(sums, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"^([0-9a-fA-F]{64})\s+\*?(\S+)$", line.strip())
                if not m:
                    continue
                f = m.group(2)
                prefix = f"{binary}-{version}-"
                if f.startswith(prefix) and f.endswith(".tar.gz"):
                    found.setdefault(f[len(prefix):-len(".tar.gz")], (f"{base}/{f}", m.group(1).lower()))
    return found


def render(env):
    def need(k):
        v = env.get(k, "").strip()
        if not v:
            die(f"{k} is required")
        return v

    name = need("NAME")
    version = need("VERSION").lstrip("v")
    desc, homepage, lic = need("DESC"), need("HOMEPAGE"), need("LICENSE_ID")
    binary = env.get("BINARY_NAME", "").strip() or name
    klass = env.get("CLASS_NAME", "").strip() or class_name(name)
    test_args = env.get("TEST_ARGS", "").strip() or "--version"
    if not re.fullmatch(r"[a-z0-9][a-z0-9@._+-]*", name):
        die(f"formula name '{name}' must be lowercase letters, digits and - _ . + @")
    if not re.fullmatch(r"[A-Z][A-Za-z0-9]*", klass):
        die(f"class name '{klass}' is not a valid Ruby constant")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", binary):
        die(f"binary name '{binary}' has unsupported characters")

    archives = read_archives(env, version, binary)
    if not archives:
        die("no archives: give ARCHIVES lines or SUMS_FILE with URL_BASE")
    grouped = {"macos": {}, "linux": {}}
    for triple, (url, sha) in sorted(archives.items()):
        if triple not in PLATFORMS:
            die(f"unsupported target triple '{triple}' (supported: {', '.join(sorted(PLATFORMS))})")
        if not url.startswith("https://"):
            die(f"URL for {triple} must be https://")
        if not re.fullmatch(r"[0-9a-f]{64}", sha):
            die(f"sha256 for {triple} is not 64 lowercase hex characters")
        os_name, cpu = PLATFORMS[triple]
        if cpu in grouped[os_name]:
            die(f"two archives for {os_name}/{cpu}")
        grouped[os_name][cpu] = (url, sha)

    out = [
        f"class {klass} < Formula",
        f"  desc {rb(desc)}",
        f"  homepage {rb(homepage)}",
        f"  license {license_literal(lic)}",
    ]
    # Homebrew scans a plain x.y.z out of `<name>-x.y.z-<triple>.tar.gz` and `brew audit` calls an
    # explicit `version` redundant then; keep it only where the scan could get it wrong.
    scannable = re.fullmatch(r"\d+\.\d+\.\d+", version) and all(
        f"-{version}-" in u.rsplit("/", 1)[-1] for u, _ in archives.values()
    )
    if not scannable:
        out.insert(3, f"  version {rb(version)}")
    for os_name in ("macos", "linux"):
        cpus = grouped[os_name]
        if not cpus:
            continue
        out += ["", f"  on_{os_name} do"]
        if len(cpus) == 1:
            # Without this a Homebrew on the other CPU loads a formula with no url.
            out.append(f"    depends_on arch: {DEPENDS_ARCH[next(iter(cpus))]}")
        for cpu in ("arm", "intel"):
            if cpu in cpus:
                url, sha = cpus[cpu]
                out += [f"    on_{cpu} do", f"      url {rb(url)}", f"      sha256 {rb(sha)}", "    end"]
        out.append("  end")
    out += [
        "",
        "  def install",
        f"    bin.install {rb(binary)}",
        "  end",
        "",
        "  test do",
        f'    assert_match version.to_s, shell_output("#{{bin}}/{binary} {test_args}")',
        "  end",
        "end",
        "",
    ]
    return name, "\n".join(out)


def main():
    env = dict(os.environ)
    name, text = render(env)
    path = env.get("OUTPUT", "").strip() or f"{name}.rb"
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    gh = env.get("GITHUB_OUTPUT")
    if gh:
        with open(gh, "a", encoding="utf-8") as fh:
            fh.write(f"formula-path={path}\n")
    print(f"generate-homebrew-formula: wrote {path}")


if __name__ == "__main__":
    main()
