#!/usr/bin/env bash
# Shared shell helpers for the composite steps of this action.
#
# Every composite step runs in its own shell, so anything used by more than one
# step lives here and is loaded with:
#
#   source "$GITHUB_ACTION_PATH/scripts/lib.sh"
#
# Keeping a single copy is what stops two inlined copies of the same sanitizer
# from drifting apart, which is how one of them ended up printing errors that
# never reached the log.
#
# Diagnostics in this file always go to stderr. Most of these functions are
# called inside a command substitution, where anything written to stdout is
# captured as the return value instead of being shown to the user.

# Strip leading and trailing whitespace, including carriage returns.
#
# `xargs` is not a trimmer: it removes quotes, eats backslashes and exits 1 on a
# lone apostrophe, so a label as ordinary as
# `org.opencontainers.image.vendor=Bob's Ltd` used to fail the build with an
# error about xargs.
trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# Lowercase a value.
lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Trim and lowercase a value. Most inputs are compared this way so that
# `None` and ` none ` mean the same thing as `none`.
normalize() {
  lowercase "$(trim "$1")"
}

# Echo a hexadecimal string with 128 bits of entropy.
random_hex() {
  local hex=""

  if [[ -r /dev/urandom ]]; then
    hex="$(head -c 16 /dev/urandom | od -An -v -t x1 | tr -d ' \n')"
  fi

  if [[ -z "$hex" ]]; then
    hex="${RANDOM}${RANDOM}${RANDOM}${RANDOM}${RANDOM}"
  fi

  printf '%s' "$hex"
}

# Write a step output using a heredoc with a random delimiter.
#
# A plain `key=value` echo corrupts $GITHUB_OUTPUT as soon as the value
# contains a newline, and the runner reports that as an opaque
# "Unable to process file command 'output' successfully".
set_output() {
  local key="$1"
  local value="$2"
  local delimiter

  delimiter="ghadelimiter_$(random_hex)"

  {
    printf '%s<<%s\n' "$key" "$delimiter"
    printf '%s\n' "$value"
    printf '%s\n' "$delimiter"
  } >>"$GITHUB_OUTPUT"
}

# Normalize a boolean input and reject anything that is not a boolean.
#
# `push: "yes"` and `push: "1"` used to be read as "do not push", and any value
# other than true or false for `latest` silently fell through to `auto`.
require_boolean() {
  local name="$1"
  local raw="$2"
  local value

  value="$(normalize "$raw")"

  if [[ "$value" != "true" && "$value" != "false" ]]; then
    printf '::error::Input %s must be "true" or "false", got "%s"\n' "$name" "$raw" >&2
    return 1
  fi

  printf '%s' "$value"
}

