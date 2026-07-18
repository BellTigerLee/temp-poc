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
compose.yaml  Docker Compose image build definitions
```

Local validation is:

```bash
./scripts/test.sh
```

Build all component images through Docker Compose. The tag defaults to
`sha-<current-git-commit>`:

```bash
./scripts/build-images.sh
```

Build and push them to the default `docker.io/belltigerlee` namespace:

```bash
docker login docker.io
./scripts/build-images.sh --push
```

Use another registry namespace or an explicit source revision when needed:

```bash
./scripts/build-images.sh \
  --registry docker.io/example \
  --push \
  <40-character-git-sha>
```

`chart/values.yaml` stays valid as standalone chart defaults, but it is not the
release state. Pushes to `main` run `.github/workflows/promote.yaml`, which
validates the source and chart, builds the exact-SHA images, and publishes one
immutable OCI promotion artifact to `10.34.25.18/playerone/temp-poc-promotions`.
The payload stores the source SHA in `source.revision` and the image deployment
digests in `images`. The OCI transport digest identifies the OCI manifest and
is emitted and verified separately, not stored inside `ReleasePromotion`. The
immutable run tag `sha-<source-sha>-run-<run-id>-attempt-<attempt>` is intended
for indefinite initial retention, while `latest-verified` is discovery only.
Child CI is the sole writer of that channel, and it moves it only when the
candidate source SHA still matches the current remote `origin/main`. Stale
completed runs keep their immutable artifact but do not move the channel. CI no
longer commits chart values, and `scripts/apply-image-metadata.sh` remains a
manual, non-authoritative helper.
