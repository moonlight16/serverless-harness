# Optional: build the worker as an in-cluster pod image.
# Build from the REPO ROOT so the proto stubs (../gen/go, referenced via a
# `replace` in go.mod) are in the build context:
#
#   docker build -f remote-worker/Dockerfile -t quay.io/aslomnet/remote-worker:dev .
#
# Then set that image in ../deploy/knative/worker-example.yaml with
# RELAY_ADDR=sandbox-relay.default.svc:8443 (no port-forward needed in-cluster).
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY gen/go/ ./gen/go/
COPY remote-worker/ ./remote-worker/
WORKDIR /src/remote-worker
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/remote-worker ./cmd/worker
# The worker execs `bash -c <command>`, so the runtime image needs a shell and the
# coreutils the harness's ops call: base64 (writeFile), file (image mime sniffing).
# distroless/static ships none of them — every exec would fail with ENOENT.
# In production the binary drops into a real sandbox image instead; this stage
# exists so the standalone demo image works on its own.
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest
RUN microdnf install -y --nodocs bash coreutils-single findutils file \
    && microdnf clean all
COPY --from=build /out/remote-worker /usr/local/bin/remote-worker
# Matches the nonroot-v2 SCC deploy-incluster.sh applies.
USER 1001
ENTRYPOINT ["/usr/local/bin/remote-worker"]