# Normalize an enumerated input and reject anything outside the allowed set.
# Usage: require_enum NAME RAW_VALUE allowed...
require_enum() {
  local name="$1"
  local raw="$2"
  shift 2

  local value
  value="$(normalize "$raw")"

  local allowed
  for allowed in "$@"; do
    if [[ "$value" == "$allowed" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done

  printf '::error::Input %s must be one of: %s. Got "%s"\n' "$name" "$*" "$raw" >&2
  return 1
}

# Sanitize one path component of a Docker repository name.
#
# The registry grammar for a component is:
#
#   [a-z0-9]+((\.|_|__|-*)[a-z0-9]+)*
#
# so a separator is never valid at either end and a run of mixed separators is
# never valid anywhere. The previous sanitizer allowed both, which is why
# branch `fix.` produced `myrepo-fix.` and branch `_wip` produced `myrepo-_wip`:
# two names the log printed confidently and the registry rejected with
# `invalid reference format`.
sanitize_name_component() {
  printf '%s' "$(normalize "$1")" \
    | sed -E 's/[^a-z0-9._-]/-/g' \
    | sed -E 's/[._-]{2,}/-/g' \
    | sed -E 's/^[._-]+//; s/[._-]+$//' \
    | tr -d '\n'
}

# Sanitize a full repository path, preserving `/` so that `team/myapp` works.
sanitize_repository_path() {
  local input="$1"
  local parts=()
  local component
  local result=""

  IFS='/' read -r -a parts <<<"$input"

  for component in ${parts[@]+"${parts[@]}"}; do
    component="$(sanitize_name_component "$component")"

    if [[ -z "$component" ]]; then
      continue
    fi

    if [[ -n "$result" ]]; then
      result="${result}/${component}"
    else
      result="$component"
    fi
  done

  printf '%s' "$result"
}

# Cap a repository name at the 255 characters the registry accepts, then repair
# the tail so that truncation cannot leave a trailing separator behind. Only the
# tag used to be capped, so a long branch name produced a confident log line
# followed by a rejection from the registry.
cap_repository_name() {
  local value="$1"
  local limit=255

  if ((${#value} > limit)); then
    value="${value:0:limit}"
    value="$(printf '%s' "$value" | sed -E 's![._/-]+$!!')"
    printf '::warning::Image name is longer than %s characters and was truncated to "%s"\n' "$limit" "$value" >&2
  fi

  printf '%s' "$value"
}

# Fail unless the value satisfies the registry grammar for a repository name.
# This is the last line of defence: the sanitizer above should always produce a
# value that passes.
assert_repository_name() {
  local value="$1"
  local component='[a-z0-9]+((\.|_|__|-*)[a-z0-9]+)*'

  if [[ -z "$value" ]]; then
    printf '::error::Image name is empty after sanitization\n' >&2
    return 1
  fi

  if [[ ! "$value" =~ ^${component}(/${component})*$ ]]; then
    printf '::error::Resolved image name "%s" is not a valid Docker repository name\n' "$value" >&2
    return 1
  fi
}

# Reject an image_name that already carries a registry host.
#
# Docker reads the first path component as a registry when it contains a dot or
# a colon, or when it is exactly `localhost`. Passing `ghcr.io/org/app` used to
# produce `ghcr.io/ghcr.io/org/app-prod`.
assert_no_registry_host() {
  local value
  value="$(normalize "$1")"

  if [[ -z "$value" ]]; then
    return 0
  fi

  local first="${value%%/*}"

  if [[ "$first" == "localhost" || "$first" == *.* || "$first" == *:* ]]; then
    printf '::error::image_name "%s" starts with what Docker reads as a registry host ("%s"). Pass the host in the "registry" input and only the path in "image_name", for example registry: %s and image_name: %s\n' \
      "$1" "$first" "$first" "${value#*/}" >&2
    return 1
  fi
}

# Sanitize a Docker tag.
#
# Tag grammar: [A-Za-z0-9_][A-Za-z0-9._-]{0,127}. Tags are lowercased for
# consistency with the image name even though the grammar allows uppercase.
sanitize_tag() {
  local tag

  tag="$(printf '%s' "$(normalize "$1")" \
    | sed -E 's/[^a-z0-9._-]/-/g' \
    | sed -E 's/^[._-]+//' \
    | tr -d '\n')"

  tag="${tag:0:128}"

  if [[ -z "$tag" ]]; then
    printf '::error::Docker tag "%s" is empty after sanitization\n' "$1" >&2
    return 1
  fi

  printf '%s' "$tag"
}

# Read a value as a boolean the way Go's strconv.ParseBool does, which is how
# buildx reads ACTIONS_CACHE_SERVICE_V2. The runner sets that one to "True".
is_truthy() {
  case "$(normalize "$1")" in
    1 | t | true)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Print a short hexadecimal digest of a value, for names that must stay short
# and still tell different values apart.
# Usage: short_hash VALUE [LENGTH]
short_hash() {
  local value="$1"
  local length="${2:-12}"
  local digest

  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s' "$value" | sha256sum)"
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "$value" | shasum -a 256)"
  else
    # Last resort on a machine with neither. A CRC is enough to tell names
    # apart, which is all this is used for.
    digest="$(printf '%s' "$value" | cksum)"
    digest="$(printf '%08x' "${digest%% *}")"
  fi

  digest="${digest%% *}"
  printf '%s' "${digest:0:length}"
}

# Derive the GitHub Actions cache scope of one image build.
#
# Usage: derive_cache_scope REPOSITORY REGISTRY BASE_NAME SUFFIX_INPUT \
#          DOCKERFILE CONTEXT TARGET PLATFORMS
#
# The result is "{readable}-{hash}". The readable part is the image name, plus
# the suffix when the caller chose one. The hash covers everything that makes
# two builds different images. Two images sharing a scope replace each other's
# cache index on every export, so each build finds the other image's index and
# misses.
#
# A suffix derived from the branch is left out on purpose. BuildKit already
# keeps one index per GitHub ref, and on import it also reads the index of the
# base and the default branch, so leaving it out lets a pull request or a new
# branch start from the default branch's cache instead of from nothing. An
# explicit suffix stays in: two variants of one image built from the same branch
# would otherwise overwrite each other.
derive_cache_scope() {
  # Named unlike the step variables that carry the same values: the linter
  # would otherwise read those as misspellings of these.
  local repo_slug="$1"
  local registry_host="$2"
  local image_base="$3"
  local suffix_raw="$4"
  local dockerfile="$5"
  local context="$6"
  local target="$7"
  local platform_set="$8"
  local suffix_value
  local readable
  local identity

  suffix_value="$(normalize "$suffix_raw")"
  registry_host="$(normalize "$registry_host")"
  registry_host="${registry_host%/}"

  # The same platforms in another order or spacing are the same build.
  platform_set="$(printf '%s' "$platform_set" \
    | tr ',' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d' \
    | LC_ALL=C sort -u \
    | tr '\n' ',')"
  platform_set="${platform_set%,}"

  readable="$(printf '%s' "$image_base" | tr '/' '-')"
  if [[ -n "$suffix_value" && "$suffix_value" != "none" ]]; then
    readable="${readable}-$(sanitize_name_component "$suffix_value")"
  fi

  # The scope ends up inside a cache key, which the cache service caps at 512
  # characters, so the readable part stays short. The hash keeps it unique.
  readable="${readable:0:100}"
  readable="$(printf '%s' "$readable" | sed -E 's/[._-]+$//')"

  identity="$(printf '%s\n' \
    "repository=${repo_slug}" \
    "registry=${registry_host}" \
    "image=${image_base}" \
    "suffix=${suffix_value}" \
    "dockerfile=${dockerfile}" \
    "context=${context}" \
    "target=${target}" \
    "platforms=${platform_set}")"

  printf '%s-%s' "${readable:-image}" "$(short_hash "$identity")"
}

# Sanitize a cache scope chosen by the caller. It ends up inside the
# comma-separated value of --cache-to and inside a cache key, so only a
# conservative alphabet survives and anything else becomes '-'.
sanitize_cache_scope() {
  local scope

  scope="$(printf '%s' "$(trim "$1")" \
    | LC_ALL=C tr -c 'A-Za-z0-9._-' '-' \
    | sed -E 's/-{2,}/-/g; s/^[._-]+//; s/[._-]+$//')"

  scope="${scope:0:200}"
  scope="$(printf '%s' "$scope" | sed -E 's/[._-]+$//')"

  if [[ -z "$scope" ]]; then
    printf '::error::Input cache_scope "%s" is empty after sanitization. Use letters, digits, dots, dashes and underscores.\n' "$1" >&2
    return 1
  fi

  printf '%s' "$scope"
}

# Print the endpoint attributes of a type=gha cache entry, or nothing when no
# address of the GitHub Actions cache service is available.
#
# Usage: gha_cache_endpoint RESULTS_URL CACHE_URL SERVICE_V2
#
# The token is not an argument on purpose: buildx reads ACTIONS_RUNTIME_TOKEN
# from its own environment, so the token never reaches a command line.
#
# The address is spelled out instead of being left to buildx, because buildx
# older than 0.21 reads ACTIONS_CACHE_URL only, knows nothing about cache
# service v2, which is the only one github.com still runs, and silently drops a
# gha cache entry that ends up without a url. BuildKit, which the builder
# container runs in its current version, speaks v2 as soon as it gets url_v2.
gha_cache_endpoint() {
  local results_url="$1"
  local cache_url="$2"
  local service_v2="$3"
  local plain_url='^https?://[^[:space:],"]+$'
  local url
  local attributes

  if is_truthy "$service_v2" && [[ -n "$results_url" ]]; then
    url="$results_url"
    # 'url' as well as 'url_v2': buildx older than 0.21 drops the entry
    # when 'url' is missing, and BuildKit prefers 'url_v2' when both are set.
    attributes="version=2,url=${url},url_v2=${url}"
  elif [[ -n "$cache_url" ]]; then
    url="$cache_url"
    attributes="url=${url}"
  elif [[ -n "$results_url" ]]; then
    url="$results_url"
    attributes="url=${url}"
  else
    return 0
  fi

  # The attributes travel inside a comma-separated value, so an address with
  # a comma, a quote or whitespace in it would corrupt the whole entry.
  if [[ ! "$url" =~ $plain_url ]]; then
    printf '::warning::Not using the Actions cache service address "%s": it is not a plain http(s) URL.\n' "$url" >&2
    return 0
  fi

  printf '%s' "$attributes"
}
