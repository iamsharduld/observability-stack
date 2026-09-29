#!/usr/bin/env python3
# Copyright 2026 Canonical Ltd.
# See LICENSE file for licensing details.
"""Record deployed charm/resource revisions and the SolQA environment.

On failure, write empty applications and an error, then exit non-zero.

Usage: write_metrics.py <model> <output file>
"""

import json
import os
import sys
from pathlib import Path

import jubilant


def deployed(juju: jubilant.Juju) -> dict:
    applications = {}
    for name, app in juju.status().apps.items():
        # Juju prints nothing for applications without resources.
        output = juju.cli("resources", name, "--format=json")
        resources = json.loads(output) if output.strip() else {}
        applications[name] = {
            "charm": app.charm_name,
            "channel": app.charm_channel,
            "revision": app.charm_rev,
            "origin": app.charm_origin,
            # Uploaded resources have no numeric store revision.
            "resources": {
                resource["name"]: int(resource["revision"])
                for resource in resources.get("resources", [])
                if str(resource.get("revision", "")).isdigit()
            },
        }
    return applications


def main() -> int:
    model = sys.argv[1]
    output = Path(sys.argv[2])
    metrics = {"model": model}
    try:
        metrics["applications"] = deployed(jubilant.Juju(model=model))
    except (jubilant.CLIError, json.JSONDecodeError, OSError) as error:
        print(
            f"ERROR: could not read what is deployed in '{model}': {error}",
            file=sys.stderr,
        )
        metrics["applications"] = {}
        metrics["error"] = str(error)
    metrics["environment"] = {
        var.lower(): os.environ.get(var)
        for var in ("CLUSTER", "SUBSTRATE", "JUJU_CHANNEL")
    }
    output.write_text(json.dumps(metrics, indent=2, sort_keys=True) + "\n")
    return 1 if "error" in metrics else 0


if __name__ == "__main__":
    sys.exit(main())
