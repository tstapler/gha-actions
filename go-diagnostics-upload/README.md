# go-diagnostics-upload

`go test -memprofile` is rejected when more than one package is tested, so this action works from the JSON stream instead, which handles any number of packages.

```yaml
- run: >
    gotestsum --jsonfile "$RUNNER_TEMP/go-test.json" --junitfile "$RUNNER_TEMP/junit.xml"
    -- -race -exec "env GODEBUG=gctrace=1" ./...
- if: always()
  uses: tstapler/gha-actions/go-diagnostics-upload@v0
  with:
    json-file: ${{ runner.temp }}/go-test.json
    junit-file: ${{ runner.temp }}/junit.xml
```

The step summary lists the slowest packages and tests and, when gctrace lines are present, GC count and peak heap per package. `-exec "env GODEBUG=gctrace=1"` turns on gctrace for the test binaries only; setting `GODEBUG` in the environment would also trace the compiler and flood the output. Extra profiles (for example `-test.memprofile` from a single-package run) can be passed in `extra-paths`.

Inputs: `json-file`, `junit-file`, `extra-paths`, `name`, `top-n`, `retention-days`. A missing file is a notice, not a failure.
