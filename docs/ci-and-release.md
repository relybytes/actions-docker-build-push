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

`.github/workflows/ci.yml` runs on every push to a branch and on pull requests,
so a change to the action runs on a real runner before it reaches `main` and a
release tag. It has two jobs.

`lint`:

- every file in `action.yml`, `.github/workflows/` and `examples/` must parse as
  YAML;
- every `uses:` in `action.yml` and `.github/workflows/` must be a local path or
  a full commit SHA with its version in a trailing comment, see
  [Pinning third-party actions](#pinning-third-party-actions);
- `scripts/lint-steps.py` must pass over `action.yml` and `scripts/lib.sh`.

`cache` is a build cache round trip through the action itself (`uses: ./`) on a
hosted runner. Nothing is pushed to any registry; the images are loaded into the
Docker daemon of the runner.

1. Build image A from `tests/cache/Dockerfile`, cold.
2. Build image B, a second image, cold.
3. Build image A again.
4. Read a nonce from each image, and require the second build of A to carry the
   nonce of the first.

The slow step of the fixture sleeps 30 seconds and then writes a random nonce,
so a rebuild always writes a new one. Every run of the action creates its own
builder and removes it at the end, so the second build of A can only get that
layer from the GitHub Actions cache. Image B in between proves that two images
do not overwrite each other's cache index. The first build must take at least 30
seconds, which proves it ran the slow step. The images are named after the run
id, the attempt and the matrix leg, so legs and runs never share a cache scope
and never race on one index.

The job runs as a matrix of two legs: with the buildx of the runner image, and
with buildx 0.12.1, the version on the self-hosted runners that build the
company images. That one is downloaded from the buildx release, checked against
its SHA-256 and installed as the Docker CLI plugin. The step summary of each leg
lists the three nonces and how long each run of the action took.

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
reaches the command line. For the build cache, also set the variables the
`runtime` step would pass, see [Build cache](build-cache.md#testing).

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

Every action that `action.yml` and the workflows run is pinned to a full commit
SHA, with the release it belongs to in a trailing comment:

```yaml
uses: docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4.4.1
```

A tag can be moved to other code after review; a commit cannot. That matters
most in `action.yml`, which runs inside every calling job, next to its registry
credentials. The `lint` job fails on any reference that is not pinned this way.
The examples in the README and in `examples/` keep tags on purpose: they are
templates for calling repositories, and the check covers what this repository
runs.

To move a pin, resolve the release tag to its commit. For an annotated tag the
commit is the `^{}` line; a lightweight tag has only the first:

```sh
git ls-remote https://github.com/actions/github-script 'refs/tags/v9.0.0' 'refs/tags/v9.0.0^{}'
```

Change the SHA and the comment together. `actions/github-script` and the two
docker actions run on Node 24, which needs runner 2.327.1 or later.
