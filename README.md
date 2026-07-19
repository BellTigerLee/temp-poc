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

`chart/values.yaml` is the canonical image inventory. Each kebab-case image key
defines its exact `repository`, OCI `tag`, and `pullPolicy`. Stable `vX.Y.Z`
tags are recommended for later Federation selection:

```yaml
images:
  custom-worker:
    repository: 10.34.25.18/playerone/custom-worker
    tag: v0.1.0
    pullPolicy: IfNotPresent
```

If `images/<key>/Dockerfile` exists, CI always builds and pushes the configured
`repository:tag`. If it does not exist, CI pulls that existing image so it can
resolve its registry digest. The image map is not limited to the three default
workloads; those entries remain only because this chart currently deploys those
three workloads.

Build the local Dockerfile-backed entries without pushing:

```bash
./scripts/build-images.sh
```

Build or resolve every configured image, push the Dockerfile-backed images, and
write CI-owned digest metadata:

```bash
docker login 10.34.25.18
./scripts/build-images.sh --push \
  --generated-values /tmp/temp-poc-generated-values.yaml \
  "$(git rev-parse HEAD)"
```

The generated file contains only CI-owned fields and is merged on top of the
base values during verification or deployment selection:

```yaml
images:
  custom-worker:
    digest: sha256:...
    sourceRevision: 77a324f98372aeafaec47b0f9d26e2f2fb0d17b6
```

To publish a new image version, edit the relevant tags in
`chart/values.yaml`, commit that explicit selection, and push `main`:

```bash
git switch main
git pull --ff-only origin main
git diff -- chart/values.yaml
git add chart/values.yaml
git commit -m "Bump temp-poc images to v0.1.1"
git push origin main
```

Docker/Harbor does not infer the highest semantic version and never moves a
`latest` tag automatically. If a user explicitly configures `tag: latest`, this
Child treats it as the literal tag `latest`; it performs no version lookup or
extra tagging. A future ScaleX Federation policy owns selection of the highest
verified SemVer and supplies an exact repository, tag, and digest to Helm. Helm
only renders those already selected values. The Docker daemon must list
`10.34.25.18` as an insecure registry while Harbor remains HTTP-only. ORAS
publication remains commented out.

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
is not immutable release state. A push to `main` runs
`.github/workflows/promote.yaml`, which validates the source and chart, processes
the arbitrary image map, and uploads `generated-values.yaml` plus
`promotion.json` as a workflow artifact. It does not infer or automatically
move `latest`, update Federation, deploy Helm, or commit generated values back
to Git. The Helm render performed in CI is validation only.
