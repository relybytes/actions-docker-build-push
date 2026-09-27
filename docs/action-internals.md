# Action internals

What the composite action is made of, and why it is shaped this way. For inputs,
outputs and usage see the [top-level README](../README.md).

## The constraint that shaped everything

Every caller runs this action on persistent self-hosted runners where jobs from
different repositories execute **concurrently as the same operating system
user**, sharing `$HOME`, `/tmp`, the Docker daemon and the process table. Most
callers declare no concurrency group.

Three consequences run through the whole file:

1. Anything with a fixed name or a fixed path is shared with other jobs. The
   Docker configuration directory and the buildx builder are therefore unique
   per run, under `$RUNNER_TEMP`.
2. Anything on a command line is readable by any other job with `ps`. Secrets go
   in on stdin, build arg values go in through the environment.
3. Cleanup may only remove what this run created, must be safe to run twice, and
   must be safe when the step that created the thing never ran.

The same file must also work unchanged on an ephemeral `ubuntu-latest` runner,
so nothing may need `sudo` and nothing may write to a machine-wide location.

## Steps

| Step                        | id         | What it does                                                                                                   |
| --------------------------- | ---------- | -------------------------------------------------------------------------------------------------------------- |
| Check prerequisites, prepare | `prepare`  | Verifies docker, the daemon and the buildx plugin; masks the password; creates the per-run `DOCKER_CONFIG`       |
| Resolve image, version, push | `resolve`  | Validates the inputs, derives base name, suffix, tag and push policy                                            |
| Validate context             | `validate` | Checks the context and Dockerfile, normalizes the platform list, refuses only the impossible load combination   |
| Set up QEMU                  |            | Opt-in through `setup_qemu`, runs `docker/setup-qemu-action`                                                     |
| Set up Docker Buildx         | `buildx`   | Creates the builder for this run; its `name` output is what every later buildx call uses                        |
| Verify builder platforms     | `builder`  | Bootstraps the builder and compares the requested platforms with what it advertises                             |
| Login to registry            |            | Only when pushing. Writes into the per-run `DOCKER_CONFIG`                                                       |
| Build and push               | `build`    | Assembles the buildx command, exports build arg values, applies cache flags, reads the digest                    |
| Cleanup                      | `cleanup`  | `if: always()`. Removes the builder, then the configuration directory, then restores `DOCKER_CONFIG`             |

Steps communicate through step outputs only. Every output is written with
`set_output`, which uses a heredoc with a random delimiter: a plain `key=value`
echo corrupts `$GITHUB_OUTPUT` as soon as a value contains a newline, and the
runner reports that as an opaque "Unable to process file command".

### Ordering constraints

- `prepare` must run before `Set up Docker Buildx`, because it exports
  `DOCKER_CONFIG` and buildx keeps its builder metadata there. That is what stops
  the current-builder marker from being shared.
- `Verify builder platforms` must run after the builder exists, because the list
  of supported platforms comes from `docker buildx inspect --bootstrap`.
- `Cleanup` removes the builder itself rather than leaving it to the
  `setup-buildx-action` post hook, because the post hook runs after cleanup has
  already deleted the directory the builder is registered in and would leave a
  buildkit container running on the host.

## scripts/lib.sh

Each composite step runs in its own shell, so anything used by more than one
step lives in `scripts/lib.sh` and is loaded with:

```sh
source "$GITHUB_ACTION_PATH/scripts/lib.sh"
```

There used to be two inlined copies of `sanitize_tag` and they had already
drifted. One copy is the point of this file.

| Function                    | Purpose                                                                   |
| --------------------------- | ------------------------------------------------------------------------- |
| `trim`                      | Strip leading and trailing whitespace with parameter expansion            |
| `lowercase`, `normalize`    | Lowercase, and trim plus lowercase                                        |
| `random_hex`                | 128 bits of hex, for the output heredoc delimiter                         |
| `set_output`                | Write a step output through a heredoc                                     |
| `require_boolean`           | Normalize a boolean input, fail on anything else                          |
| `require_enum`              | Normalize an enumerated input, fail on anything else                      |
| `sanitize_name_component`   | One path component of a repository name, valid per the registry grammar   |
| `sanitize_repository_path`  | A full path, `/` preserved                                               |
| `cap_repository_name`       | Cap at 255 characters and repair the tail                                |
| `assert_repository_name`    | Last-defence grammar check                                               |
| `assert_no_registry_host`   | Reject an `image_name` that already carries a registry host              |
| `sanitize_tag`              | A Docker tag, capped at 128 characters                                   |

**Every function writes diagnostics to stderr.** They are called inside command
substitutions, where anything on stdout becomes the return value: an
`echo "::error::..."` there was captured as the value and the step died with
nothing in the log.

### Why `trim` is not `xargs`

`echo "$value" | xargs` was used as a trimmer in three places. It strips quotes,
eats backslashes, and exits 1 on a lone apostrophe, so a label as ordinary as
`org.opencontainers.image.vendor=Bob's Ltd` failed the build with an error about
xargs.

### The name grammar

A registry accepts a repository path component matching:

```text
[a-z0-9]+((\.|_|__|-*)[a-z0-9]+)*
```

A separator is therefore never valid at either end, and a run of mixed
separators is never valid anywhere. `sanitize_name_component` lowercases,
replaces anything outside the alphabet with `-`, collapses runs of two or more
separators into one `-`, and strips separators from both ends. A single `.` or
`_` between alphanumeric runs is left alone, so `v1.2` stays `v1.2`.

## Build arguments

`--build-arg KEY=VALUE` puts the value in argv. `--build-arg KEY` with no value
makes buildx read it from its own environment, so the build step validates the
key as a shell identifier, exports `KEY=VALUE`, and passes only the key.

This keeps the value out of the process table. It does **not** make it a secret:
build args are recorded in the image configuration and can be read back from the
pushed image. Real secrets belong in BuildKit secret mounts.

## Multi-architecture

Emulation needs QEMU `binfmt` handlers registered on the host, which is
host-wide state on a shared runner. The action does not register it implicitly;
it detects the gap and reports it. `setup_qemu: "true"` opts in.

The check is deliberately forgiving in one direction: if the platform list
cannot be parsed out of `docker buildx inspect`, it warns and proceeds rather
than blocking a build over a parsing problem.
