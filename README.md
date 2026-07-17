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

No CI workflow is included. Local validation is:

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
