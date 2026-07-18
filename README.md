# temp-poc

`temp-poc` is one deployable Helm release for a small end-to-end ScaleX
multi-cluster service test.

The data path intentionally crosses the Karmada member boundary:

```text
b: dataset-ingest HTTP service
          |
          | GET /dataset.csv
          v
c: batch-analyzer CronJob
          |
          | POST /result
          v
b: report-generator HTTP service
```

Tower Argo CD reads `chart/` through the
`scalex-federation` `experiment/release-per-directory` ApplicationSet. The
single chart renders all workloads plus namespaced Karmada
`PropagationPolicy` and `OverridePolicy` resources. The two b-side Services
remain `ClusterIP` in the base manifests and become fixed LoadBalancer
services only through Karmada overrides.

## Repository layout

```text
chart/        single Helm chart and policy/propagation plus policy/overrides templates
images/       one Dockerfile per component
src/          shared typed service implementation
scripts/      local build and validation entrypoints
tests/        application and rendered-chart tests
compose.yaml  optional local Compose definitions (not the CI image inventory)
```

Local validation is:

```bash
./scripts/test.sh
```

Build every component that has an `images/<component>/Dockerfile`. Discovery is
sorted and automatic; the tag defaults to `sha-<current-git-commit>`:

```bash
./scripts/build-images.sh
```

Build and push immutable SHA tags to the local Harbor namespace:

```bash
docker login 10.34.25.18
./scripts/build-images.sh --registry 10.34.25.18/playerone --push
```

Use another registry namespace or an explicit source revision when needed:

```bash
./scripts/build-images.sh \
  --registry 10.34.25.18/playerone \
  --push --release-tag 0.1.0 --latest \
  <40-character-git-sha>
```

`--release-tag` requires an `X.Y.Z` semantic version. `--latest` moves each
component repository's mutable `latest` tag to that release and therefore
requires both `--push` and `--release-tag`. The Docker daemon must list
`10.34.25.18` as an insecure registry. ORAS promotion publication is currently
commented out because this workflow only builds and pushes component images.

The workflow uses Git tags as release events:

- A `main` push publishes only the immutable `sha-<commit>` tag.
- A `v0.1.0` Git tag publishes `sha-<commit>`, `0.1.0`, and `latest`.
- A later `v0.1.1` tag publishes `0.1.1` and moves `latest` to the same digest.
- Publishing an older version after a newer version does not move `latest`
  backwards; only the highest stable SemVer tag may update it.

The chart's `images` values are user-owned deployment defaults and contain only
`repository`, `tag`, and `pullPolicy`. A `latest` tag requires `Always`; an
immutable SHA tag may use either `Always` or `IfNotPresent`. CI-generated
digests and source revisions live in the promotion artifact, not in base
`values.yaml`.

## Deployed workload behavior

The chart deploys two long-running HTTP `Deployment` workloads and one periodic
`CronJob`:

- `dataset-ingest` serves `GET /dataset.csv` on port 8080 through a Service.
- `batch-analyzer` runs every two minutes by default, downloads that CSV from
  `DATASET_URL`, analyzes it, and posts the result to `REPORT_URL`.
- `report-generator` receives `POST /result`, stores the latest result in the
  running process, and exposes the report through its HTTP API and Service.

With Karmada enabled, dataset ingest and report generator are placed on cluster
`b`, while batch analyzer is placed on cluster `c`. Override policies change
the two Services to `LoadBalancer` only on their target cluster and assign the
configured Cilium LB IPs.

`chart/values.yaml` stays valid as user-owned standalone chart defaults, but it
is not the immutable release state. Pushes to `main` and stable `vX.Y.Z` tags run
`.github/workflows/promote.yaml`, which validates the source and chart,
discovers every Dockerfile, and pushes the appropriate SHA and release tags. It
also verifies the pushed registry digests locally. ORAS publication of the
generated promotion payload is preserved as commented workflow code for later
release-tracking work; it does not execute now. CI does not commit chart values,
and `scripts/apply-image-metadata.sh` remains a manual, non-authoritative helper.
