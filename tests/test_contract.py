from __future__ import annotations

import shutil
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from typing import TypeAlias, TypedDict

import pytest
import yaml


class ImageYaml(TypedDict):
    repository: str
    tag: str
    digest: str
    sourceRevision: str


class SpecYaml(TypedDict):
    requires: list[str]
    optional: list[str]
    provides: list[str]
    paths: dict[str, str]
    image: ImageYaml


class QuantityYaml(TypedDict):
    cpu: str
    memory: str


class ResourcesYaml(TypedDict):
    requests: QuantityYaml
    limits: QuantityYaml


class YamlMap(TypedDict, total=False):
    features: list[str]
    spec: SpecYaml
    resources: ResourcesYaml


YamlMutation: TypeAlias = Callable[[YamlMap], None]
PathMutation: TypeAlias = Callable[[Path], None]

ROOT = Path(__file__).parents[1]
FEATURES = ("batch-analyzer", "dataset-ingest", "report-generator")
EXPECTED_RESOURCES = {
    "batch-analyzer": (("ConfigMap", "comparison-batch-analyzer-config"), ("CronJob", "comparison-batch-analyzer")),
    "dataset-ingest": (("ConfigMap", "comparison-dataset-ingest-config"), ("Deployment", "comparison-dataset-ingest"), ("Service", "comparison-dataset-ingest")),
    "report-generator": (("ConfigMap", "comparison-report-generator-config"), ("Deployment", "comparison-report-generator"), ("Service", "comparison-report-generator")),
}
EXPECTED_EXPORT = (
    '{"apiVersion":"temp-poc.netai.io/v1alpha1","features":['
    '{"name":"batch-analyzer","optional":[],"provides":[],"requires":["dataset-ingest"]},'
    '{"name":"dataset-ingest","optional":[],"provides":[],"requires":[]},'
    '{"name":"report-generator","optional":[],"provides":[],"requires":["batch-analyzer"]}'
    '],"kind":"ProducerContract"}\n'
)


def run_validator(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(root / "scripts/validate.py"), "--root", str(root)],
        check=False,
        capture_output=True,
        text=True,
    )


def copy_repository(tmp_path: Path) -> Path:
    target = tmp_path / "candidate"
    shutil.copytree(ROOT, target, ignore=shutil.ignore_patterns(".git", "__pycache__", ".pytest_cache"))
    return target


def load_yaml(path: Path) -> YamlMap:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def save_yaml(path: Path, document: YamlMap) -> None:
    path.write_text(yaml.safe_dump(document, sort_keys=False), encoding="utf-8")


def feature_file(root: Path, name: str) -> Path:
    return root / "features" / name / "feature.yaml"


def mutate_feature(root: Path, name: str, mutation: YamlMutation) -> None:
    path = feature_file(root, name)
    document = load_yaml(path)
    mutation(document)
    save_yaml(path, document)


def test_candidate_a_exact_topology_exists() -> None:
    # Given the fixed Candidate A contract
    expected_roots = {"features.yaml", "schemas", "scripts", "tests", "features", "README.md", ".git"}

    # When the repository root is inventoried
    actual_roots = {path.name for path in ROOT.iterdir()} - {".pytest_cache"}

    # Then only the approved roots exist
    assert actual_roots == expected_roots


def test_validator_accepts_complete_candidate() -> None:
    # Given the complete repository
    # When validation runs through the real CLI
    result = run_validator(ROOT)

    # Then validation succeeds without misleading output
    assert result.returncode == 0
    assert result.stdout == "VALID: feature package contract\n"
    assert result.stderr == ""


def test_exporter_is_deterministic_and_canonical() -> None:
    # Given the valid producer repository
    command = [sys.executable, str(ROOT / "scripts/export_contract.py"), "--root", str(ROOT)]

    # When the exporter runs twice
    first = subprocess.run(command, check=True, capture_output=True, text=True).stdout
    second = subprocess.run(command, check=True, capture_output=True, text=True).stdout

    # Then bytes and the complete canonical contract are stable
    assert first == second == EXPECTED_EXPORT


