# Candidate A: feature-owned packages

Candidate A is an **illustrative**, **non-production** repository layout for three
logical features. Each feature directory contains its source description, image
definition, Helm chart, and feature metadata. A root index and repository-level
validator connect those packages into one checked dependency graph.

## Evidence status

The labels below define the scope of every claim in this guide.

| Label | Meaning in this repository |
| --- | --- |
| **repository-observed** | The claim follows from tracked files, metadata, tests, or static validation in this Git checkout. |
| **render-verified** | Helm 3 strict lint and local `helm template` completed for all three charts with the commands below. |
| **operationally-unverified** | No image build or push, artifact promotion, Federation admission, cluster reconciliation, scheduling, readiness, rollback, or runtime check was performed. |

The `.invalid` image repositories, image digests, and source revisions are
placeholders. They are metadata fixtures, not published artifacts. The chart
renders are local output only and are not evidence of acceptance by Kubernetes,
Argo CD, Karmada, or ScaleX Federation.

## Feature graph

The root `features.yaml` is a sorted package index. Dependency edges remain in
the feature-owned `feature.yaml` files and are checked as one graph by
`scripts/validate.py`.

```text
dataset-ingest
└── batch-analyzer
    └── report-generator
```

In dependency notation:

| Feature | `requires` | `optional` | `provides` |
| --- | --- | --- | --- |
| `dataset-ingest` | `[]` | `[]` | `[]` |
| `batch-analyzer` | `[dataset-ingest]` | `[]` | `[]` |
| `report-generator` | `[batch-analyzer]` | `[]` | `[]` |

## Exact tracked tree

```text
.
├── README.md
├── features.yaml
├── schemas/
│   └── feature.schema.json
├── scripts/
│   ├── export_contract.py
│   └── validate.py
├── tests/
│   └── test_contract.py
└── features/
    ├── batch-analyzer/
    │   ├── feature.yaml
    │   ├── src/
    │   │   └── README.md
    │   ├── image/
    │   │   ├── .containerignore
    │   │   ├── Containerfile
    │   │   └── payload.txt
    │   └── chart/
    │       ├── Chart.yaml
    │       ├── values.yaml
    │       ├── values.schema.json
    │       └── templates/
    │           ├── _helpers.tpl
    │           ├── configmap.yaml
    │           └── cronjob.yaml
    ├── dataset-ingest/
    │   ├── feature.yaml
    │   ├── src/
    │   │   └── README.md
    │   ├── image/
    │   │   ├── .containerignore
    │   │   ├── Containerfile
    │   │   └── payload.txt
    │   └── chart/
    │       ├── Chart.yaml
    │       ├── values.yaml
    │       ├── values.schema.json
    │       └── templates/
    │           ├── _helpers.tpl
    │           ├── configmap.yaml
    │           ├── deployment.yaml
    │           └── service.yaml
    └── report-generator/
        ├── feature.yaml
        ├── src/
        │   └── README.md
        ├── image/
        │   ├── .containerignore
        │   ├── Containerfile
        │   └── payload.txt
        └── chart/
            ├── Chart.yaml
            ├── values.yaml
            ├── values.schema.json
            └── templates/
                ├── _helpers.tpl
                ├── configmap.yaml
                ├── deployment.yaml
                └── service.yaml
```

## Validation and local rendering

Run this block from the repository root. It starts a shell without profile or
startup files, selects the preflighted local Python environment, disables Python
and pytest caches, writes generated output to a temporary directory, and removes
that directory on exit.

```bash
bash --noprofile --norc <<'CHECKS'
set -eu
export PYENV_VERSION=.venv
export PYTHONDONTWRITEBYTECODE=1
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

python3 -m pytest -q -p no:cacheprovider
python3 scripts/validate.py
python3 scripts/export_contract.py > "$tmp/contract.json"

for feature in batch-analyzer dataset-ingest report-generator; do
  chart="features/$feature/chart"
  helm lint --strict "$chart"
  helm template comparison "$chart" --namespace comparison > "$tmp/$feature.yaml"
done

GIT_MASTER=1 git diff --check
printf '%s\n' 'Local static and render checks passed; operational status remains unverified.'
CHECKS
```

`tests/test_contract.py` also exercises duplicate, unknown, self-referencing,
cyclic, and unsorted graph failures, path and topology violations, mutable image
metadata, missing provenance, forbidden Kubernetes kinds, and Secret payloads.
The exporter writes deterministic canonical JSON for later candidate comparison.

## Ownership boundary

