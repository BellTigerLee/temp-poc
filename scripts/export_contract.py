from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))

from scripts.policy import ContractError, JsonValue
from scripts.validate import Feature, parse_root, validate_repository


def export_contract(features: tuple[Feature, ...]) -> str:
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
    try:
        output = export_contract(validate_repository(parse_root(sys.argv[1:])))
    except ContractError as error:
        print(error, file=sys.stderr)
        return 1
    _ = sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
