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

The payload contains the child source SHA and all image
repository/tag/digest/sourceRevision fields. Apply those fields to a chart
values file with:

```bash
./scripts/apply-image-metadata.sh /tmp/temp-poc-promotion.json
```

The apply command verifies that the payload contains the exact chart image set,
that every image tag and source revision matches the payload commit, and that
every digest is immutable. It only changes the image metadata fields in
`chart/values.yaml`.

On pushes to `main`, `.github/workflows/promote.yaml` validates the project,
builds and pushes all three images, creates and applies the payload, then commits
`chart/values.yaml` back to this repository. A values-only bot commit is ignored
by the workflow trigger. Configure these GitHub Actions secrets first:

- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`

The repository Actions setting must allow workflows read and write access. If
`main` is protected against direct pushes, allow `github-actions[bot]` to bypass
that rule or change the final step to open a same-repository Pull Request.

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
