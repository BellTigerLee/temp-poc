# Scripts

Run these commands from the repository root. `build-images.sh` also resolves the
root directory itself, so it can be invoked from another working directory.

## Image build and push

`build-images.sh` discovers every `images/<component>/Dockerfile`, in sorted
order, and builds with the repository root as the Docker build context. Adding
or removing a Dockerfile automatically changes the CI build set; `compose.yaml`
is not the CI inventory.

Prerequisites:

- Docker Engine access
- Registry authentication before using `--push`

Build all discovered images using the current Git commit as the source revision:

```bash
./scripts/build-images.sh
```

Build and push to the local Harbor namespace:

```bash
docker login 10.34.25.18
./scripts/build-images.sh --registry 10.34.25.18/playerone --push
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

Create a semantic-version release and move `latest` to it with:

```bash
./scripts/build-images.sh --registry 10.34.25.18/playerone \
  --push --release-tag 0.1.0 --latest "$(git rev-parse HEAD)"
```

`--release-tag` accepts only `X.Y.Z`. `--latest` requires both a release tag and
`--push`; a normal SHA build can no longer move `latest`. Use `pullPolicy:
Always` with `latest`; `IfNotPresent` is intended for immutable SHA or release
tags.

`create-promotion-payload.sh` reads the immutable manifest digest for every
discovered exact-SHA tag after it is pushed:

```bash
./scripts/create-promotion-payload.sh /tmp/temp-poc-promotion.json "$(git rev-parse HEAD)"
```

The payload stores the child source SHA in `source.revision` and the image
deployment digests in `images`. The OCI transport digest identifies the OCI
manifest and is emitted and verified separately, not recorded inside
`ReleasePromotion`. `chart/values.yaml` contains only user-owned `repository`,
`tag`, and `pullPolicy` image fields and is not authoritative release state.
Apply a promotion's repository and immutable tag to a chart values file with:

```bash
./scripts/apply-image-metadata.sh /tmp/temp-poc-promotion.json
```

The apply command verifies that each chart image is present, its tag and source
revision match the payload commit, and its digest is immutable. It writes only
the user-facing repository and tag; CI-only digest and source revision remain
in the promotion payload. Extra build-only images are allowed. CI never commits
`chart/values.yaml`.

On pushes to `main`, `.github/workflows/promote.yaml` validates the project,
discovers all components, and publishes only their exact SHA tags. A stable Git
tag such as `v0.1.0` additionally publishes image tag `0.1.0`; the highest
stable SemVer release also moves `latest`. ORAS promotion artifact publication
is currently commented out while CI is limited to Docker image automation.
Configure these GitHub Actions secrets for the existing Harbor project only:

- `HARBOR_USERNAME`
- `HARBOR_PASSWORD`

The workflow uses GitHub `contents: read`, no Git write permission, and no chart
commit-back path. The current Harbor is HTTP-only, so the Docker host must trust
it as an insecure registry. The preserved ORAS block can be revisited after
promotion publication is needed and Harbor transport is finalized.

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
