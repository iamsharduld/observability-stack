# Copyright 2026 Canonical Ltd.
# See LICENSE file for licensing details.
"""Send the tests' HTTP requests with curl from inside a unit.

The steps talk to each workload at its unit address, which only works from
somewhere that can reach the Kubernetes pod network. SolQA's runners can't
(see sqa_tests), but they can run commands in units through Juju. Setting
SOLUTION_HTTP_RELAY to an application name (e.g. "grafana") makes every request
run as `curl` inside that application's leader unit via `juju exec`, like the
parca-k8s and sloth-k8s integration tests query their servers from another pod.
Unset, requests go out directly as usual.
"""

import os
import shlex

import jubilant
import requests
from requests.adapters import BaseAdapter

_RELAY_ENV_VAR = "SOLUTION_HTTP_RELAY"


class JujuExecAdapter(BaseAdapter):
    """A requests transport that sends each request with curl from inside a unit."""

    def __init__(self, juju: jubilant.Juju, unit: str):
        super().__init__()
        self.juju = juju
        self.unit = unit

    def send(
        self, request, stream=False, timeout=None, verify=True, cert=None, proxies=None
    ):
        if isinstance(timeout, tuple):
            timeout = timeout[1]
        command = ["curl", "--silent", "--show-error", "--insecure"]
        command += ["--max-time", str(timeout or 60), "--request", request.method]
        # The status code goes on its own last line, after the body
        command += ["--write-out", "\n%{http_code}"]
        for name, value in request.headers.items():
            # requests would decompress a gzipped reply, but this transport
            # hands back curl's raw output, so ask for an uncompressed one
            if name.lower() == "accept-encoding":
                continue
            command += ["--header", f"{name}: {value}"]
        if request.body:
            body = request.body
            command += [
                "--data-binary",
                body.decode() if isinstance(body, bytes) else body,
            ]
        command.append(request.url)
        try:
            task = self.juju.exec(shlex.join(command), unit=self.unit)
        except (jubilant.CLIError, jubilant.TaskError, TimeoutError) as e:
            # curl exits non-zero when it gets no HTTP response at all
            raise requests.ConnectionError(
                f"curl from {self.unit} failed: {e}", request=request
            ) from e

        body, _, status = task.stdout.rpartition("\n")
        response = requests.Response()
        response.status_code = int(status)
        response._content = body.encode()
        response.encoding = "utf-8"
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
