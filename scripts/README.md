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
repository/tag/digest/sourceRevision fields expected by `scalex-federation`.
It does not modify another repository by itself.

On pushes to `experiment/candidate-feature-packages`,
`.github/workflows/promote.yaml` validates the project, builds and pushes all
three images, creates this payload, then uses a short-lived GitHub App token to
open or update the `promote/temp-poc` bot Pull Request in
`SJoon99/scalex-federation`. A newer child commit replaces that PR's candidate
state, so only one open promotion is maintained. The workflow never pushes
`main` or merges the PR. Configure these GitHub Actions settings first:

- variable: `SCALEX_PROMOTION_ENABLED=true` to enable the workflow (it is
  disabled when the variable is absent or has any other value)
- variable: `SCALEX_PROMOTION_APP_ID`
- secrets: `SCALEX_PROMOTION_APP_PRIVATE_KEY`, `DOCKERHUB_USERNAME`,
  `DOCKERHUB_TOKEN`

The GitHub App must be installed on `SJoon99/scalex-federation` with repository
Contents and Pull requests write permissions.

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