@pytest.mark.parametrize("feature", FEATURES)
def test_helm_render_has_exact_resource_identities(feature: str) -> None:
    # Given a real feature chart
    chart = ROOT / "features" / feature / "chart"

    # When Helm renders the comparison release
    rendered = subprocess.run(
        ["helm", "template", "comparison", str(chart), "--namespace", "comparison"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    resources = tuple(sorted(
        (document["kind"], document["metadata"]["name"])
        for document in yaml.safe_load_all(rendered)
        if document
    ))

    # Then the resource kinds and names are exact
    assert resources == tuple(sorted(EXPECTED_RESOURCES[feature]))


def duplicate_entry(document: YamlMap) -> None:
    document["features"].append("report-generator")


def unsorted_entry(document: YamlMap) -> None:
    document["features"] = list(reversed(document["features"]))


def unknown_dependency(document: YamlMap) -> None:
    document["spec"]["requires"] = ["unknown-feature"]


def self_dependency(document: YamlMap) -> None:
    document["spec"]["requires"] = ["batch-analyzer"]


def cycle_dependency(document: YamlMap) -> None:
    document["spec"]["requires"] = ["report-generator"]


def mutable_tag(document: YamlMap) -> None:
    document["spec"]["image"]["tag"] = "latest"


def mutable_revision(document: YamlMap) -> None:
    document["spec"]["image"]["sourceRevision"] = "main"


def missing_digest(document: YamlMap) -> None:
    del document["spec"]["image"]["digest"]


def missing_revision(document: YamlMap) -> None:
    del document["spec"]["image"]["sourceRevision"]


def remove_resources(root: Path) -> None:
    path = root / "features/dataset-ingest/chart/values.yaml"
    document = load_yaml(path)
    del document["resources"]
    save_yaml(path, document)


def oversize_resources(root: Path) -> None:
    path = root / "features/dataset-ingest/chart/values.yaml"
    document = load_yaml(path)
    document["resources"]["limits"]["cpu"] = "8"
    save_yaml(path, document)


def deployment_template(root: Path) -> Path:
    return root / "features/dataset-ingest/chart/templates/deployment.yaml"


def render_latest_image(root: Path) -> None:
    path = deployment_template(root)
    content = path.read_text(encoding="utf-8").replace('image: "{{ .Values.image.repository }}@{{ .Values.image.digest }}"', 'image: "nginx:latest"')
    path.write_text(content, encoding="utf-8")


def render_wrong_digest(root: Path) -> None:
    path = deployment_template(root)
    image = "registry.example.invalid/temp-poc/dataset-ingest@sha256:" + "f" * 64
    content = path.read_text(encoding="utf-8").replace('image: "{{ .Values.image.repository }}@{{ .Values.image.digest }}"', f'image: "{image}"')
    path.write_text(content, encoding="utf-8")


def render_mutable_init_container(root: Path) -> None:
    path = deployment_template(root)
    content = path.read_text(encoding="utf-8").replace(
        "    spec:\n      containers:",
        "    spec:\n      initContainers:\n        - name: unsafe-init\n          image: nginx:latest\n      containers:",
    )
    path.write_text(content, encoding="utf-8")


def append_helper_template(content: str) -> PathMutation:
    def mutate(root: Path) -> None:
        path = root / "features/dataset-ingest/chart/templates/_helpers.tpl"
        path.write_text(path.read_text(encoding="utf-8") + content, encoding="utf-8")

    return mutate


@pytest.mark.parametrize(
    ("category", "target", "mutation"),
    (
        ("DUPLICATE_ENTRY", "index", duplicate_entry),
        ("UNSORTED_ENTRY", "index", unsorted_entry),
        ("UNKNOWN_DEPENDENCY", "batch-analyzer", unknown_dependency),
        ("SELF_DEPENDENCY", "batch-analyzer", self_dependency),
        ("CYCLIC_DEPENDENCY", "dataset-ingest", cycle_dependency),
        ("MUTABLE_IMAGE", "dataset-ingest", mutable_tag),
        ("MUTABLE_REVISION", "dataset-ingest", mutable_revision),
        ("MISSING_DIGEST", "dataset-ingest", missing_digest),
        ("MISSING_SOURCE_REVISION", "dataset-ingest", missing_revision),
    ),
)
def test_validator_rejects_metadata_mutation(tmp_path: Path, category: str, target: str, mutation: YamlMutation) -> None:
    # Given one malformed metadata mutation
    root = copy_repository(tmp_path)
    path = root / "features.yaml" if target == "index" else feature_file(root, target)
    document = load_yaml(path)
    mutation(document)
    save_yaml(path, document)

    # When validation runs
    result = run_validator(root)

    # Then it fails with the stable category
    assert result.returncode == 1
    assert result.stderr.startswith(f"{category}:")
    assert result.stdout == ""


@pytest.mark.parametrize(
    ("category", "mutation"),
    (
        ("MISSING_ARTIFACT", lambda root: (root / "features/dataset-ingest/src/README.md").unlink()),
        ("PATH_ESCAPE", lambda root: mutate_feature(root, "dataset-ingest", lambda doc: doc["spec"]["paths"].update(source="../../README.md"))),
        ("TOPOLOGY_VIOLATION", lambda root: (root / "unexpected.txt").write_text("unexpected\n", encoding="utf-8")),
        ("FORBIDDEN_KIND", lambda root: (root / "features/dataset-ingest/chart/templates/namespace.yaml").write_text("apiVersion: v1\nkind: Namespace\nmetadata:\n  name: forbidden\n", encoding="utf-8")),
        ("SECRET_PAYLOAD", lambda root: (root / "features/dataset-ingest/chart/templates/secret.yaml").write_text("apiVersion: v1\nkind: Secret\nmetadata:\n  name: forbidden\nstringData:\n  token: exposed\n", encoding="utf-8")),
        ("MALFORMED_YAML", lambda root: (root / "features/dataset-ingest/feature.yaml").write_text("spec: [unterminated\n", encoding="utf-8")),
        ("MISSING_ARTIFACT", lambda root: (root / "schemas/feature.schema.json").unlink()),
        ("TOPOLOGY_VIOLATION", lambda root: (root / "features/dataset-ingest/src/unexpected.txt").write_text("unexpected\n", encoding="utf-8")),
        ("FORBIDDEN_KIND", lambda root: (root / "features/dataset-ingest/src/namespace.yaml").write_text("apiVersion: v1\nkind: Namespace\nmetadata:\n  name: forbidden\n", encoding="utf-8")),
        ("CONTAINER_CONTEXT", lambda root: (root / "features/dataset-ingest/image/.containerignore").write_text(".git\n", encoding="utf-8")),
        ("CONTAINERFILE", lambda root: (root / "features/dataset-ingest/image/Containerfile").write_text("FROM registry.example.invalid/base/static@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nRUN docker login registry.example.invalid --password exposed\nCOPY payload.txt /payload.txt\n", encoding="utf-8")),
        ("CONTAINERFILE", lambda root: (root / "features/dataset-ingest/image/payload.txt").write_text("api_token=exposed\n", encoding="utf-8")),
        ("CONTAINERFILE", lambda root: (root / "features/dataset-ingest/image/Containerfile").write_text("FROM registry.example.invalid/base/static@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nRUN oras push registry.example.invalid/temp-poc/test:bad payload.txt\nCOPY payload.txt /payload.txt\n", encoding="utf-8")),
        ("RESOURCE_CONTRACT", remove_resources),
        ("RESOURCE_CONTRACT", oversize_resources),
    ),
)
def test_validator_rejects_repository_mutation(tmp_path: Path, category: str, mutation: PathMutation) -> None:
    # Given one malformed repository mutation
    root = copy_repository(tmp_path)
    mutation(root)

    # When validation runs
    result = run_validator(root)

    # Then it fails with the stable category
    assert result.returncode == 1
    assert result.stderr.startswith(f"{category}:")
    assert result.stdout == ""


@pytest.mark.parametrize(
    ("category", "mutation"),
    (
        pytest.param("WORKLOAD_IMAGE", render_latest_image, id="rendered-latest-container"),
        pytest.param("WORKLOAD_IMAGE", render_wrong_digest, id="rendered-wrong-digest"),
        pytest.param("WORKLOAD_IMAGE", render_mutable_init_container, id="rendered-mutable-init-container"),
        pytest.param("FORBIDDEN_KIND", append_helper_template("\n{{- if false }}\n---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: dormant-forbidden\n{{- end }}\n"), id="dormant-forbidden-kind"),
        pytest.param("FORBIDDEN_KIND", append_helper_template('\n{{- if false }}\n---\napiVersion: v1\nkind: "Namespace"\nmetadata:\n  name: dormant-quoted\n{{- end }}\n'), id="dormant-quoted-kind"),
        pytest.param("FORBIDDEN_KIND", append_helper_template('\n{{- if false }}\n---\napiVersion: v1\nkind: {{ "Namespace" }}\nmetadata:\n  name: dormant-templated\n{{- end }}\n'), id="dormant-templated-kind"),
        pytest.param("FORBIDDEN_KIND", append_helper_template("\n{{- if false }}\n---\napiVersion: v1\n{{/* harmless */}}kind: Namespace\nmetadata:\n  name: dormant-comment-prefix\n{{- end }}\n"), id="dormant-comment-prefixed-kind"),
        pytest.param("FORBIDDEN_KIND", append_helper_template("\n{{- if false }}\n---\napiVersion: v1\n{{- /* harmless */ -}}kind: Namespace\nmetadata:\n  name: dormant-trim-comment-prefix\n{{- end }}\n"), id="dormant-trim-comment-prefixed-kind"),
        pytest.param("SECRET_PAYLOAD", append_helper_template("\n{{- if false }}\n---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: dormant-secret\nstringData:\n  token: exposed\n{{- end }}\n"), id="dormant-secret-payload"),
        pytest.param("FORBIDDEN_KIND", append_helper_template("\n{{- if false }}\n---\napiVersion: v1\nkind: >-\n  Namespace\nmetadata:\n  name: dormant-block-scalar\n{{- end }}\n"), id="dormant-block-scalar-kind"),
        pytest.param("FORBIDDEN_KIND", append_helper_template('\n{{- if false }}\n---\napiVersion: v1\nkind: "Deployment{{ .Values.suffix }}"\nmetadata:\n  name: dormant-dynamic\n{{- end }}\n'), id="dormant-dynamic-kind-suffix"),
        pytest.param("FORBIDDEN_KIND", append_helper_template("\n{{- if false }}\n---\napiVersion: v1\nkind: Deployment#{{ .Values.suffix }}\nmetadata:\n  name: dormant-plain-dynamic\n{{- end }}\n"), id="dormant-plain-dynamic-suffix"),
        pytest.param("FORBIDDEN_KIND", append_helper_template("\n{{- if false }}\n---\napiVersion: v1\nkind: Deployment,{{ .Values.suffix }}\nmetadata:\n  name: dormant-comma-dynamic\n{{- end }}\n"), id="dormant-plain-comma-suffix"),
        pytest.param("FORBIDDEN_KIND", append_helper_template("\n{{- if false }}\n---\napiVersion: v1\nkind: >-\n  Deployment #{{ .Values.suffix }}\nmetadata:\n  name: dormant-block-dynamic\n{{- end }}\n"), id="dormant-block-dynamic-suffix"),
        pytest.param("FORBIDDEN_KIND", append_helper_template("\n{{- if false }}\n---\napiVersion: v1\nkind: >-\n\n  Deployment\nmetadata:\n  name: dormant-block-blank\n{{- end }}\n"), id="dormant-block-leading-blank"),
        pytest.param("FORBIDDEN_KIND", append_helper_template("\n{{- if false }}\n---\napiVersion: v1\n? kind\n: Namespace\nmetadata:\n  name: dormant-explicit\n{{- end }}\n"), id="dormant-explicit-mapping-key"),
        pytest.param("FORBIDDEN_KIND", append_helper_template("\n{{- if false }}\n---\napiVersion: v1\n? kind # resource type\n: Namespace\nmetadata:\n  name: dormant-explicit-comment\n{{- end }}\n"), id="dormant-commented-explicit-key"),
        pytest.param("FORBIDDEN_KIND", append_helper_template('\n{{- if false }}\n---\n{? "kind" : "Namespace", "apiVersion": "v1", "metadata": {"name": "dormant"}}\n{{- end }}\n'), id="dormant-flow-explicit-key"),
        pytest.param("SECRET_PAYLOAD", append_helper_template('\n{{- if false }}\n---\n{? "kind" : "Secret", ? "apiVersion" : "v1", ? "metadata" : {"name": "dormant"}, ? "stringData" : {"token": "exposed"}}\n{{- end }}\n'), id="dormant-flow-explicit-secret"),
    ),
)
def test_validator_rejects_hidden_render_policy_violation(tmp_path: Path, category: str, mutation: PathMutation) -> None:
    # Given a policy violation hidden from the current validator
    root = copy_repository(tmp_path)
    mutation(root)

    # When validation runs
    result = run_validator(root)

    # Then validation fails closed with no success marker
    assert result.returncode == 1
    assert result.stderr.startswith(f"{category}:")
    assert result.stdout == ""


@pytest.mark.parametrize(
    "mutation",
    (
        pytest.param(append_helper_template("\n{{/* kind: Namespace */}}\n"), id="helm-comment"),
        pytest.param(append_helper_template("\n{{- if false }}\n---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: dormant-allowed\ndata:\n  example: |-\n    kind: Namespace\n{{- end }}\n"), id="block-scalar"),
    ),
)
def test_validator_accepts_harmless_template_source(tmp_path: Path, mutation: PathMutation) -> None:
    root = copy_repository(tmp_path)
    mutation(root)

    result = run_validator(root)

    assert result.returncode == 0
    assert result.stdout == "VALID: feature package contract\n"
    assert result.stderr == ""
