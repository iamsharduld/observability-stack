#!/usr/bin/env python3
# Copyright 2026 Canonical Ltd.
# See LICENSE file for licensing details.
"""Write metrics.json for SolQA's pipeline: what the deployed model runs.

For every application: its charm, channel, revision and resource revisions.
The stable quality gate compares these with the revisions it pinned before
testing (`just solution verify-pin`). Also records the test environment the
pipeline describes in CLUSTER, SUBSTRATE and JUJU_CHANNEL (SolQA's spec SQ088).

If the model can't be read, the file still gets written, with no
applications and an "error", and the script exits non-zero.

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
        # Juju prints nothing (not "{}") for an app without resources, such
        # as self-signed-certificates
        output = juju.cli("resources", name, "--format=json")
        resources = json.loads(output) if output.strip() else {}
        applications[name] = {
            "charm": app.charm_name,
            "channel": app.charm_channel,
            "revision": app.charm_rev,
            "origin": app.charm_origin,
            # Store resources have numeric revisions; uploaded ones don't
            "resources": {
                r["name"]: int(r["revision"])
                for r in resources.get("resources", [])
                if str(r.get("revision", "")).isdigit()
            },
        }
    return applications


def main() -> int:
    model, out = sys.argv[1], Path(sys.argv[2])
    metrics = {"model": model}
    try:
        metrics["applications"] = deployed(jubilant.Juju(model=model))
    except (jubilant.CLIError, json.JSONDecodeError, OSError) as e:
        print(
            f"ERROR: could not read what is deployed in '{model}': {e}", file=sys.stderr
        )
        metrics["applications"] = {}
        metrics["error"] = str(e)
    metrics["environment"] = {
        var.lower(): os.environ.get(var)
        for var in ("CLUSTER", "SUBSTRATE", "JUJU_CHANNEL")
    }
    out.write_text(json.dumps(metrics, indent=2, sort_keys=True) + "\n")
    return 1 if "error" in metrics else 0


if __name__ == "__main__":
    sys.exit(main())
