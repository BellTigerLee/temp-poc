from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Final, NoReturn, TypeAlias

import yaml

JsonScalar: TypeAlias = str | int | float | bool | None
JsonValue: TypeAlias = JsonScalar | list["JsonValue"] | dict[str, "JsonValue"]
JsonMap: TypeAlias = dict[str, JsonValue]
ALLOWED_RESOURCE_KINDS: Final = frozenset({"ConfigMap", "CronJob", "Deployment", "Service"})
KIND_KEY: Final = re.compile(r"(?m)(^|[{,])[ \t]*[\"']?kind[\"']?[ \t]*:")
EXPLICIT_KIND_KEY: Final = re.compile(r"(?m)(^)[ \t]*\?[ \t]+[\"']?kind[\"']?[ \t]*(?:[ \t]+#.*)?\n[ \t]*:[ \t]*")
FLOW_EXPLICIT_KIND_KEY: Final = re.compile(r"(?m)([{,])[ \t]*\?[ \t]+[\"']?kind[\"']?[ \t]*:[ \t]*")
STATIC_KIND: Final = re.compile(r"(?:!!str[ \t]+)?(?:\"([A-Za-z][A-Za-z0-9.-]*)\"|'([A-Za-z][A-Za-z0-9.-]*)'|([A-Za-z][A-Za-z0-9.-]*))[ \t]*(?:[ \t]+#.*)?")
FLOW_KIND: Final = re.compile(r"(?:!!str[ \t]+)?(?:\"([A-Za-z][A-Za-z0-9.-]*)\"|'([A-Za-z][A-Za-z0-9.-]*)'|([A-Za-z][A-Za-z0-9.-]*))[ \t]*[,}].*")
BLOCK_HEADER: Final = re.compile(r"[>|][+-]?[0-9]?[ \t]*(?:#.*)?")
BLOCK_VALUE: Final = re.compile(r"([A-Za-z][A-Za-z0-9.-]*)")
SECRET_PAYLOAD_FIELD: Final = re.compile(r"(?m)(?:^|[{,])[ \t]*(?:\?[ \t]+)?[\"']?(?:data|stringData)[\"']?[ \t]*:")
YAML_DOCUMENT: Final = re.compile(r"(?m)^---[ \t]*$")


@dataclass(frozen=True, slots=True)
class ContractError(Exception):
    category: str
    detail: str

    def __str__(self) -> str:
        return f"{self.category}: {self.detail}"


@dataclass(frozen=True, slots=True)
class RenderedResource:
    kind: str
    name: str
    spec: JsonMap


@dataclass(frozen=True, slots=True)
class WorkloadIdentity:
    feature_name: str
    image: str


@dataclass(frozen=True, slots=True)
class RenderPolicy:
    workload: WorkloadIdentity
    allowed_kinds: frozenset[str]
    required_labels: frozenset[str]


def assert_never(value: NoReturn) -> NoReturn:
    raise AssertionError(f"unreachable value: {value!r}")


def mapping(value: JsonValue, label: str) -> JsonMap:
    match value:
        case dict():
            return value
        case str() | int() | float() | bool() | list() | None:
            raise ContractError("INVALID_SCHEMA", f"{label} must be a mapping")
        case unreachable:
            assert_never(unreachable)


def text(mapping_value: JsonMap, key: str) -> str:
    value = mapping_value.get(key)
    match value:
        case str():
            return value
        case int() | float() | bool() | list() | dict() | None:
            raise ContractError("INVALID_SCHEMA", f"{key} must be text")
        case unreachable:
            assert_never(unreachable)


def static_kind(value: str, flow: bool = False) -> str:
    matched = (FLOW_KIND if flow else STATIC_KIND).fullmatch(value)
    if matched is None:
        raise ContractError("FORBIDDEN_KIND", "dynamic kind")
    for group in matched.groups():
        if group is not None:
            return group
    raise AssertionError("static kind pattern has no value")