| Concern | Candidate A owner | Boundary and evidence status |
| --- | --- | --- |
| Feature source description | `features/<feature>/src/` | Package-owned, **repository-observed**. The sample contains documentation and payload fixtures, not application source. |
| Image definition and context | `features/<feature>/image/` | Package-owned and statically checked, **repository-observed**. No image was built or pushed. |
| Workload chart and defaults | `features/<feature>/chart/` | Package-owned, **render-verified** locally. The chart creates only its allowlisted workload resources. |
| Feature identity and direct dependencies | `features/<feature>/feature.yaml` | Package-owned, then aggregated and checked by repository tooling, **repository-observed**. |
| Package index and graph validation | Root `features.yaml`, schema, scripts, and tests | Repository-owned. The root index names packages, while feature descriptors own edges. |
| Release and environment values | Not assigned in Candidate A | **operationally-unverified**. No deployment-owned values or promotion record exists here. |
| Existing runtime Secret | External prerequisite | Charts accept only an existing Secret name and key. Current ScaleX main assigns Infra-created credentials and bucket names to a common runtime-binding runner; creation, payload, rotation, and delivery remain outside this repository and **operationally-unverified** here. |
| OBC and workload namespace | Target `*-k8s` Infra repository | Current EECS and ScaleX main agree that Infra owns OBC and workload-namespace lifecycle. Candidate A creates neither and remains reference-only, **repository-observed** and **operationally-unverified**. |
| Karmada placement and override policy | Federation prerequisite | Current ScaleX main assigns workload placement and replica overrides to Federation. Candidate A contains no PropagationPolicy, OverridePolicy, cluster selection, or Federation release. |

## Six-axis scorecard

Scores run from 1, weak or unresolved, to 5, strong for the stated governance
property. They compare the layout, not workload quality.

| Axis | Score | Candidate A trade-off | Evidence |
| --- | ---: | --- | --- |
| Package boundary | 5 | Source description, image context, chart, and metadata sit under one feature directory, giving a clear review and CODEOWNERS boundary. | **repository-observed** |
| Graph authority | 3 | Edges are directory-local, but correctness depends on repository-level schema, validator, tests, and the root package index. There is no single embedded root graph record. | **repository-observed** |
| Release/version boundary | 3 | A chart and image contract can change within one directory, but every package still shares the repository commit SHA and branch history. Independent artifact promotion is not implemented. | **repository-observed**, **operationally-unverified** |
| Instance-values ownership | 1 | The producer charts define defaults only. Environment values, release selection, and deployment approval have no owner in this candidate. | **repository-observed**, **operationally-unverified** |
| Source topology | 4 | Feature work is easy to locate and review locally. Shared helpers, label logic, schemas, Containerfile shape, and defaults are repeated across packages. | **repository-observed** |
| Shared-resource ownership | 1 | Candidate A encodes none of these owners. Current references assign OBC and workload namespaces to Infra, runtime binding to a management-plane runner, and Karmada placement or overrides to Federation; all remain external and untested by this producer sample. | **repository-observed**, **operationally-unverified** |

## Strengths

- A feature team can review source description, image definition, chart, values,
  and metadata within one directory.
- Directory-local chart versions and image metadata allow focused package changes.
- Root validation catches cross-directory graph errors without moving package
  details into one central catalog.
- Removing deployment instances and shared infrastructure keeps the producer
  boundary narrow.

## Weaknesses and open decisions

- Directory-local autonomy is incomplete. The three packages share one Git
  history, root validator, schema, tests, and source revision.
- Common chart helpers, recommended labels, values schema fragments,
  Containerfile rules, and resource defaults are duplicated. Updating a shared
  convention requires coordinated edits and parity checks across directories.
- ScaleX Federation's release-per-directory experiment uses the feature
  **repository name** as the release directory, descriptor, namespace, and
  source identity. Candidate A has one repository containing three logical
  features. That is not a one-to-one identity match. Adoption requires either
  splitting the packages into repositories or changing the Federation identity
  contract. This repository proves neither option.
- The earlier architecture review records a historical OBC ownership conflict
  between feature-chart and Federation-dependency approaches. That is not the
  current contract. EECS main at
  `c459082fe247044c440aeb1280d6a3569d6f7de6` and ScaleX main at
  `421272628ce2a11881f1f32c3fe546662925d484` consistently assign OBC and
  workload-namespace lifecycle to the target `*-k8s` Infra repository.
  Candidate A follows the producer side of that boundary: it renders no OBC or
  Namespace and references only existing runtime Secret names and keys.
- Candidate A does not implement the current external handoff. ScaleX main
  assigns Infra-created credential and bucket-name normalization to a common
  runtime-binding runner, and assigns Karmada workload placement and replica
  overrides to Federation. Those paths remain **operationally-unverified** here.

