from __future__ import annotations

import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Final

import yaml

from export_contract import validate_context_and_values, validate_static_repository
from policy import ContractError, JsonMap, JsonValue, RenderPolicy, WorkloadIdentity, assert_never, mapping, text, validate_rendered_resource

FEATURES: Final = ("batch-analyzer", "dataset-ingest", "report-generator")
GRAPH: Final = {
    "batch-analyzer": ("dataset-ingest",),
    "dataset-ingest": (),
    "report-generator": ("batch-analyzer",),
}
ALLOWED_KINDS: Final = {"ConfigMap", "CronJob", "Deployment", "Service"}
REQUIRED_LABELS: Final = {"app.kubernetes.io/name", "app.kubernetes.io/instance", "app.kubernetes.io/version", "app.kubernetes.io/managed-by", "app.kubernetes.io/part-of"}
RESOURCE_NAMES: Final = {
    "batch-analyzer": {("ConfigMap", "comparison-batch-analyzer-config"), ("CronJob", "comparison-batch-analyzer")},
    "dataset-ingest": {("ConfigMap", "comparison-dataset-ingest-config"), ("Deployment", "comparison-dataset-ingest"), ("Service", "comparison-dataset-ingest")},
    "report-generator": {("ConfigMap", "comparison-report-generator-config"), ("Deployment", "comparison-report-generator"), ("Service", "comparison-report-generator")},
}
IMAGE_ENTRIES: Final = {".containerignore", "Containerfile", "payload.txt"}
HEX64: Final = re.compile(r"sha256:[0-9a-f]{64}\Z")
HEX40: Final = re.compile(r"[0-9a-f]{40}\Z")


@dataclass(frozen=True, slots=True)
class Feature:
    name: str
    requires: tuple[str, ...]
    paths: JsonMap
    image: JsonMap


def load_yaml(path: Path) -> JsonValue:
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as error:
        raise ContractError("MALFORMED_YAML", str(path)) from error


def texts(mapping_value: JsonMap, key: str) -> tuple[str, ...]:
    value = mapping_value.get(key)
    match value:
        case list():
            if not all(isinstance(item, str) for item in value):
                raise ContractError("INVALID_SCHEMA", f"{key} must contain text")
            return tuple(item for item in value if isinstance(item, str))
        case str() | int() | float() | bool() | dict() | None:
            raise ContractError("INVALID_SCHEMA", f"{key} must be a list")
        case unreachable:
            assert_never(unreachable)