def block_kind(value: str) -> str:
    matched = BLOCK_VALUE.fullmatch(value)
    if matched is None:
        raise ContractError("FORBIDDEN_KIND", "dynamic kind")
    return matched.group(1)


def declared_kind(document: str, match: re.Match[str]) -> str:
    remainder = document[match.end():]
    lines = remainder.splitlines()
    first = lines[0].strip() if lines else ""
    if BLOCK_HEADER.fullmatch(first) is None:
        return static_kind(first, match.group(1) != "")
    block: list[str] = []
    for line in lines[1:]:
        if line and not line[0].isspace():
            break
        if not line.strip():
            raise ContractError("FORBIDDEN_KIND", "dynamic kind")
        block.append(line.strip())
    return block_kind(" ".join(block))


def validate_source_yaml(root: Path) -> None:
    metadata = {root / "features.yaml"}
    metadata.update(root.glob("features/*/feature.yaml"))
    metadata.update(root.glob("features/*/chart/Chart.yaml"))
    metadata.update(root.glob("features/*/chart/values.yaml"))
    templates = {
        path
        for directory in root.glob("features/*/chart/templates")
        for path in directory.rglob("*")
        if path.is_file()
    }
    for path in sorted(templates):
        content = path.read_text(encoding="utf-8")
        for document in YAML_DOCUMENT.split(content):
            matches = (*KIND_KEY.finditer(document), *EXPLICIT_KIND_KEY.finditer(document), *FLOW_EXPLICIT_KIND_KEY.finditer(document))
            for match in matches:
                kind = declared_kind(document, match)
                if kind == "Secret" and SECRET_PAYLOAD_FIELD.search(document):
                    raise ContractError("SECRET_PAYLOAD", str(path))
                if kind not in ALLOWED_RESOURCE_KINDS:
                    raise ContractError("FORBIDDEN_KIND", kind)
    for path in root.rglob("*.yaml"):
        content = path.read_text(encoding="utf-8")
        if path in metadata or path in templates or "{{" in content:
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


def validate_rendered_resource(
    document: JsonMap,
    policy: RenderPolicy,
) -> RenderedResource:
    kind = text(document, "kind")
    if kind == "Secret" and ("data" in document or "stringData" in document):
        raise ContractError("SECRET_PAYLOAD", policy.workload.feature_name)
    if kind not in policy.allowed_kinds:
        raise ContractError("FORBIDDEN_KIND", kind)
    metadata = mapping(document.get("metadata"), "metadata")
    if "namespace" in metadata:
        raise ContractError("HARDCODED_NAMESPACE", policy.workload.feature_name)
    labels = mapping(metadata.get("labels"), "labels")
    if not policy.required_labels.issubset(labels):
        raise ContractError("MISSING_LABEL", policy.workload.feature_name)
    validate_workload_images(document, policy.workload.image, policy.workload.feature_name)
    spec = mapping(document.get("spec"), "spec") if kind != "ConfigMap" else {}
    return RenderedResource(kind=kind, name=text(metadata, "name"), spec=spec)


def validate_workload_images(value: JsonValue, expected_image: str, feature_name: str) -> None:
    match value:
        case dict():
            for key in ("containers", "initContainers"):
                if key not in value:
                    continue
                containers = value[key]
                match containers:
                    case list():
                        for raw in containers:
                            container = mapping(raw, key)
                            if text(container, "image") != expected_image:
                                raise ContractError("WORKLOAD_IMAGE", feature_name)
                    case str() | int() | float() | bool() | dict() | None:
                        raise ContractError("INVALID_SCHEMA", f"{key} must be a list")
                    case unreachable:
                        assert_never(unreachable)
            for child in value.values():
                validate_workload_images(child, expected_image, feature_name)
        case list():
            for child in value:
                validate_workload_images(child, expected_image, feature_name)
        case str() | int() | float() | bool() | None:
            return
        case unreachable:
            assert_never(unreachable)
