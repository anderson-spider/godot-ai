"""Minimal client for the Godot editor's GDScript language server.

Backs ``script_manage(op="find_usages")``. The language server is reachable
only over its own TCP port: in Godot 4.7 the parse cache it resolves symbols
against is per connected client, so calling the bound ``references`` method
in-process without a client returns an empty list instead of failing.

Two editors cannot both listen on the default port, and the second one's
language server fails to start. A client that reached the wrong editor would
get empty answers for every file of this project, so the session proves
ownership first: ``initialize`` carries this project's root, and Godot answers
a mismatch with a ``gdscript_client/changeWorkspace`` notification naming its
own root before the response.

The session never sends ``initialized``; that notification makes Godot push
its whole native class reference (several MB) to the client.
"""

from __future__ import annotations

import asyncio
import ipaddress
import json
from typing import Any
from urllib.parse import quote, unquote, urlsplit

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.protocol.errors import ErrorCode

CHANGE_WORKSPACE = "gdscript_client/changeWorkspace"
CONNECT_TIMEOUT = 3.0
## Godot answers `references` synchronously while it scans every .gd in the
## project; large projects take several seconds.
REQUEST_TIMEOUT = 60.0
MAX_MESSAGE_BYTES = 32 * 1024 * 1024


def lsp_error(reason: str, message: str, **data: Any) -> GodotCommandError:
    return GodotCommandError(
        code=ErrorCode.LSP_UNAVAILABLE, message=message, data={"reason": reason, **data}
    )


def loopback_host(host: str) -> str:
    """The address to dial for a language server bound to ``host``.

    The server binds the editor setting's host; a wildcard bind is dialed on
    loopback. Anything that is not loopback is refused: Godot AI never
    leaves the machine.
    """
    value = host.strip()
    if value in ("", "*", "0.0.0.0") or value.lower() == "localhost":
        return "127.0.0.1"
    if value == "::":
        return "::1"
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        address = None
    if address is None or not address.is_loopback:
        raise lsp_error(
            "non_loopback_host",
            f"The GDScript language server is configured for host {host!r}; "
            "find_usages only connects over loopback. Set the editor setting "
            "network/language_server/remote_host to 127.0.0.1.",
            host=host,
        )
    return value


def file_uri(path: str) -> str:
    """A file URI built the way Godot's ``GDScriptWorkspace::get_file_uri`` does."""
    parts = path.replace("\\", "/").lstrip("/").split("/")
    return "file:///" + "/".join(quote(part, safe="") for part in parts)


def uri_path(uri: str) -> str:
    path = unquote(urlsplit(uri).path)
    ## file:///C:/x decodes to /C:/x; drop the slash before a drive letter.
    if len(path) > 2 and path[0] == "/" and path[2] == ":":
        path = path[1:]
    return path


def same_root(a: str, b: str) -> bool:
    """Godot compares workspace roots case-insensitively, separators as given."""

    def norm(value: str) -> str:
        return value.replace("\\", "/").rstrip("/").lower()

    return norm(a) == norm(b)


def res_path(path: str, project_root: str) -> str:
    """``path`` as res:// when it lies under ``project_root``, else unchanged."""
    root = project_root.replace("\\", "/").rstrip("/")
    value = path.replace("\\", "/")
    if value.lower().startswith(root.lower() + "/"):
        return "res://" + value[len(root) + 1 :]
    return path


class GodotLspSession:
    """One verified connection; use ``async with await GodotLspSession.open(...)``."""

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self._reader = reader
        self._writer = writer
        self._next_id = 0

    @classmethod
    async def open(cls, host: str, port: int, project_root: str) -> GodotLspSession:
        try:
            async with asyncio.timeout(CONNECT_TIMEOUT):
                reader, writer = await asyncio.open_connection(host, port)
        except (OSError, TimeoutError) as exc:
            raise lsp_error(
                "connect_failed",
                f"Could not reach the GDScript language server at {host}:{port} ({exc}). "
                "The editor starts it once the editor is ready; if another editor "
                "already held the port, this one logged 'Failed to start GDScript "
                "language server' in Output. Launch the editor with --lsp-port <port> "
                "to give it a port of its own.",
                host=host,
                port=port,
            ) from exc
        session = cls(reader, writer)
        try:
            await session._initialize(project_root, port)
        except BaseException:
            await session.close()
            raise
        return session

    async def __aenter__(self) -> GodotLspSession:
        return self

    async def __aexit__(self, *exc_info: object) -> None:
        await self.close()

    async def close(self) -> None:
        self._writer.close()
        try:
            await self._writer.wait_closed()
        except (OSError, ConnectionError):
            pass

    async def _initialize(self, project_root: str, port: int) -> None:
        _, notifications = await self.request(
            "initialize",
            {
                "processId": None,
                "rootPath": project_root,
                "rootUri": file_uri(project_root),
                "capabilities": {},
            },
        )
        for note in notifications:
            if note.get("method") != CHANGE_WORKSPACE:
                continue
            params = note.get("params")
            lsp_root = params.get("path", "") if isinstance(params, dict) else ""
            if not same_root(lsp_root, project_root):
                raise GodotCommandError(
                    code=ErrorCode.LSP_WRONG_PROJECT,
                    message=(
                        f"The language server on port {port} belongs to the editor of "
                        f"{lsp_root!r}, not {project_root!r}. Two editors cannot share "
                        "the port: launch this one with --lsp-port <free port>."
                    ),
                    data={"port": port, "lsp_root": lsp_root, "expected_root": project_root},
                )

    async def request(self, method: str, params: dict) -> tuple[Any, list[dict]]:
        """Send one request; return its result and the notifications read before it."""
        self._next_id += 1
        request_id = self._next_id
        body = json.dumps(
            {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        ).encode("utf-8")
        notifications: list[dict] = []
        try:
            async with asyncio.timeout(REQUEST_TIMEOUT):
                self._writer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
                await self._writer.drain()
                while True:
                    message = await self._read_message()
                    if message.get("id") == request_id and "method" not in message:
                        break
                    if "method" in message:
                        notifications.append(message)
        except TimeoutError as exc:
            raise lsp_error(
                "timeout",
                f"The GDScript language server did not answer {method} within "
                f"{REQUEST_TIMEOUT:.0f}s.",
                method=method,
            ) from exc
        except (OSError, ConnectionError, asyncio.IncompleteReadError) as exc:
            raise lsp_error(
                "connection_closed",
                f"The GDScript language server closed the connection during {method}.",
                method=method,
            ) from exc
        if "error" in message:
            raise lsp_error(
                "request_failed",
                f"The GDScript language server rejected {method}: {message['error']}",
                method=method,
            )
        return message.get("result"), notifications

    async def _read_message(self) -> dict:
        try:
            header = await self._reader.readuntil(b"\r\n\r\n")
        except asyncio.LimitOverrunError as exc:
            raise lsp_error("protocol_error", "Oversized LSP message header") from exc
        length = -1
        for line in header.decode("ascii", errors="replace").split("\r\n"):
            name, _, value = line.partition(":")
            if name.strip().lower() == "content-length" and value.strip().isdigit():
                length = int(value.strip())
        if length < 0 or length > MAX_MESSAGE_BYTES:
            raise lsp_error("protocol_error", f"Bad LSP Content-Length header: {header!r}")
        payload = await self._reader.readexactly(length)
        try:
            message = json.loads(payload)
        except ValueError as exc:
            raise lsp_error("protocol_error", "The language server sent invalid JSON") from exc
        if not isinstance(message, dict):
            raise lsp_error("protocol_error", "The language server sent a non-object message")
        return message
