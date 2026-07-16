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
chart/       single Helm chart and Karmada policies
images/      one immutable image definition per component
src/         shared typed service implementation
scripts/     local build and validation entrypoints
tests/       application and rendered-chart tests
```

No CI workflow is included. Local validation is:

```bash
./scripts/test.sh
```

Build all component images with a source-bound tag:

```bash
./scripts/build-images.sh <40-character-git-sha>
```
