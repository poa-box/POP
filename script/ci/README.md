# Contract coverage

Normal tests and production builds use the compiler pinned in `foundry.toml`.
Coverage needs a separate compiler adapter: Forge disables viaIR by default,
while its `--ir-minimum` preset fails to compile `AccessFactory` with a Yul stack
error. `coverage_solc.py` restores the passing default profile's unoptimized IR
settings (`viaIR=true`, optimizer disabled, 200 runs). It does not change sources,
output selection, linking, EVM version or production builds.

After Forge has installed Solc, set `POA_COVERAGE_SOLC` to its **native Solc 0.8.33
executable**, then run:

```bash
export POA_COVERAGE_SOLC="/absolute/path/to/solc-0.8.33"
python3 -B -m unittest discover -s script/ci -p 'test_*.py' -v
FOUNDRY_PROFILE=default forge coverage --ir-minimum \
  --use ./script/ci/coverage_solc.py \
  --report summary --report lcov --report-file lcov.info
```

Common compiler locations are `~/.svm/0.8.33/solc-0.8.33`,
`~/.local/share/svm/0.8.33/solc-0.8.33` on Linux, and
`~/Library/Application Support/svm/0.8.33/solc-0.8.33` on macOS.
The adapter rejects other compiler versions and propagates compiler failures.
CI also requires a nonempty LCOV report with source line records and a parsed
summary; an empty report or failed compilation cannot pass the job.

Foundry's viaIR source-mapping warning still applies: coverage is useful for
finding untested paths, but individual line and branch attribution can be imprecise.