def exact_keys(value: JsonMap, expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise ContractError("INVALID_SCHEMA", f"{label} fields")


def parse_feature(root: Path, name: str) -> Feature:
    document = mapping(load_yaml(root / "features" / name / "feature.yaml"), name)
    metadata = mapping(document.get("metadata"), "metadata")
    spec = mapping(document.get("spec"), "spec")
    exact_keys(document, {"apiVersion", "kind", "metadata", "spec"}, name)
    exact_keys(metadata, {"name"}, f"{name}.metadata")
    exact_keys(spec, {"status", "renderer", "requires", "optional", "provides", "paths", "image"}, f"{name}.spec")
    if text(document, "apiVersion") != "temp-poc.netai.io/v1alpha1" or text(document, "kind") != "Feature":
        raise ContractError("INVALID_SCHEMA", f"{name} header")
    if text(metadata, "name") != name or text(spec, "status") != "non-production" or text(spec, "renderer") != "helm/v1":
        raise ContractError("INVALID_SCHEMA", f"{name} identity")
    paths = mapping(spec.get("paths"), "paths")
    image = mapping(spec.get("image"), "image")
    exact_keys(paths, {"source", "image", "chart", "tests"}, f"{name}.paths")
    if "digest" not in image:
        raise ContractError("MISSING_DIGEST", name)
    if "sourceRevision" not in image:
        raise ContractError("MISSING_SOURCE_REVISION", name)
    exact_keys(image, {"repository", "tag", "digest", "sourceRevision"}, f"{name}.image")
    if texts(spec, "optional") or texts(spec, "provides"):
        raise ContractError("INVALID_GRAPH", name)
    return Feature(
        name=name,
        requires=texts(spec, "requires"),
        paths=paths,
        image=image,
    )


def validate_index(root: Path) -> tuple[str, ...]:
    document = mapping(load_yaml(root / "features.yaml"), "features.yaml")
    names = texts(document, "features")
    if len(names) != len(set(names)):
        raise ContractError("DUPLICATE_ENTRY", "features.yaml")
    if names != tuple(sorted(names)):
        raise ContractError("UNSORTED_ENTRY", "features.yaml")
    if names != FEATURES:
        raise ContractError("FEATURE_SET", "expected exactly three canonical features")
    return names


def validate_graph(features: tuple[Feature, ...]) -> None:
    names = {feature.name for feature in features}
    for feature in features:
        if feature.requires != tuple(sorted(feature.requires)):
            raise ContractError("UNSORTED_ENTRY", f"{feature.name}.requires")
        if feature.name in feature.requires:
            raise ContractError("SELF_DEPENDENCY", feature.name)
        if not set(feature.requires).issubset(names):
            raise ContractError("UNKNOWN_DEPENDENCY", feature.name)
    pending = {feature.name: set(feature.requires) for feature in features}
    while pending:
        ready = {name for name, dependencies in pending.items() if not dependencies}
        if not ready:
            raise ContractError("CYCLIC_DEPENDENCY", ",".join(sorted(pending)))
        pending = {name: dependencies - ready for name, dependencies in pending.items() if name not in ready}
    if {feature.name: feature.requires for feature in features} != GRAPH:
        raise ContractError("INVALID_GRAPH", "canonical dependency graph changed")


def validate_paths(root: Path, feature: Feature) -> None:
    package = root / "features" / feature.name
    expected = {"source": "src/README.md", "image": "image", "chart": "chart", "tests": "../../tests/test_contract.py"}
    for key, relative in expected.items():
        actual = text(feature.paths, key)
        resolved = (package / actual).resolve()
        owner = root.resolve() if key == "tests" else package.resolve()
        if not resolved.is_relative_to(owner):
            raise ContractError("PATH_ESCAPE", f"{feature.name}.{key}")
        if actual != relative:
            raise ContractError("TOPOLOGY_VIOLATION", f"{feature.name}.{key}")
        if not resolved.exists():
            raise ContractError("MISSING_ARTIFACT", f"{feature.name}.{key}")


def validate_image(root: Path, feature: Feature) -> None:
    repository = text(feature.image, "repository")
    tag = text(feature.image, "tag")
    digest_value = feature.image.get("digest")
    revision_value = feature.image.get("sourceRevision")
    if repository != f"registry.example.invalid/temp-poc/{feature.name}" or tag != "0.1.0-c57dcba":
        raise ContractError("MUTABLE_IMAGE", feature.name)
    if not isinstance(digest_value, str):
        raise ContractError("MISSING_DIGEST", feature.name)
    if HEX64.fullmatch(digest_value) is None:
        raise ContractError("MUTABLE_IMAGE", feature.name)
    if not isinstance(revision_value, str):
        raise ContractError("MISSING_SOURCE_REVISION", feature.name)
    if HEX40.fullmatch(revision_value) is None:
        raise ContractError("MUTABLE_REVISION", feature.name)
    image_dir = root / "features" / feature.name / "image"
    if {path.name for path in image_dir.iterdir()} != IMAGE_ENTRIES:
        raise ContractError("TOPOLOGY_VIOLATION", f"{feature.name}.image")
    containerfile = (image_dir / "Containerfile").read_text(encoding="utf-8")
    if not re.search(r"^FROM registry\.example\.invalid/.+@sha256:[0-9a-f]{64}$", containerfile, re.MULTILINE):
        raise ContractError("MUTABLE_IMAGE", f"{feature.name} base")
    if containerfile.count("COPY ") != 1 or "COPY payload.txt /payload.txt" not in containerfile or "latest" in containerfile.lower():
        raise ContractError("CONTAINERFILE", feature.name)


def validate_render(root: Path, feature: Feature) -> None:
    chart = root / "features" / feature.name / "chart"
    chart_metadata = mapping(load_yaml(chart / "Chart.yaml"), "Chart.yaml")
    if (text(chart_metadata, "apiVersion"), text(chart_metadata, "name"), text(chart_metadata, "version"), text(chart_metadata, "appVersion")) != ("v2", feature.name, "0.1.0", "0.1.0"):
        raise ContractError("CHART_CONTRACT", feature.name)
    result = subprocess.run(
        ["helm", "template", "comparison", str(chart), "--namespace", "comparison"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ContractError("HELM_RENDER", result.stderr.strip())
    expected_image = f"{text(feature.image, 'repository')}@{text(feature.image, 'digest')}"
    policy = RenderPolicy(WorkloadIdentity(feature.name, expected_image), frozenset(ALLOWED_KINDS), frozenset(REQUIRED_LABELS))
    identities: set[tuple[str, str]] = set()
    for raw in yaml.safe_load_all(result.stdout):
        document = mapping(raw, "rendered resource")
        resource = validate_rendered_resource(document, policy)
        identities.add((resource.kind, resource.name))
        match resource.kind:
            case "ConfigMap":
                pass
            case "CronJob":
                if text(resource.spec, "schedule") != "0 * * * *":
                    raise ContractError("WORKLOAD_CONTRACT", feature.name)
            case "Deployment":
                if resource.spec.get("replicas") != 1:
                    raise ContractError("WORKLOAD_CONTRACT", feature.name)
            case "Service":
                ports = resource.spec.get("ports")
                if not isinstance(ports, list) or not ports or mapping(ports[0], "service port").get("port") != 8080:
                    raise ContractError("WORKLOAD_CONTRACT", feature.name)
            case unreachable:
                assert_never(unreachable)
    if identities != RESOURCE_NAMES[feature.name]:
        raise ContractError("RESOURCE_IDENTITY", feature.name)


def validate_repository(root: Path) -> tuple[Feature, ...]:
    validate_static_repository(root)
    names = validate_index(root)
    features = tuple(parse_feature(root, name) for name in names)
    validate_graph(features)
    for feature in features:
        validate_paths(root, feature)
        validate_image(root, feature)
    validate_context_and_values(root)
    for feature in features:
        validate_render(root, feature)
    return features


def parse_root(arguments: list[str]) -> Path:
    if arguments == []:
        return Path(__file__).parents[1]
    if len(arguments) == 2 and arguments[0] == "--root":
        return Path(arguments[1])
    raise ContractError("USAGE", "validate.py [--root PATH]")


def main() -> int:
    try:
        validate_repository(parse_root(sys.argv[1:]))
    except ContractError as error:
        print(error, file=sys.stderr)
        return 1
    print("VALID: feature package contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
