# Copyright 2026 Canonical Ltd.
# See LICENSE file for licensing details.
"""Send the tests' HTTP requests from inside a unit, for hosts outside the cluster.

The steps talk to each workload at its unit address, which only works from
somewhere that can reach the Kubernetes pod network. SolQA's runners can't
(see sqa_tests), but they can run commands in units through Juju. Setting
SOLUTION_HTTP_RELAY to an application name (e.g. "grafana") makes every request
run from inside that application's leader unit via `juju exec`, where the pod
network is reachable. Unset, requests go out directly as usual.
"""

import base64
import json
import os

import jubilant
import requests
from requests.adapters import BaseAdapter
from requests.structures import CaseInsensitiveDict

_RELAY_ENV_VAR = "SOLUTION_HTTP_RELAY"

# Runs in the relay unit's charm container, so it may only use the standard
# library. REQUEST is replaced with the base64-encoded request.
_REMOTE_SCRIPT = """
import base64, json, ssl, urllib.error, urllib.request
req = json.loads(base64.b64decode("REQUEST"))
body = base64.b64decode(req["body"]) if req["body"] else None
r = urllib.request.Request(
    req["url"], data=body, headers=req["headers"], method=req["method"]
)
context = ssl._create_unverified_context()
try:
    resp = urllib.request.urlopen(r, timeout=req["timeout"], context=context)
except urllib.error.HTTPError as e:
    resp = e
except Exception as e:
    print(json.dumps({"error": f"{type(e).__name__}: {e}"}))
    raise SystemExit
print(json.dumps({
    "status": resp.status,
    "reason": resp.reason,
    "headers": dict(resp.headers),
    "body": base64.b64encode(resp.read()).decode(),
}))
"""


class JujuExecAdapter(BaseAdapter):
    """A requests transport that performs each request inside a unit."""

    def __init__(self, juju: jubilant.Juju, unit: str):
        super().__init__()
        self.juju = juju
        self.unit = unit

    def send(
        self, request, stream=False, timeout=None, verify=True, cert=None, proxies=None
    ):
        if isinstance(timeout, tuple):
            timeout = timeout[1]
        body = request.body.encode() if isinstance(request.body, str) else request.body
        payload = {
            "method": request.method,
            "url": request.url,
            "headers": dict(request.headers),
            "body": base64.b64encode(body).decode() if body else "",
            "timeout": timeout or 60,
        }
        encoded = base64.b64encode(json.dumps(payload).encode()).decode()
        script = base64.b64encode(
            _REMOTE_SCRIPT.replace("REQUEST", encoded).encode()
        ).decode()
        command = f'python3 -c \'exec(__import__("base64").b64decode("{script}"))\''
        try:
            task = self.juju.exec(command, unit=self.unit)
            result = json.loads(task.stdout)
        except (jubilant.CLIError, jubilant.TaskError, TimeoutError, ValueError) as e:
            raise requests.ConnectionError(
                f"relay via {self.unit} failed: {e}", request=request
            ) from e
        if "error" in result:
            raise requests.ConnectionError(result["error"], request=request)

        response = requests.Response()
        response.status_code = result["status"]
        response.reason = result["reason"]
        response.headers = CaseInsensitiveDict(result["headers"])
        response._content = base64.b64decode(result["body"])
        response.encoding = requests.utils.get_encoding_from_headers(response.headers)
        response.url = request.url
        response.request = request
        return response

    def close(self):
        pass


def route(session: requests.Session, juju: jubilant.Juju) -> requests.Session:
    """Send the session's requests through the relay unit, if one is configured."""
    app = os.environ.get(_RELAY_ENV_VAR)
    if app:
        adapter = JujuExecAdapter(juju, f"{app}/leader")
        session.mount("http://", adapter)
        session.mount("https://", adapter)
    return session