## Reference comparison

These paths were inspected as references. They are not copied contracts, and
their repository-specific behavior differs.

- `architecture/child/temp-child-repo.md:5-12` sketches a feature folder with
  `k8s`, `src`, `docs`, `scripts`, and `images`. Candidate A narrows `k8s` to a
  Helm chart and places image, source description, chart, and metadata together
  under each feature.
- `architecture/child/temp-child-repo-revision.md:55-68` records the current
  child producer as split root `src/`, `images/`, `charts/`, and `tests/` trees.
  Lines 70-86 classify feature-bundle and registry layouts as neutral local
  render experiments. Lines 88-116 assign producer artifacts to the child while
  excluding Secret, OBC, and Karmada policy creation. Lines 120-133 record the
  now-historical OBC conflict and the limit of static and render evidence.
  Candidate A applies those evidence limits but uses the current ownership
  contract cited below and tests a different, feature-co-located topology.
- `scalex-federation@experiment/release-per-directory:releases/README.md` and
  `docs/structure-variant.md` bind one release directory to one feature
  repository name. `docs/ci-promotion.md` expects immutable promotion inputs and
  an active chart to render Karmada placement policy. Candidate A's three
  internal feature names do not match that repository-name identity, and its
  charts intentionally contain no placement policy or promotion automation.
- Live `origin/experiment/single-values-catalog` resolves to
  `74fe32eeb86b47fed80152362dae9b0dfecba126`. At the immutable paths
  `scalex-federation@74fe32eeb86b47fed80152362dae9b0dfecba126:values.yaml`
  and
  `scalex-federation@74fe32eeb86b47fed80152362dae9b0dfecba126:templates/applications.yaml`,
  the root Helm chart iterates repository-keyed release entries containing
  `repo`, `revision`, and `enabled`; optional `path` and `values` fields are
  release-only overrides, with omitted settings owned by each feature chart.
  All ten current examples are disabled: the list has one real 40-hex SHA and
  nine `REPLACE_WITH_FULL_GIT_SHA` placeholders. Only enabled entries must use a
  full immutable Git SHA, and disabled placeholders render no child
  Application. The current tree has no ApplicationSet: enabled entries render
  Argo Applications directly. Candidate A remains the producer-side package
  layout and contains no release catalog, Argo Application, or automated sync
  policy.
- `eecs-k8s/apps/template/features.yaml` and
  `eecs-k8s/templates/applications.yaml:7-85,232-399` keep a large parent-owned
  feature graph and generate Argo Applications from parent manifests.
  `eecs-k8s/apps/template/application.yaml:48-128` composes sources and sync
  policy. Candidate A's small graph belongs to the producer repository and is
  not auto-discovered by those templates. Current
  `eecs-k8s@c459082fe247044c440aeb1280d6a3569d6f7de6:README.md` assigns OBC and
  workload-namespace lifecycle to the target Infra repository and limits
  Federation to workloads and non-secret runtime bindings. Current
  `scalex-federation@421272628ce2a11881f1f32c3fe546662925d484:docs/common-contract.md`
  agrees and keeps feature charts reference-only. Candidate A follows that
  producer restriction but does not operationally verify the external handoff.
  `eecs-k8s/images/openark-kiss-ipxe/Containerfile` is a templated, multi-stage
  production build; Candidate A uses static `.invalid` fixture bases and copies
  only `payload.txt`.
- `smartx-k8s/apps/template/features.yaml` is a separate parent-owned graph.
  `smartx-k8s/templates/applications.yaml:7-85,232-389` validates that graph,
  enables required features, and composes Helm or Kustomize application sources.
  It resembles EECS but has repository-specific catalog entries and application
  behavior. Neither parent reads Candidate A's `features.yaml` automatically.
- `mobilex-k8s/charts/ssh/kangryeol/application.yaml:8-27` demonstrates a
  deployment-owned, multi-source Argo Application and a separate values file.
  It also uses mutable `targetRevision: default` and automated self-heal, so it
  is not a producer or immutability contract for Candidate A.
  `mobilex-k8s/charts/ssh/kangryeol/values.yaml` contains instance-specific
  resources, while `mobilex-k8s/.containerignore:19-25` excludes deployment and
  values trees from image context. Candidate A has no instance layer and keeps
  each image context allowlisted within its feature package.

## Decision summary

Candidate A is strongest when feature-directory review ownership matters more
than central editing and when duplication is acceptable. It is weak where an
organization needs one graph record, independent repository releases,
deployment-owned instances, or settled shared-resource policy. Those gaps are
design decisions, not evidence of operational success.
