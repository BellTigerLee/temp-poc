from __future__ import annotations

import re
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Final, Literal, Protocol, TypeAlias, override

import yaml

JsonScalar: TypeAlias = str | int | float | bool | None
JsonValue: TypeAlias = JsonScalar | list["JsonValue"] | dict[str, "JsonValue"]
JsonMap: TypeAlias = dict[str, JsonValue]
ResourceKind: TypeAlias = Literal["ConfigMap", "CronJob", "Deployment", "Service"]
ALLOWED_RESOURCE_KINDS: Final = frozenset({"ConfigMap", "CronJob", "Deployment", "Service"})
RESOURCE_KINDS: Final[dict[str, ResourceKind]] = {"ConfigMap": "ConfigMap", "CronJob": "CronJob", "Deployment": "Deployment", "Service": "Service"}
POD_SPEC_PATHS: Final[dict[ResourceKind, tuple[str, ...]]] = {"ConfigMap": (), "CronJob": ("spec", "jobTemplate", "spec", "template", "spec"), "Deployment": ("spec", "template", "spec"), "Service": ()}
RESOURCES: Final = {"requests": {"cpu": "10m", "memory": "16Mi"}, "limits": {"cpu": "100m", "memory": "64Mi"}}
KIND_KEY: Final = re.compile(r"(?m)(^|[{,])[ \t]*[\"']?kind[\"']?[ \t]*:")
EXPLICIT_KIND_KEY: Final = re.compile(r"(?m)(^)[ \t]*\?[ \t]+[\"']?kind[\"']?[ \t]*(?:[ \t]+#.*)?\n[ \t]*:[ \t]*")
FLOW_EXPLICIT_KIND_KEY: Final = re.compile(r"(?m)([{,])[ \t]*\?[ \t]+[\"']?kind[\"']?[ \t]*:[ \t]*")
STATIC_KIND: Final = re.compile(r"(?:!!str[ \t]+)?(?:\"([A-Za-z][A-Za-z0-9.-]*)\"|'([A-Za-z][A-Za-z0-9.-]*)'|([A-Za-z][A-Za-z0-9.-]*))[ \t]*(?:[ \t]+#.*)?")
FLOW_KIND: Final = re.compile(r"(?:!!str[ \t]+)?(?:\"([A-Za-z][A-Za-z0-9.-]*)\"|'([A-Za-z][A-Za-z0-9.-]*)'|([A-Za-z][A-Za-z0-9.-]*))[ \t]*[,}].*")
BLOCK_HEADER: Final = re.compile(r"[>|][+-]?[0-9]?[ \t]*(?:#.*)?")
BLOCK_VALUE: Final = re.compile(r"([A-Za-z][A-Za-z0-9.-]*)")
SECRET_PAYLOAD_FIELD: Final = re.compile(r"(?m)(?:^|[{,])[ \t]*(?:\?[ \t]+)?[\"']?(?:data|stringData)[\"']?[ \t]*:")
YAML_DOCUMENT: Final = re.compile(r"(?m)^---[ \t]*$")
HELM_COMMENT: Final = re.compile(r"{{-?[ \t]*/\*.*?\*/[ \t]*-?}}", re.DOTALL)
BLOCK_SCALAR_FIELD: Final = re.compile(r"^(?P<indent> *)(?P<key>[\"']?[A-Za-z][A-Za-z0-9.-]*[\"']?)[ \t]*:[ \t]*[>|][+-]?[0-9]?[ \t]*(?:#.*)?$")
HELM_KIND_ACTION: Final = re.compile(r"(?m)^[ \t]*\{\{[^\n]*\bkind\b[^\n]*\}\}(?:[ \t]*:.*)?$", re.IGNORECASE)


class YamlLoader(Protocol):
    def __call__(self, stream: str) -> JsonValue: ...


class YamlDocumentsLoader(Protocol):
    def __call__(self, stream: str) -> Iterable[JsonValue]: ...


@dataclass(frozen=True, slots=True)
class ContractError(Exception):
    category: str
    detail: str

    @override
    def __str__(self) -> str:
        return f"{self.category}: {self.detail}"


@dataclass(frozen=True, slots=True)
class RenderedResource:
    kind: ResourceKind
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


def mapping(value: JsonValue, label: str) -> JsonMap:
    if isinstance(value, dict):
        return value
    raise ContractError("INVALID_SCHEMA", f"{label} must be a mapping")


def text(mapping_value: JsonMap, key: str) -> str:
    value = mapping_value.get(key)
    if isinstance(value, str):
        return value
    raise ContractError("INVALID_SCHEMA", f"{key} must be text")


def texts(mapping_value: JsonMap, key: str) -> tuple[str, ...]:
    value = mapping_value.get(key)
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ContractError("INVALID_SCHEMA", f"{key} must contain text")
    return tuple(item for item in value if isinstance(item, str))


