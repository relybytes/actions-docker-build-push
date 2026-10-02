# Fixture for the build cache test in .github/workflows/ci.yml. The images built
# from it are loaded into the runner's Docker daemon and never pushed anywhere.
#
# The base image comes from Amazon ECR Public, which mirrors the Docker official
# images, to stay clear of the anonymous pull limit Docker Hub applies to the
# shared addresses of hosted runners.
FROM public.ecr.aws/docker/library/busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e

# Unique per workflow run, attempt and matrix leg, so that the first build of a
# leg can only miss the cache.
ARG RUN_ID
# Tells the two test images apart, so that their slow steps have different keys.
ARG VARIANT

# The slow step the cache is there to skip. The nonce shows where the layer came
# from: a cache hit reuses the layer unchanged, a rebuild writes a new nonce.
RUN echo "${RUN_ID} ${VARIANT}" >/cache-test-run \
  && sleep 30 \
  && cat /proc/sys/kernel/random/uuid >/cache-test-nonce
