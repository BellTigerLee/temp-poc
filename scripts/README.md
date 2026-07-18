# Scripts

Run these commands from the repository root. `build-images.sh` also resolves the
root directory itself, so it can be invoked from another working directory.

## Image build and push

`build-images.sh` is the primary image entrypoint. It runs the three image
definitions in `compose.yaml` with Docker Compose.

Prerequisites:

- Docker Engine access
- Docker Compose v2 (`docker compose`)
- Registry authentication before using `--push`

Build all three images using the current Git commit as the source revision:

```bash
./scripts/build-images.sh
```

Build and push to the default `docker.io/belltigerlee` namespace:

```bash
docker login docker.io
./scripts/build-images.sh --push
```

Use another registry namespace:

```bash
docker login registry.example.com
./scripts/build-images.sh --registry registry.example.com/team --push
```

An explicit 40-character Git SHA may be supplied as the final argument:

```bash
./scripts/build-images.sh --push "$(git rev-parse HEAD)"
```

The resulting tags have this form:

```text
<registry>/temp-poc-dataset-ingest:sha-<git-sha>
<registry>/temp-poc-batch-analyzer:sha-<git-sha>
<registry>/temp-poc-report-generator:sha-<git-sha>
```

`IMAGE_REGISTRY` is the environment-variable equivalent of `--registry`.
The command-line option takes precedence.

```bash
IMAGE_REGISTRY=registry.example.com/team ./scripts/build-images.sh --push
```

The Git SHA identifies the committed source. Commit source changes before a
release build so the image contents and tag refer to the same revision.

`create-promotion-payload.sh` reads the immutable manifest digest for all three
exact-SHA tags after they are pushed:

```bash
./scripts/create-promotion-payload.sh /tmp/temp-poc-promotion.json "$(git rev-parse HEAD)"
```

The payload stores the child source SHA in `source.revision` and the image
deployment digests in `images`. The OCI transport digest identifies the OCI
manifest and is emitted and verified separately, not recorded inside
`ReleasePromotion`. `chart/values.yaml` still works as standalone defaults, but
it is not authoritative release state. Apply those fields to a chart values file
with:

```bash
./scripts/apply-image-metadata.sh /tmp/temp-poc-promotion.json
```

The apply command verifies that the payload contains the exact chart image set,
that every image tag and source revision matches the payload commit, and that
every digest is immutable. It is a manual utility for local chart metadata only.
CI no longer commits `chart/values.yaml`.

On pushes to `main`, `.github/workflows/promote.yaml` validates the project,
builds and pushes all three images, creates the payload, publishes the
immutable promotion artifact to `10.34.25.18/playerone/temp-poc-promotions`, and
advances `latest-verified` only when the candidate source SHA still equals the
current remote `origin/main`. Stale completed runs keep their immutable artifact
but do not move the channel. The immutable run tag
`sha-<source-sha>-run-<run-id>-attempt-<attempt>` is intended for indefinite
initial retention, and `latest-verified` is discovery only. Configure these
GitHub Actions secrets for the existing Harbor project/repository only:

- `HARBOR_USERNAME`
- `HARBOR_PASSWORD`

The workflow uses GitHub `contents: read`, no Git write permission, and no chart
commit-back path. Live Harbor retention remains unverified until TLS and policy
activation are complete.

`push-images.sh` is the lower-level compatibility command for pushing images
that are already built under the default registry. New workflows should use
`build-images.sh --push`.

## Local validation

Run the complete local validation suite:

```bash
./scripts/test.sh
```

It checks Python dependency locking, formatting, lint, static types, tests,
strict Helm linting, rendered manifests, and whitespace errors.

`validate-render.sh` validates an already rendered manifest directly:

```bash
helm template temp-poc chart --namespace scalex-temp-poc > /tmp/temp-poc.yaml
./scripts/validate-render.sh /tmp/temp-poc.yaml
```

This verifies the expected workload identities, Karmada placement targets,
base Service types, and LoadBalancer address overrides.