def exact_keys(value: JsonMap, expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise ContractError("INVALID_SCHEMA", f"{label} fields")


def load_yaml(path: Path, loader: YamlLoader = yaml.safe_load) -> JsonValue:
    try:
        return loader(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as error:
        raise ContractError("MALFORMED_YAML", str(path)) from error


def yaml_documents(stream: str, loader: YamlDocumentsLoader = yaml.safe_load_all) -> Iterable[JsonValue]:
    return loader(stream)


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


def source_policy_text(content: str) -> str:
    uncommented = HELM_COMMENT.sub(lambda matched: "\n" * matched.group().count("\n"), content)
    masked: list[str] = []
    block_indent: int | None = None
    for line in uncommented.splitlines(keepends=True):
        text_line = line.rstrip("\r\n")
        indent = len(text_line) - len(text_line.lstrip(" "))
        if block_indent is not None:
            if not text_line.strip() or indent > block_indent:
                masked.append("\n" if line.endswith("\n") else "")
                continue
            block_indent = None
        matched = BLOCK_SCALAR_FIELD.fullmatch(text_line)
        if matched is not None and matched.group("key").strip("\"'") != "kind":
            block_indent = len(matched.group("indent"))
        masked.append(line)
    return "".join(masked)


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
        content = source_policy_text(path.read_text(encoding="utf-8"))
        for document in YAML_DOCUMENT.split(content):
            if HELM_KIND_ACTION.search(document):
                raise ContractError("FORBIDDEN_KIND", "dynamic kind")
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
            for raw in yaml_documents(content):
                document = mapping(raw, str(path))
                kind = text(document, "kind")
                if kind == "Secret" and ("data" in document or "stringData" in document):
                    raise ContractError("SECRET_PAYLOAD", str(path))
                raise ContractError("FORBIDDEN_KIND", kind)
        except yaml.YAMLError as error:
            raise ContractError("MALFORMED_YAML", str(path)) from error


def validate_context_and_values(root: Path, features: tuple[str, ...]) -> None:
    suspicious = (
        "token", "password", "passwd", "credential", "private key", "private_key",
        "certificate", "kubeconfig", "docker login", "podman login", "buildah login",
        "docker push", "podman push", "buildah push", "nerdctl push", "skopeo ",
        "crane ", "oras ", "regctl ",
    )
    for name in features:
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


def validate_rendered_resource(
    document: JsonMap,
    policy: RenderPolicy,
) -> RenderedResource:
    raw_kind = text(document, "kind")
    if raw_kind == "Secret" and ("data" in document or "stringData" in document):
        raise ContractError("SECRET_PAYLOAD", policy.workload.feature_name)
    if raw_kind not in policy.allowed_kinds:
        raise ContractError("FORBIDDEN_KIND", raw_kind)
    kind = RESOURCE_KINDS.get(raw_kind)
    if kind is None:
        raise ContractError("FORBIDDEN_KIND", raw_kind)
    metadata = mapping(document.get("metadata"), "metadata")
    if "namespace" in metadata:
        raise ContractError("HARDCODED_NAMESPACE", policy.workload.feature_name)
    labels = mapping(metadata.get("labels"), "labels")
    if not policy.required_labels.issubset(labels):
        raise ContractError("MISSING_LABEL", policy.workload.feature_name)
    validate_workload_images(document, policy.workload.image, policy.workload.feature_name)
    if kind in ("CronJob", "Deployment") and regular_container_count(document, kind) == 0:
        raise ContractError("WORKLOAD_CONTRACT", policy.workload.feature_name)
    spec = mapping(document.get("spec"), "spec") if kind != "ConfigMap" else {}
    return RenderedResource(kind=kind, name=text(metadata, "name"), spec=spec)


def regular_container_count(document: JsonMap, kind: ResourceKind) -> int:
    current = document
    for key in POD_SPEC_PATHS[kind]:
        current = mapping(current.get(key), key)
    containers = current.get("containers")
    if containers is None:
        return 0
    if not isinstance(containers, list):
        raise ContractError("INVALID_SCHEMA", "containers must be a list")
    return len(containers)


def validate_workload_images(value: JsonValue, expected_image: str, feature_name: str) -> None:
    if isinstance(value, list):
        for child in value:
            validate_workload_images(child, expected_image, feature_name)
        return
    if not isinstance(value, dict):
        return
    for key in ("containers", "initContainers"):
        if key not in value:
            continue
        containers = value[key]
        if not isinstance(containers, list):
            raise ContractError("INVALID_SCHEMA", f"{key} must be a list")
        for raw in containers:
            container = mapping(raw, key)
            if text(container, "image") != expected_image:
                raise ContractError("WORKLOAD_IMAGE", feature_name)
    for child in value.values():
        validate_workload_images(child, expected_image, feature_name)
