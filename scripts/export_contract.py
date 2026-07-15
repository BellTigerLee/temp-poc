from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Final, TypeAlias

import yaml

JsonScalar: TypeAlias = str | int | float | bool | None
JsonValue: TypeAlias = JsonScalar | list["JsonValue"] | dict[str, "JsonValue"]

FEATURES: Final = ("batch-analyzer", "dataset-ingest", "report-generator")
TEMPLATES: Final = {
    "batch-analyzer": {"_helpers.tpl", "configmap.yaml", "cronjob.yaml"},
    "dataset-ingest": {"_helpers.tpl", "configmap.yaml", "deployment.yaml", "service.yaml"},
    "report-generator": {"_helpers.tpl", "configmap.yaml", "deployment.yaml", "service.yaml"},
}
RESOURCES: Final = {
    "requests": {"cpu": "10m", "memory": "16Mi"},
    "limits": {"cpu": "100m", "memory": "64Mi"},
}


@dataclass(frozen=True, slots=True)
class ContractError(Exception):
    category: str
    detail: str

    def __str__(self) -> str:
        return f"{self.category}: {self.detail}"


def entries(path: Path, ignored: set[str] | None = None) -> set[str]:
    excluded = ignored or set()
    return {item.name for item in path.iterdir()} - excluded


def validate_source_yaml(root: Path) -> None:
    from validate import mapping, text

    metadata = {root / "features.yaml"}
    metadata.update(root.glob("features/*/feature.yaml"))
    metadata.update(root.glob("features/*/chart/Chart.yaml"))
    metadata.update(root.glob("features/*/chart/values.yaml"))
    for path in root.rglob("*.yaml"):
        content = path.read_text(encoding="utf-8")
        if path in metadata or "{{" in content:
            continue
        try:
            documents = yaml.safe_load_all(content)
            for raw in documents:
                document = mapping(raw, str(path))
                kind = text(document, "kind")
                if kind == "Secret" and ("data" in document or "stringData" in document):
                    raise ContractError("SECRET_PAYLOAD", str(path))
                raise ContractError("FORBIDDEN_KIND", kind)
        except yaml.YAMLError as error:
            raise ContractError("MALFORMED_YAML", str(path)) from error


def validate_exact_topology(root: Path) -> None:
    if not (root / "schemas/feature.schema.json").is_file():
        raise ContractError("MISSING_ARTIFACT", "schemas/feature.schema.json")
    root_entries = entries(root)
    root_entries.discard(".git")
    if root_entries != {"README.md", "features", "features.yaml", "schemas", "scripts", "tests"}:
        raise ContractError("TOPOLOGY_VIOLATION", "repository root")
    if entries(root / "schemas") != {"feature.schema.json"}:
        raise ContractError("TOPOLOGY_VIOLATION", "schemas")
    if entries(root / "scripts") != {"validate.py", "export_contract.py"}:
        raise ContractError("TOPOLOGY_VIOLATION", "scripts")
    if entries(root / "tests") != {"test_contract.py"}:
        raise ContractError("TOPOLOGY_VIOLATION", "tests")
    for name in FEATURES:
        package = root / "features" / name
        chart = package / "chart"
        if not (package / "src/README.md").is_file():
            raise ContractError("MISSING_ARTIFACT", f"{name}.source")
        if entries(package) != {"feature.yaml", "src", "image", "chart"}:
            raise ContractError("TOPOLOGY_VIOLATION", name)
        if entries(package / "src") != {"README.md"}:
            raise ContractError("TOPOLOGY_VIOLATION", f"{name}.src")
        if entries(chart) != {"Chart.yaml", "values.yaml", "values.schema.json", "templates"}:
            raise ContractError("TOPOLOGY_VIOLATION", f"{name}.chart")
        if entries(chart / "templates") != TEMPLATES[name]:
            raise ContractError("TOPOLOGY_VIOLATION", f"{name}.templates")


def validate_context_and_values(root: Path) -> None:
    from validate import load_yaml, mapping

    suspicious = (
        "token", "password", "passwd", "credential", "private key", "private_key",
        "certificate", "kubeconfig", "docker login", "podman login", "buildah login",
        "docker push", "podman push", "buildah push", "nerdctl push", "skopeo ",
        "crane ", "oras ", "regctl ",
    )
    for name in FEATURES:
        package = root / "features" / name
        image_dir = package / "image"
        if (image_dir / ".containerignore").read_text(encoding="utf-8") != "*\n!Containerfile\n!payload.txt\n":
            raise ContractError("CONTAINER_CONTEXT", name)
        context = "\n".join(path.read_text(encoding="utf-8").lower() for path in image_dir.iterdir())
        if any(term in context for term in suspicious):
            raise ContractError("CONTAINERFILE", name)
        feature = mapping(load_yaml(package / "feature.yaml"), "feature")
        spec = mapping(feature.get("spec"), "spec")
        values = mapping(load_yaml(package / "chart/values.yaml"), "values")
        if mapping(values.get("image"), "values.image") != mapping(spec.get("image"), "spec.image"):
            raise ContractError("IMAGE_PROVENANCE", name)
        if values.get("existingSecret") != {"name": "", "key": ""}:
            raise ContractError("SECRET_REFERENCE", name)
        if values.get("resources") != RESOURCES:
            raise ContractError("RESOURCE_CONTRACT", name)


def validate_static_repository(root: Path) -> None:
    validate_source_yaml(root)
    validate_exact_topology(root)


def export_contract(root: Path) -> str:
    from validate import validate_repository

    features = validate_repository(root)
    document: dict[str, JsonValue] = {
        "apiVersion": "temp-poc.netai.io/v1alpha1",
        "features": [
            {
                "name": feature.name,
                "optional": [],
                "provides": [],
                "requires": list(feature.requires),
            }
            for feature in features
        ],
        "kind": "ProducerContract",
    }
    return json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n"


def main() -> int:
    from validate import ContractError as ValidationError, parse_root

    try:
        output = export_contract(parse_root(sys.argv[1:]))
    except ValidationError as error:
        print(error, file=sys.stderr)
        return 1
    sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
