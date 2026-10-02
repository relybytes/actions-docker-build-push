# Build cache

How the action reaches the GitHub Actions cache service, how it scopes the cache
per image, and how that is tested. For the user-facing contract see
[Build cache in the README](../README.md#build-cache).

## Why a JavaScript step is needed

The `type=gha` cache backend of BuildKit needs two things from the runner: the
job token for the cache service and the address of the service. The runner puts
them in the environment of **JavaScript actions only**. In `actions/runner`,
`NodeScriptActionHandler` sets `ACTIONS_RUNTIME_TOKEN`, `ACTIONS_CACHE_URL`,
`ACTIONS_RESULTS_URL`, `ACTIONS_CACHE_SERVICE_V2` and `ACTIONS_CACHE_MODE`;
`ScriptHandler`, which runs every `run:` step, sets none of them. The build step
of this composite action is a `run:` step, so it never had them and every build
ran cold.

## The `runtime` step

`Read the Actions cache service address` (`id: runtime`) runs
`actions/github-script`, pinned by commit, right before the build step, and only
when the `gha` backend is in use (`steps.resolve.outputs.gha_cache`, which means
`cache: true` and `no_cache: false`). It reads the five variables above and sets
one step output for each:

| Output        | Variable                   |
| ------------- | -------------------------- |
| `token`       | `ACTIONS_RUNTIME_TOKEN`    |
| `results_url` | `ACTIONS_RESULTS_URL`      |
| `cache_url`   | `ACTIONS_CACHE_URL`        |
| `service_v2`  | `ACTIONS_CACHE_SERVICE_V2` |
| `cache_mode`  | `ACTIONS_CACHE_MODE`       |

The build step maps those outputs back to the same variable names in its own
`env:` block. No other step receives them. The `runtime` step prints the names
of the variables it found, never a value.

The step has `continue-on-error: true`. If it fails, the build step finds no
address, prints the *Build cache is unavailable* notice and builds cold: a cache
problem never fails a build.

### Why step outputs and not the job environment

- **`GITHUB_ENV` is job-wide.** A variable written there reaches every later
  step of the calling job, third-party actions included, and cannot be removed
  again, only overwritten with an empty value. The runner also prints the job
  environment in the header of every later step.
- **Step outputs stay inside the action.** The outputs of the steps of a
  composite action are visible to the other steps of that action only, and they
  are gone when it ends. Only the build step lists them in its `env:`.
- **The token is masked either way.** When the job starts, the runner registers
  the authorization parameters of its service endpoints with its secret masker,
  so the header of the build step shows `ACTIONS_RUNTIME_TOKEN: ***`. The action
  never prints the value and never passes it through `::add-mask::`.

`crazy-max/ghaction-github-runtime`, the usual answer to this problem, was ruled
out: it prints every `ACTIONS_*` variable, the token included and hidden only by
the masker, and exports all of them into the job environment, the OIDC request
token among them.

## The build step

The build step first unsets each of the five variables that is empty, because
buildx tells an empty variable apart from a missing one. It then derives the
scope, see below, and calls `gha_cache_endpoint` from `scripts/lib.sh` to turn
the address into cache attributes:

| What the runner provided                                    | Attributes                                 |
| ----------------------------------------------------------- | ------------------------------------------ |
| `ACTIONS_CACHE_SERVICE_V2` true and `ACTIONS_RESULTS_URL`   | `version=2,url={results},url_v2={results}` |
| otherwise `ACTIONS_CACHE_URL`                               | `url={cache url}`                          |
| otherwise `ACTIONS_RESULTS_URL`                             | `url={results}`                            |
| no address, or no token                                     | none: notice, cold build                   |

An address with a comma, a quote or whitespace in it is refused with a warning,
because it would corrupt the comma-separated `--cache-from` value.

### Why the address is spelled out

buildx fills in `token` and `url` from the environment when they are missing,
and how it does that depends on its version:

- buildx 0.21 and later read `ACTIONS_CACHE_SERVICE_V2` and
  `ACTIONS_RESULTS_URL` and set `url_v2` themselves.
- buildx before 0.21, for example the **0.12.1** on the self-hosted runner that
  builds the website, reads only `ACTIONS_CACHE_URL`, never sets `url_v2`, and
  **silently drops** a `gha` entry that ends up without a `url`.

Both pass every other attribute to BuildKit unchanged. BuildKit picks the
protocol in its `getConfig`: unless `version` is `1`, a `url_v2` attribute
selects cache service v2. The builder container that
`docker/setup-buildx-action` creates runs `moby/buildkit:buildx-stable-1`, a
current BuildKit, so passing `version=2`, `url` and `url_v2` explicitly makes the
cache work whatever the buildx version on the host. `url` repeats the address of
`url_v2` only to keep old buildx from dropping the entry.

The token is never an attribute. buildx reads `ACTIONS_RUNTIME_TOKEN` from its
own environment and hands it to BuildKit over its API, never through argv.

### cache-mode

`ACTIONS_CACHE_MODE` holds the effective
[`cache-mode`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
of the job, `write` for an ordinary push. The cache service enforces it; the
action follows it the way the `@actions/cache` toolkit does, to avoid an export
the service would refuse:

| Mode                    | `--cache-from` | `--cache-to` |
| ----------------------- | -------------- | ------------ |
| `write`, unset, unknown | yes            | yes          |
| `read`                  | yes            | no           |
| `write-only`            | no             | yes          |
| `none`                  | no             | no           |

### Failures

- **Export**: `ignore-error=true` on `--cache-to` turns any export error into a
  log line.
- **Import**: BuildKit wraps every cache import in a lazy cache manager. When the
  import fails, the manager answers every query with no records, so the build
  runs cold and still succeeds. The log shows the error under
  `importing cache manifest from gha:...`.

## Cache scope

`derive_cache_scope` in `scripts/lib.sh` produces `{readable}-{hash}`:

- **readable**: the base image name with `/` turned into `-`, followed by the
  suffix when the caller passed one explicitly, capped at 100 characters;
- **hash**: the first 12 hex characters of the SHA-256 of these lines:
  `repository`, `registry` (lowercased, without a trailing `/`), `image` (the
  base name), `suffix` (the normalized `suffix` input, empty when derived),
  `dockerfile` (the resolved path), `context`, `target` and `platforms` (sorted,
  deduplicated, comma-separated).

Build args are left out on purpose. Their values can be secrets, and many of
them change on every run, which would give every run a new scope.

### What BuildKit does with the scope

BuildKit stores two kinds of entries in the cache service:

- `buildkit-blob-1-{digest}`: one per layer, shared by every scope;
- `index-{scope}-1-{hash of the GitHub ref}#{n}`: the cache index of one scope on
  one ref. Every export writes the next `#{n}`, and an import reads the newest.

On import BuildKit reads the index of every ref the job token can read: the
current branch, the base branch of a pull request and the default branch. That
is why the suffix derived from the branch is left out of the scope. With the
same scope on every branch, a pull request or a new branch finds the index of
`main` and starts warm, while its own exports land on its own ref and never
touch the index of `main`. An explicit suffix stays in, because two variants of
one image built on the same ref would otherwise take turns writing one index.

`cache_scope` replaces the derived scope. `sanitize_cache_scope` turns anything
other than letters, digits, `.`, `_` and `-` into `-`, trims separators at both
ends, caps the value at 200 characters, and fails the step when nothing is left.

## Checking a cache hit in a log

The build step of a run that reused the cache prints:

```text
Cache:           GitHub Actions cache, scope relybytes-public-website-06c7710e623e
Cache service:   version=2,url=https://results-receiver.actions.githubusercontent.com/,url_v2=...
#5 importing cache manifest from gha:...
```

A reused Dockerfile step then shows as `CACHED` with buildx 0.12, and with a
current buildx as a short blob download instead of the step running. The cache
entries of a repository are listed under Actions, Caches, or by
`gh cache list`.

## Testing

- **Real runners**: the `cache` job in `.github/workflows/ci.yml`, described in
  [CI and release](ci-and-release.md#ci-workflow), builds a small image twice
  and fails unless the second build reuses the slow step of the first.
- **Locally**: the build step runs in isolation with a stub `docker` first on
  `PATH`, as described in
  [CI and release](ci-and-release.md#testing-the-step-logic-locally). Setting
  `ACTIONS_RUNTIME_TOKEN`, `ACTIONS_RESULTS_URL`, `ACTIONS_CACHE_SERVICE_V2` and
  `ACTIONS_CACHE_MODE` in its environment exercises every row of the tables
  above, and the argv record of the stub shows that the token never reaches it.
