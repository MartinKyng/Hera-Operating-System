# Optional public-only wrapper for a published artifact. Production Compose
# pulls by digest directly and NEVER builds this file. No application source,
# COPY instructions, or private repository access belongs in this bundle.
# Example: docker build --build-arg HERA_IMAGE_DIGEST=<64 hex chars> -f deploy/Dockerfile .
ARG HERA_IMAGE_DIGEST
FROM docker.io/kyngroyalty/hera-os@sha256:${HERA_IMAGE_DIGEST}
