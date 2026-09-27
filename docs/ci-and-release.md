# CI and release

## Linting

`shellcheck` cannot read `action.yml`, so the shell scripts embedded in a
composite action are normally checked by nothing at all. `scripts/lint-steps.py`
closes that gap:

1. loads the action file as YAML, which also proves it parses;
2. extracts each composite step's `run` body;
3. replaces every `${{ ... }}` expression with `$(:)`, a command substitution that
   expands to nothing and is valid wherever a value can appear, so the script
   parses without pretending the expression had a particular value;
4. writes each body to a temporary file with a `#!/usr/bin/env bash` shebang,
   always with LF endings, and runs `shellcheck` over it.

It also checks standalone shell files passed with `--shell-file`.

Run it locally:

```sh
pip install pyyaml
python scripts/lint-steps.py action.yml --shell-file scripts/lib.sh
```

It fails if `shellcheck` reports anything, at any severity. Findings are fixed
rather than silenced. The only suppression in the repository is `SC1091` on the
`source "$GITHUB_ACTION_PATH/scripts/lib.sh"` lines, with a comment: the path is
only known at run time, so shellcheck cannot follow it.

## CI workflow

`.github/workflows/ci.yml` runs on pushes to `main` and on pull requests:

- every file in `action.yml`, `.github/workflows/` and `examples/` must parse as
  YAML;
- `scripts/lint-steps.py` must pass over `action.yml` and `scripts/lib.sh`.

## Testing the step logic locally

The pure-shell logic is testable without a runner. Source the library and call
the functions directly:

```sh
source scripts/lib.sh
sanitize_name_component 'fix.'      # fix
sanitize_name_component '_wip'      # wip
sanitize_tag '2026-05-09.a464688'   # unchanged
require_boolean push yes            # fails, message on stderr
```

A whole step can be run in isolation by setting the environment variables listed
in its `env:` block plus `GITHUB_ACTION_PATH`, `GITHUB_OUTPUT`, `GITHUB_ENV` and
`RUNNER_TEMP`, and executing the `run` body. Putting a stub `docker` earlier on
`PATH` that records its argv is how the build step's command assembly is checked
without building anything: that is what proves no build arg value and no secret
reaches the command line.

## Releasing

Versions are tagged `vX.Y.Z`. Callers pin the major alias:

```yaml
uses: relybytes/actions-docker-build-push@v1
```

Pushing a `vX.Y.Z` tag triggers `.github/workflows/release.yml`, which force-moves
the `vX` and `vX.Y` annotated tags to that commit. It needs
`permissions: contents: write`, and it refuses a tag that is not exactly
`vX.Y.Z`.

Because `v1` moves, a change that is not backwards compatible for the six calling
workflows needs a new major tag, not a new patch.

## Pinning third-party actions

The action uses `docker/setup-buildx-action@v4` and, opt-in,
`docker/setup-qemu-action@v4`. The workflows use `actions/checkout@v7` and
`actions/setup-python@v6`. Check that a tag exists before pinning it:

```sh
gh api repos/docker/setup-buildx-action/tags --jq '.[].name' | head
```
