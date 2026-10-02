# Build & Push to Registry

Build a Docker image and push it to **any container registry** using a fixed naming convention:

```text
{registry}/{image_name}-{suffix}:YYYY-MM-DD.shortsha
```

When no credentials are passed, the action defaults to **GitHub Container Registry** (`ghcr.io`) and authenticates using the current GitHub actor and `GITHUB_TOKEN`.

This means a zero-config build for the current repository works out of the box, as long as the workflow grants the required package permissions.

The environment marker is appended as a **suffix on the image repository**, not as a prefix on the tag. This means each environment gets its own image repository with clean tags such as `:latest`.

The `suffix` is automatically derived from the current Git ref, branch, tag, or pull request, and can be overridden together with `image_name`, `version`, registry credentials, and other build options.

The action is designed to run unchanged on GitHub-hosted runners and on persistent self-hosted runners shared by several repositories. See [Runner requirements](#runner-requirements) and [Behaviour on shared runners](#behaviour-on-shared-runners).

## Naming convention

- **Image repository**: `{base_name}-{suffix}`, for example `relybytes/myapp-prod`
- **Tag**: `YYYY-MM-DD.shortsha`, using the UTC date and the first 7 characters of the commit being built
- **Full image**: `{registry}/{base_name}-{suffix}:{tag}`

The commit in the tag is `github.sha` on every event except pull requests. On `pull_request` and `pull_request_target` it is `github.event.pull_request.head.sha`, the head commit of the pull request, because `github.sha` there is an ephemeral merge commit that does not exist in the repository and could never be checked out again. The same commit is used for the `org.opencontainers.image.revision` label.

Examples:

```text
ghcr.io/relybytes/myapp-prod:2026-05-09.a464688
registry.example.com/team/myapp-dev:2026-05-09.a464688
docker.io/relybytes/myapp-pr-42:2026-05-09.a464688
```

## Default suffix mapping

| Source ref / event | Suffix                |
| ------------------ | --------------------- |
| `main`, `master`   | `prod`                |
| `develop`, `dev`   | `dev`                 |
| `staging`          | `staging`             |
| `release/*`        | `rc`                  |
| `hotfix/*`         | `hotfix`              |
| `feature/*`        | `feat`                |
| Pull request       | `pr-{number}`         |
| Git tag push       | `release`             |
| Other branch       | Sanitized branch name |

Override the suffix with the `suffix` input when the default does not fit your workflow.

Example:

```yaml
suffix: canary
```

Pass `suffix: none` to disable the suffix entirely. The comparison is case-insensitive and ignores surrounding whitespace, so `None` and `" none "` work too.

## Extra tags published automatically

All extra tags are published on the same suffixed image repository.

The action can publish:

- the generated version tag, always;
- `:latest`, depending on the `latest` input;
- the Git tag itself, on tag push events;
- custom tags passed through `additional_tags`.

By default, `latest=auto` publishes `:latest` only on `main` or `master` non-PR builds.

Example on `main`:

```text
ghcr.io/relybytes/myapp-prod:2026-05-09.a464688
ghcr.io/relybytes/myapp-prod:latest
```

The `:latest` alias is only ever **pushed**. A build that is loaded into the local Docker daemon instead of being pushed gets the version tag only, because `:latest` is a fixed name in a daemon that may be shared with other jobs.

## Runner requirements

### GitHub-hosted runners (`ubuntu-latest`)

Everything the action needs is already there. Nothing to install, no `sudo` required.

- Docker and the `buildx` plugin: preinstalled.
- Multi-platform builds: `binfmt` is already registered, so `linux/arm64` works out of the box.
- Build cache: works out of the box, see [Build cache](#build-cache).

### Self-hosted runners

The action checks all of this at the start of the job and fails immediately, naming what is missing, rather than failing later with a confusing error.

Must be present on the machine:

- The `docker` CLI on `PATH`, and a Docker daemon the runner user can talk to **without `sudo`** (usually by adding the runner user to the `docker` group). The action never calls `sudo` and never writes to a machine-wide location.
- The `docker buildx` plugin. The action builds with BuildKit and does not fall back to the legacy builder.
- `RUNNER_TEMP` set, which the runner does by itself. It is where the per-run Docker configuration directory goes.
- For a multi-platform build: QEMU `binfmt` handlers registered on the host, or `setup_qemu: "true"` (see below).

Handled by the action itself, with nothing to configure:

- A per-run `DOCKER_CONFIG` directory, so `docker login` never touches the shared `~/.docker/config.json`.
- A buildx builder created and named for this run, passed explicitly with `--builder` to every buildx command, and removed at the end.
- Reading the address of the Actions cache service from the runner, with a clean fallback where the runner provides none.
- Detection of the platforms the builder can actually build, with an explicit error when emulation is missing.

### Multi-platform builds and QEMU

Building for an architecture other than the runner's needs QEMU `binfmt` handlers registered on the host. `binfmt` registration is **host-wide state**: on a self-hosted runner shared between repositories, every other job on the machine sees it. For that reason this action does not register it behind your back.

What it does instead: after setting up buildx it asks the builder which platforms it supports, and if a requested platform is not among them it fails with the real cause, instead of letting the build die inside the first `RUN` with a bare `exec format error`.

You have two ways to make multi-arch work on a self-hosted runner:

1. Register `binfmt` once on the host, outside CI, which is the recommended option:

   ```sh
   docker run --privileged --rm tonistiigi/binfmt --install all
   ```

2. Let the action do it per job, with `setup_qemu: "true"`. This runs `docker/setup-qemu-action`, which needs a privileged container and changes state shared with other jobs on the machine.

On GitHub-hosted runners neither is needed.

## Build cache

`cache: "true"` (the default) imports and exports a BuildKit cache through the **GitHub Actions cache service**:

```text
--cache-from type=gha,scope={scope},{service address}
--cache-to   type=gha,mode=max,ignore-error=true,scope={scope},{service address}
```

`mode=max` caches the layers of every build stage, not only those of the final image. A cache problem never fails a build: `ignore-error=true` turns a failed export into a log line, and BuildKit treats a failed import as an empty cache and builds cold.

`no_cache: "true"` passes `--no-cache` and skips cache import and export entirely. `cache: "false"` builds without importing or exporting anything.

### What the action reads from the runner, and why

The runner gives the address of the cache service, and the job token for it, to JavaScript actions only. This action is a composite action whose build runs in a shell step, which never sees them. When the cache is in use, the action therefore runs one small `actions/github-script` step, pinned by commit, that reads these variables:

| Variable                   | What it carries                                                                                           |
| -------------------------- | --------------------------------------------------------------------------------------------------------- |
| `ACTIONS_RUNTIME_TOKEN`    | The job token for the cache service. The runner registers it as a secret, so the log shows it as `***`    |
| `ACTIONS_RESULTS_URL`      | The address of the current cache service, v2                                                              |
| `ACTIONS_CACHE_SERVICE_V2` | Set where the repository uses cache service v2, which is every repository on github.com                  |
| `ACTIONS_CACHE_URL`        | The address of the legacy cache service, v1, which GitHub Enterprise Server still uses                    |
| `ACTIONS_CACHE_MODE`       | The `cache-mode` of the job: `read`, `write`, `write-only` or `none`                                      |

It hands them to the build step as step outputs, and that is the whole exposure:

- They reach the build step and nothing else. They are **not** exported to the job environment, so the later steps of your job do not see them, and nothing is left behind when the action ends.
- The step prints the names of the variables it found, never a value.
- The token never reaches a command line: buildx reads it from its own environment. Only the service address and protocol version go on the command line, as cache attributes.

The address is passed explicitly, as `url`, `url_v2` and `version=2`, instead of being left for buildx to find, because buildx older than 0.21 reads only the legacy `ACTIONS_CACHE_URL` and silently drops the cache when that is missing. With the explicit attributes the cache also works on self-hosted runners with an older Docker installation, such as buildx 0.12: the builder container always runs a current BuildKit, which speaks cache service v2.

The `cache-mode` of the job is honoured the way `actions/cache` honours it: `read` imports only, `write-only` exports only, and `none` builds without the cache. The cache service enforces the mode in any case; honouring it saves an export that would be refused.

### Cache scope

Each image gets a scope of its own, `{image name}-{hash}`, for example:

```text
relybytes-public-website-06c7710e623e
```

The hash covers the repository, the registry, the image name, an explicit `suffix`, the Dockerfile path, the build context, the target and the platforms. That means:

- **Two images never share a scope**, even in the same repository or the same job. A shared scope would make each export replace the cache index of the other image, and the next build would miss.
- **The suffix derived from the branch is not part of the scope.** GitHub keeps cache entries per branch anyway, and BuildKit imports the index of the current branch and also of the base and the default branch. A pull request or a new branch therefore starts from the cache of `main` instead of from nothing, and never overwrites it.
- **An explicit `suffix` is part of the scope**, because two variants of one image built from the same branch would otherwise overwrite each other.

Set `cache_scope` to choose the scope yourself: to share one cache between two image names built from the same Dockerfile, or to keep apart two builds of the same image that differ only in `build_args`. The value is used as given, except that anything other than letters, digits, `.`, `_` and `-` becomes `-`.

### When the cache still cannot help

In each of these cases the build runs cold, or partly cold, and still succeeds:

- **The runner provides no cache service**, for example GitHub Enterprise Server with the Actions cache turned off, or a local runner such as `act`. The action says so in a notice that starts with *Build cache is unavailable*.
- **The builder cannot reach the service.** BuildKit talks to `results-receiver.actions.githubusercontent.com` and to the cache storage on `*.blob.core.windows.net` from inside the builder container. A self-hosted runner behind a firewall must allow both. A firewall that silently drops the traffic makes the build wait for the cache timeout first, so set `cache: "false"` on such a runner.
- **The job may only read the cache.** Runs of events that someone without write access can trigger, such as `pull_request_target` or `issue_comment`, get read-only access to the cache of the default branch, and `cache-mode: read` does the same on purpose. The cache is imported, nothing new is exported.
- **The cache was evicted.** A repository holds 10 GB of cache by default. Entries not used for 7 days are deleted, and when the limit is reached the least recently used go first. `mode=max` stores every intermediate layer, so a large multi-stage image fills it quickly.
- **There is nothing to start from.** The first build on the default branch is cold, and a branch never reads the cache of a sibling branch or of another tag.
- **A build arg changes on every run**, such as a token, a timestamp or the commit SHA. Every Dockerfile step after the `ARG` that declares it gets a new cache key and rebuilds. Declare such an `ARG` as late as possible in the Dockerfile.
- **The service throttles the export.** A repository can create up to 200 cache entries a minute and each exported layer is one entry. An export cut short is logged and ignored.

The cache can also work and still not pay off. With `mode=max` every new layer is compressed and uploaded on every build, including the layers of build stages that never reach the image. A stage that writes gigabytes on every commit, such as a site build that prerenders thousands of pages, can cost more to export than the cache saves on the steps before it. Compare the duration of the build step over two or three builds with the cache, and set `cache: "false"` where the export does not pay for itself.

## Usage

### Default, push to GHCR for the current repository

```yaml
name: Build and Push

on:
  push:
    branches:
      - main

permissions:
  contents: read
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v7

      - name: Build and push Docker image
        uses: relybytes/actions-docker-build-push@v1
```

A push to `main` produces:

```text
ghcr.io/<owner>/<repo>-prod:2026-05-09.a464688
ghcr.io/<owner>/<repo>-prod:latest
```

## Push to a different registry

```yaml
- name: Build and push Docker image
  uses: relybytes/actions-docker-build-push@v1
  with:
    registry: registry.example.com
    username: ${{ secrets.REGISTRY_USER }}
    password: ${{ secrets.REGISTRY_PASS }}
    image_name: team/myapp
```

Produces:

```text
registry.example.com/team/myapp-prod:2026-05-09.a464688
```

Pass the host in `registry` and only the path in `image_name`. An `image_name` that starts with something Docker reads as a registry host, such as `ghcr.io/org/app`, is rejected with a message saying what to pass instead, because it would otherwise produce `ghcr.io/ghcr.io/org/app-prod`.

## Push to Docker Hub

```yaml
- name: Build and push Docker image
  uses: relybytes/actions-docker-build-push@v1
  with:
    registry: docker.io
    username: ${{ secrets.DOCKERHUB_USER }}
    password: ${{ secrets.DOCKERHUB_TOKEN }}
    image_name: relybytes/myapp
```

Produces:

```text
docker.io/relybytes/myapp-prod:2026-05-09.a464688
```

## Inputs

Boolean inputs accept only `true` or `false`, case-insensitively and ignoring surrounding whitespace. Anything else fails the build with a clear error instead of being silently read as the default.

| Input             | Required | Default                        | Description                                                                                                             |
| ----------------- | -------- | ------------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| `registry`        | no       | `ghcr.io`                      | Container registry host, for example `ghcr.io`, `docker.io`, or `registry.example.com`                                   |
| `username`        | no       | `${{ github.actor }}`          | Registry username                                                                                                       |
| `password`        | no       | `${{ github.token }}`          | Registry password or access token. Masked by the action even when derived from a previous step                           |
| `image_name`      | no       | Current repository, lowercased | Base image name, without registry host. The suffix is appended as `-{suffix}`                                            |
| `dockerfile`      | no       | `Dockerfile`                   | Path to the Dockerfile. Can be relative to the repository root or to the build context                                  |
| `context`         | no       | `.`                            | Build context directory                                                                                                 |
| `suffix`          | no       | Derived from ref               | Override the suffix. Use `none` to disable it                                                                           |
| `version`         | no       | Auto-generated                 | Override the tag and skip `YYYY-MM-DD.shortsha` generation                                                              |
| `platforms`       | no       | `linux/amd64`                  | Comma-separated target platforms. See [Multi-platform builds and QEMU](#multi-platform-builds-and-qemu)                  |
| `build_args`      | no       | empty                          | Newline-separated build args, `KEY=VALUE`. Values are passed through the environment, never on the command line          |
| `target`          | no       | empty                          | Target build stage for multi-stage Dockerfiles                                                                          |
| `labels`          | no       | OCI auto-labels                | Newline-separated OCI labels. When provided, they replace the auto-generated labels                                     |
| `push`            | no       | `true`                         | Push the image to the registry. `true` or `false`                                                                       |
| `push_on_pr`      | no       | `false`                        | Allow pushing images on pull request events. `true` or `false`                                                           |
| `additional_tags` | no       | empty                          | Comma-separated additional tags on the suffixed image repository                                                         |
| `latest`          | no       | `auto`                         | `true`, `false`, or `auto`. `auto` enables `:latest` only on `main` or `master` non-PR builds                            |
| `cache`           | no       | `true`                         | Import and export the GitHub Actions build cache. `true` or `false`. See [Build cache](#build-cache)                     |
| `no_cache`        | no       | `false`                        | Disable the build cache entirely. `true` or `false`                                                                      |
| `cache_scope`     | no       | One per image                  | Scope of the GitHub Actions build cache. See [Cache scope](#cache-scope)                                                 |
| `load`            | no       | `auto`                         | Load the image into the local Docker daemon when it is not pushed. `auto`, `true`, or `false`. See [Build without push](#build-without-push) |
| `setup_qemu`      | no       | `false`                        | Register QEMU binfmt handlers for this job. `true` or `false`. Off by default because binfmt is host-wide state          |

## Outputs

| Output             | Description                                                                          |
| ------------------ | ------------------------------------------------------------------------------------ |
| `image`            | Full image reference, for example `registry/name-suffix:version`                     |
| `image_repository` | Repository portion without tag, for example `registry/name-suffix`                   |
| `version`          | Resolved tag, either `YYYY-MM-DD.shortsha` or the custom override                    |
| `suffix`           | Resolved environment suffix                                                          |
| `branch`           | Branch used to derive the suffix                                                     |
| `tags`             | All tags actually applied, newline-separated                                         |
| `digest`           | Image digest after push, when the registry returns it                                |
| `build_time`       | UTC timestamp of the build                                                           |

When the digest cannot be read, the underlying error from `docker buildx imagetools inspect` is printed and a warning explains that the image was pushed but the `digest` output is empty. A digest problem never fails the build.

## Examples

### Multi-arch build with build args

```yaml
- name: Build and push Docker image
  uses: relybytes/actions-docker-build-push@v1
  with:
    platforms: linux/amd64,linux/arm64
    build_args: |
      NODE_ENV=production
      VERSION=${{ github.ref_name }}
```

On a self-hosted runner, add `setup_qemu: "true"` unless `binfmt` is already registered on the host.

### Custom suffix

```yaml
- name: Build and push Docker image
  uses: relybytes/actions-docker-build-push@v1
  with:
    suffix: canary
```

Produces:

```text
ghcr.io/<owner>/<repo>-canary:2026-05-09.a464688
```

### Disable suffix

```yaml
- name: Build and push Docker image
  uses: relybytes/actions-docker-build-push@v1
  with:
    suffix: none
```

Produces:

```text
ghcr.io/<owner>/<repo>:2026-05-09.a464688
```

### Override the image name

```yaml
- name: Build and push Docker image
  uses: relybytes/actions-docker-build-push@v1
  with:
    image_name: platform/myapp
```

Produces:

```text
ghcr.io/platform/myapp-prod:2026-05-09.a464688
```

### Override the image name with a private registry

```yaml
- name: Build and push Docker image
  uses: relybytes/actions-docker-build-push@v1
  with:
    registry: registry.example.com
    username: ${{ secrets.REGISTRY_USER }}
    password: ${{ secrets.REGISTRY_PASS }}
    image_name: platform/myapp
```

Produces:

```text
registry.example.com/platform/myapp-prod:2026-05-09.a464688
```

### Custom version tag

```yaml
- name: Build and push Docker image
  uses: relybytes/actions-docker-build-push@v1
  with:
    version: v1.0.0
```

Produces:

```text
ghcr.io/<owner>/<repo>-prod:v1.0.0
```

### Additional tags

```yaml
- name: Build and push Docker image
  uses: relybytes/actions-docker-build-push@v1
  with:
    additional_tags: stable,production
```

On `main`, this can publish:

```text
ghcr.io/<owner>/<repo>-prod:2026-05-09.a464688
ghcr.io/<owner>/<repo>-prod:latest
ghcr.io/<owner>/<repo>-prod:stable
ghcr.io/<owner>/<repo>-prod:production
```

### PR validation build, including multi-arch

```yaml
name: Validate Docker build

on:
  pull_request:

jobs:
  validate:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v7

      - name: Validate Docker build
        uses: relybytes/actions-docker-build-push@v1
        with:
          push: "false"
          platforms: linux/amd64,linux/arm64
```

Pull request builds do not push images by default: `push` is forced to `false` and a warning says so.

A validation build for several platforms works. When nothing is pushed and there is more than one platform, the action builds with no exporter at all: a broken Dockerfile still fails the job, which is the whole point, and no local image is needed to prove the build works.

To explicitly allow push on pull request events:

```yaml
- name: Build and push Docker image
  uses: relybytes/actions-docker-build-push@v1
  with:
    push_on_pr: "true"
```

Use this carefully, especially with external contributors or forked repositories.

### Build without push

```yaml
- name: Build Docker image locally
  uses: relybytes/actions-docker-build-push@v1
  with:
    push: "false"
```

With `load: "auto"`, the default, a single-platform build that is not pushed is loaded into the local Docker daemon with `--load`, so a later step in the same job can run it. The `:latest` alias is not loaded.

The `load` input controls this:

| `load`  | Behaviour                                                                                                   |
| ------- | ----------------------------------------------------------------------------------------------------------- |
| `auto`  | Load when the image is not pushed and there is a single platform. This is the historical behaviour           |
| `false` | Never load. Use it on a shared runner when no later step needs the image locally                             |
| `true`  | Always load when not pushing. Refused for more than one platform, because the local image store cannot hold a multi-platform image |

### Custom Dockerfile and context

```yaml
- name: Build and push frontend image
  uses: relybytes/actions-docker-build-push@v1
  with:
    context: ./frontend
    dockerfile: Dockerfile
```

Or:

```yaml
- name: Build and push image
  uses: relybytes/actions-docker-build-push@v1
  with:
    context: .
    dockerfile: docker/Dockerfile
```

### Pipe into a deploy step

```yaml
jobs:
  release:
    runs-on: ubuntu-latest

    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout
        uses: actions/checkout@v7

      - name: Build and push
        id: image
        uses: relybytes/actions-docker-build-push@v1

      - name: Deploy to Kubernetes
        uses: relybytes/actions-kubernetes-deploy@v1
        with:
          kubeconfig: ${{ secrets.KUBECONFIG_B64 }}
          namespace: production
          manifests: ./k8s
          replacements: |
            __IMAGE__=${{ steps.image.outputs.image }}
          wait: "true"
          wait_timeout: "300s"
```

## Permissions

To push to `ghcr.io` with the default `GITHUB_TOKEN`, the workflow must declare:

```yaml
permissions:
  contents: read
  packages: write
```

For cross-repository or organization-level pushes, use a Personal Access Token with package write permissions and pass it through the `password` input.

For external registries such as Docker Hub, Harbor, OVHcloud Managed Private Registry, AWS ECR, or private registries, use the credentials provided by the registry.

## Behaviour on shared runners

A persistent self-hosted runner can run jobs from several repositories at the same time, as the same user, sharing `$HOME`, the process table and one Docker daemon. The action is built for that:

- **No global login state.** Every run gets its own `DOCKER_CONFIG` directory with a unique name under `$RUNNER_TEMP`, created with mode `700`. `docker login` writes the credential there, not into the shared `~/.docker/config.json`, and cleanup deletes that directory instead of running a global `docker logout` that would revoke another job's credential mid-push.
- **No reliance on the current-builder marker.** The builder created for this run is passed explicitly with `--builder` to every buildx command, so another job's buildx setup cannot redirect this build into a container that is about to be removed.
- **Nothing with a fixed name or path.** The Docker configuration directory and the builder are unique per run. The `:latest` alias is never loaded into the shared daemon.
- **Cleanup only removes what this run created**, is safe to run twice, and is safe when the step that created the thing never ran. No images, containers or builders belonging to other jobs are touched.

## Security notes

- Do not hardcode registry credentials in workflow files. Store them in GitHub Secrets.
- The registry password is masked by the action itself, so it is redacted in the log even when the caller computed it in a previous step, which is how AWS ECR login tokens are usually obtained. It is handed to `docker login` on stdin, never as an argument.
- **Build arg values never appear on a command line.** They are exported into the step environment and only the key is passed as `--build-arg KEY`, because the process table is readable by every other job on a shared runner.
- **Build args are not a place for secrets.** Their values are recorded in the image configuration and can be read back from the pushed image by anyone who can pull it. Use BuildKit secret mounts in your Dockerfile for real secrets.
- **The cache token stays inside the action.** `ACTIONS_RUNTIME_TOKEN` goes from the step that reads it to the build step as a step output. It never enters the job environment, never reaches a command line and is never printed. See [Build cache](#build-cache).
- **Every third-party action this action runs is pinned to a full commit SHA**, so a moved tag cannot change what runs with your registry credentials.
- Prefer pull-only or push-only robot accounts when your registry supports them.
- Pull request events do not push images by default. Use `push_on_pr: "true"` only when you fully trust the workflow context.

### Residual risk this action cannot remove

On a self-hosted runner where all jobs run as the same operating system user and share one Docker daemon, concurrent jobs can read each other's process environment and each other's images, and any job can talk to the daemon as root-equivalent. The process environment includes build arg values and, while the build step runs, the token for the Actions cache. The per-run `DOCKER_CONFIG` narrows the window, but it cannot create isolation the machine does not have. If your jobs handle credentials of different trust levels, use ephemeral runners or one runner per repository; that is the only place where this can actually be fixed.

## Notes

- Image names are forced to lowercase because GHCR rejects uppercase names and lowercase names are safer across registries.
- Image names and suffixes are sanitized to satisfy the registry grammar for a repository name, `[a-z0-9]+((\.|_|__|-*)[a-z0-9]+)*` per path component: a separator is never left at either end and runs of separators are collapsed. Branch `fix.` gives `myrepo-fix` and branch `_wip` gives `myrepo-wip`, both valid. `/` is preserved, so paths such as `team/myapp` work.
- The image name is capped at the 255 characters a registry accepts, and tags at 128, so a long branch name cannot produce a reference the registry rejects.
- Docker tags generated from versions, Git tags, and additional tags are sanitized the same way.
- Each environment gets its own image repository, for example `myapp-prod`, `myapp-dev`, or `myapp-pr-42`.
- This keeps `:latest` clean and allows per-environment retention or visibility rules on registries that support them.
- The `org.opencontainers.image.source`, `org.opencontainers.image.revision`, `org.opencontainers.image.created`, and `org.opencontainers.image.version` labels are added automatically when `labels` is empty.
- Pass custom `labels` to override the auto-generated OCI labels.
- `latest=auto` publishes `:latest` only on `main` or `master` non-PR builds.
- `digest` is available only when `push=true` and the registry returns an inspectable manifest digest.

## Development

The composite steps and the shared shell library are linted in CI:

```sh
pip install pyyaml
python scripts/lint-steps.py action.yml --shell-file scripts/lib.sh
```

`scripts/lint-steps.py` loads `action.yml`, extracts each composite step's `run` body, replaces `${{ ... }}` expressions with a harmless placeholder, and runs `shellcheck` over the result. `scripts/lib.sh` holds every helper used by more than one step, so the sanitizers exist in exactly one place.

CI also checks that every action is pinned to a full commit SHA, and builds a small image twice on a hosted runner to prove that the second build comes from the GitHub Actions cache, once with the buildx of the runner image and once with buildx 0.12.1. See [CI and release](docs/ci-and-release.md).

Releases are tagged `vX.Y.Z`; a workflow then moves the `vX` and `vX.Y` alias tags to that commit.

## Documentation

Developer documentation lives in [`docs/`](docs/README.md).

## License

MIT
