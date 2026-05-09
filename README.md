# Build & Push to Registry

Build a Docker image and push it to **any container registry** using a fixed naming convention:

```text
{registry}/{image_name}-{suffix}:YYYY-MM-DD.shortsha
```

When no credentials are passed, the action defaults to **GitHub Container Registry** (`ghcr.io`) and authenticates using the current GitHub actor and `GITHUB_TOKEN`.

This means a zero-config build for the current repository works out of the box, as long as the workflow grants the required package permissions.

The environment marker is appended as a **suffix on the image repository**, not as a prefix on the tag. This means each environment gets its own image repository with clean tags such as `:latest`.

The `suffix` is automatically derived from the current Git ref, branch, tag, or pull request, and can be overridden together with `image_name`, `version`, registry credentials, and other build options.

## Naming convention

- **Image repository**: `{base_name}-{suffix}`, for example `relybytes/myapp-prod`
- **Tag**: `YYYY-MM-DD.shortsha`, using UTC date and the first 7 characters of `github.sha`
- **Full image**: `{registry}/{base_name}-{suffix}:{tag}`

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

Pass `suffix: none` to disable the suffix entirely.

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

## Usage

### Default — push to GHCR for the current repository

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
        uses: actions/checkout@v4

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

| Input             | Required | Default                        | Description                                                                                   |
| ----------------- | -------- | ------------------------------ | --------------------------------------------------------------------------------------------- |
| `registry`        | no       | `ghcr.io`                      | Container registry host, for example `ghcr.io`, `docker.io`, or `registry.example.com`        |
| `username`        | no       | `${{ github.actor }}`          | Registry username                                                                             |
| `password`        | no       | `${{ github.token }}`          | Registry password or access token                                                             |
| `image_name`      | no       | Current repository, lowercased | Base image name. The suffix is appended as `-{suffix}`                                        |
| `dockerfile`      | no       | `Dockerfile`                   | Path to the Dockerfile. Can be relative to the repository root or to the build context        |
| `context`         | no       | `.`                            | Build context directory                                                                       |
| `suffix`          | no       | Derived from ref               | Override the suffix. Use `none` to disable it                                                 |
| `version`         | no       | Auto-generated                 | Override the tag and skip `YYYY-MM-DD.shortsha` generation                                    |
| `platforms`       | no       | `linux/amd64`                  | Comma-separated target platforms                                                              |
| `build_args`      | no       | empty                          | Newline-separated build args, using `KEY=VALUE`                                               |
| `target`          | no       | empty                          | Target build stage for multi-stage Dockerfiles                                                |
| `labels`          | no       | OCI auto-labels                | Newline-separated OCI labels. When provided, they replace the auto-generated labels           |
| `push`            | no       | `true`                         | Push the image to the registry. Set to `false` for local validation builds                    |
| `push_on_pr`      | no       | `false`                        | Allow pushing images on pull request events                                                   |
| `additional_tags` | no       | empty                          | Comma-separated additional tags on the suffixed image repository                              |
| `latest`          | no       | `auto`                         | `true`, `false`, or `auto`. `auto` enables `:latest` only on `main` or `master` non-PR builds |
| `cache`           | no       | `true`                         | Enable BuildKit inline cache                                                                  |
| `no_cache`        | no       | `false`                        | Disable build cache entirely                                                                  |

## Outputs

| Output             | Description                                                        |
| ------------------ | ------------------------------------------------------------------ |
| `image`            | Full image reference, for example `registry/name-suffix:version`   |
| `image_repository` | Repository portion without tag, for example `registry/name-suffix` |
| `version`          | Resolved tag, either `YYYY-MM-DD.shortsha` or the custom override  |
| `suffix`           | Resolved environment suffix                                        |
| `branch`           | Branch used to derive the suffix                                   |
| `tags`             | All tags applied, newline-separated                                |
| `digest`           | Image digest after push, when available                            |
| `build_time`       | UTC timestamp of the build                                         |

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

### PR build without push

```yaml
name: Validate Docker build

on:
  pull_request:

jobs:
  validate:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Validate Docker build
        uses: relybytes/actions-docker-build-push@v1
        with:
          push: "false"
```

Pull request builds do not push images by default.

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

When `push=false`, the action uses `--load`.

For this reason, `push=false` supports only a single platform. Multi-platform builds require `push=true`.

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
        uses: actions/checkout@v4

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

## Security notes

- Do not hardcode registry credentials in workflow files.
- Store credentials in GitHub Secrets.
- Prefer pull-only or push-only robot accounts when your registry supports them.
- Pull request events do not push images by default.
- Use `push_on_pr: "true"` only when you fully trust the workflow context.

## Notes

- Image names are forced to lowercase because GHCR rejects uppercase names and lowercase names are safer across registries.
- Custom image names are sanitized while preserving `/`, so paths such as `team/myapp` are supported.
- Docker tags generated from versions, Git tags, and additional tags are sanitized.
- Each environment gets its own image repository, for example `myapp-prod`, `myapp-dev`, or `myapp-pr-42`.
- This keeps `:latest` clean and allows per-environment retention or visibility rules on registries that support them.
- The `org.opencontainers.image.source`, `org.opencontainers.image.revision`, `org.opencontainers.image.created`, and `org.opencontainers.image.version` labels are added automatically when `labels` is empty.
- Pass custom `labels` to override the auto-generated OCI labels.
- `latest=auto` publishes `:latest` only on `main` or `master` non-PR builds.
- `digest` is available only when `push=true` and the registry returns an inspectable manifest digest.

## License

MIT
