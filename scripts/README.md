# Scripts

Run these commands from the repository root. `build-images.sh` also resolves the
root directory itself, so it can be invoked from another working directory.

## Image build and push

`build-images.sh` reads the arbitrary `images` map in `chart/values.yaml`, in
sorted key order. `compose.yaml` and directory discovery are not the CI image
inventory. Each entry requires a user-managed repository, exact OCI tag, and
`Always` or `IfNotPresent` pull policy. Stable `vX.Y.Z` tags are recommended.

Prerequisites:

- Docker Engine access
- Registry authentication before using `--push`

Build all entries that have an `images/<key>/Dockerfile` without pushing:

```bash
./scripts/build-images.sh
```

Build/push Dockerfile-backed entries, pull entries without a Dockerfile for
digest resolution, and write CI-managed metadata:

```bash
docker login 10.34.25.18
./scripts/build-images.sh --push \
  --generated-values /tmp/generated-values.yaml \
  "$(git rev-parse HEAD)"
```

An explicit 40-character Git SHA may be supplied as the final argument:

```bash
./scripts/build-images.sh --push \
  --generated-values /tmp/generated-values.yaml \
  "0123456789abcdef0123456789abcdef01234567"
```

The base and generated values have separate ownership:

```yaml
# chart/values.yaml: user-managed
images:
  custom-worker:
    repository: 10.34.25.18/playerone/custom-worker
    tag: v0.1.0
    pullPolicy: IfNotPresent

# generated-values.yaml: CI-managed
images:
  custom-worker:
    digest: sha256:...
    sourceRevision: 77a324f98372aeafaec47b0f9d26e2f2fb0d17b6
```

The Git SHA identifies the committed source. Commit source changes before a
release build so generated metadata remains traceable to the image contents.

`create-promotion-payload.sh` combines user-managed identity with CI-managed
metadata without modifying either source file:

```bash
./scripts/create-promotion-payload.sh \
  /tmp/temp-poc-promotion.json \
  /tmp/generated-values.yaml \
  "$(git rev-parse HEAD)"
```

The payload stores exact repository, version tag, digest, and source revision
for every configured image. CI never commits base or generated values.

On pushes to `main`, `.github/workflows/promote.yaml` validates the project,
processes all configured images, and uploads `generated-values.yaml` plus
`promotion.json`. ORAS promotion artifact publication remains commented out.
Configure these GitHub Actions secrets for the existing Harbor project only:

- `HARBOR_USERNAME`
- `HARBOR_PASSWORD`

The workflow uses GitHub `contents: read`, no Git write permission, and no chart
commit-back path. The current Harbor is HTTP-only, so the Docker host must trust
it as an insecure registry. Explicit `tag: latest` is processed as the literal
ordinary tag; the Child performs no highest-version lookup or extra tagging.
Federation will later choose the highest verified SemVer and pin repository,
tag, and digest; Helm only renders that exact selection.

`push-images.sh` is a deprecated wrapper around `build-images.sh --push`.

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
