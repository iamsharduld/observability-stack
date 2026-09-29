# Copyright 2026 Canonical Ltd.
# See LICENSE file for licensing details.
"""Relay HTTP requests into the pod network for runners without direct access.

Set SOLUTION_HTTP_RELAY to an application name to run curl in its leader unit
via juju exec. Leave it unset to send requests directly.
"""

import os
import shlex

import jubilant
import requests
from requests.adapters import BaseAdapter


class JujuExecAdapter(BaseAdapter):
    """Send requests through curl in a Juju unit."""

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
        # Keep the status code on a separate final line for parsing.
        command += ["--write-out", "\n%{http_code}"]
        for name, value in request.headers.items():
            # This adapter returns curl's raw output without decompression.
            if name.lower() == "accept-encoding":
                continue
            command += ["--header", f"{name}: {value}"]
        body = request.body
        if body:
            command += [
                "--data-binary",
                body.decode() if isinstance(body, bytes) else body,
            ]
        command.append(request.url)
        try:
            task = self.juju.exec(shlex.join(command), unit=self.unit)
        except (jubilant.CLIError, jubilant.TaskError, TimeoutError) as error:
            raise requests.ConnectionError(
                f"curl from {self.unit} failed: {error}", request=request
            ) from error

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
    app = os.environ.get("SOLUTION_HTTP_RELAY")
    if app:
        adapter = JujuExecAdapter(juju, f"{app}/leader")
        session.mount("http://", adapter)
        session.mount("https://", adapter)
    return session
