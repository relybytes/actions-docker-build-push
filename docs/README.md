# Documentation index

The [top-level README](../README.md) is the contract for people **using** the
action: inputs, outputs, naming convention, runner requirements. These files
describe how it works **inside**, for people changing it.

- [Action internals](action-internals.md): the composite steps, what each one
  resolves, the shared shell library, and the constraints that shaped them.
- [Build cache](build-cache.md): how the build step reaches the GitHub Actions
  cache service, how the cache is scoped per image, and how that is tested.
- [CI and release](ci-and-release.md): how the action is linted and tested, how
  third-party actions are pinned, and how a version is released.
