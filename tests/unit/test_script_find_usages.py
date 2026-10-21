"""script_manage(op="find_usages"): the Python LSP client and handler.

A fake language server stands in for the editor's. Its replies copy the
shapes Godot 4.7.2 sends: a changeWorkspace notification ahead of the
initialize response when rootPath is not the editor's project, a one-root
documentSymbol tree, 0-based Location lists for references and definition.
"""

from __future__ import annotations

import asyncio
import json
from collections.abc import Callable
from typing import Any

import pytest

from godot_ai.godot_client import lsp as lsp_module
from godot_ai.godot_client.client import GodotCommandError
from godot_ai.godot_client.lsp import (
    GodotLspSession,
    file_uri,
    loopback_host,
    res_path,
    same_root,
    uri_path,
)
from godot_ai.handlers import script as script_handlers
from godot_ai.protocol.errors import ErrorCode

ROOT = "/projects/game"
PLAYER = ROOT + "/player.gd"
ENEMY = ROOT + "/enemy.gd"


def _range(line: int, start: int, end: int) -> dict:
    return {
        "start": {"line": line, "character": start},
        "end": {"line": line, "character": end},
    }


def _symbol(name: str, kind: int, line: int, start: int, children=None) -> dict:
    node = {
        "name": name,
        "kind": kind,
        "detail": "",
        "deprecated": False,
        "range": _range(line, 0, 40),
        "selectionRange": _range(line, start, start + len(name)),
    }
    if children is not None:
        node["children"] = children
    return node


## player.gd: class_name Player, func hit() on line 5, signal died on line 2,
## inner class Stats (line 9) with its own hit() on line 10.
PLAYER_OUTLINE = [
    _symbol(
        "Player",
        5,
        0,
        11,
        [
            _symbol("died", 24, 2, 7),
            _symbol("hit", 6, 5, 5),
            _symbol("Stats", 5, 9, 6, [_symbol("hit", 6, 10, 6)]),
        ],
    )
]
## enemy.gd has no class_name: its root is named after the file.
ENEMY_OUTLINE = [_symbol("enemy.gd", 5, 0, 0, [_symbol("attack", 6, 3, 5)])]


def _location(path: str, line: int, start: int, end: int) -> dict:
    return {"uri": file_uri(path), "range": _range(line, start, end)}


class FakeLanguageServer:
    def __init__(self, root: str = ROOT):
        self.root = root
        self.received: list[dict] = []
        self.handlers: dict[str, Callable[[dict], Any]] = {
            "textDocument/documentSymbol": self._document_symbol,
            "textDocument/references": lambda params: [],
            "textDocument/definition": lambda params: [],
        }
        self.server: asyncio.Server | None = None
        self.port = 0

    def _document_symbol(self, params: dict) -> list:
        uri = params["textDocument"]["uri"]
        return {file_uri(PLAYER): PLAYER_OUTLINE, file_uri(ENEMY): ENEMY_OUTLINE}.get(uri, [])

    async def __aenter__(self) -> FakeLanguageServer:
        self.server = await asyncio.start_server(self._serve, "127.0.0.1", 0)
        self.port = self.server.sockets[0].getsockname()[1]
        return self

    async def __aexit__(self, *exc_info: object) -> None:
        assert self.server is not None
        self.server.close()
        await self.server.wait_closed()

    @staticmethod
    async def _send(writer: asyncio.StreamWriter, message: dict) -> None:
        body = json.dumps(message).encode()
        writer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        await writer.drain()

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            while True:
                header = await reader.readuntil(b"\r\n\r\n")
                length = int(header.split(b":")[1].split(b"\r\n")[0])
                message = json.loads(await reader.readexactly(length))
                self.received.append(message)
                if "id" not in message:
                    continue
                method = message["method"]
                if method == "initialize":
                    await self._send(
                        writer,
                        {
                            "jsonrpc": "2.0",
                            "method": "window/showMessage",
                            "params": {"type": 2, "message": "noise"},
                        },
                    )
                    if message["params"]["rootPath"] != self.root:
                        await self._send(
                            writer,
                            {
                                "jsonrpc": "2.0",
                                "method": lsp_module.CHANGE_WORKSPACE,
                                "params": {"path": self.root},
                            },
                        )
                    result: Any = {"capabilities": {}}
                else:
                    result = self.handlers[method](message["params"])
                await self._send(writer, {"jsonrpc": "2.0", "id": message["id"], "result": result})
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            writer.close()

    def methods(self) -> list[str]:
        return [m.get("method", "") for m in self.received]

    def last(self, method: str) -> dict:
        return [m for m in self.received if m.get("method") == method][-1]["params"]


class StubRuntime:
    def __init__(self, port: int, *, root: str = ROOT, host: str = "127.0.0.1", **endpoint):
        self.calls: list[tuple[str, dict]] = []
        self.endpoint = {
            "available": True,
            "host": host,
            "port": port,
            "port_source": "editor_settings",
            "project_root": root,
            **endpoint,
        }
        self.connections: list[dict] = []

    async def send_command(self, command: str, params: dict | None = None, **_: Any) -> dict:
        self.calls.append((command, params or {}))
        if command == "lsp_endpoint":
            relative = (params or {})["path"].removeprefix("res://")
            return {**self.endpoint, "file": ROOT + "/" + relative}
        if command == "find_scene_connections":
            return {"connections": self.connections, "truncated": False, "skipped_binary": 1}
        raise AssertionError(f"unexpected command {command}")


# ----- helpers ---------------------------------------------------------------


def test_file_uri_matches_godot_encoding() -> None:
    assert file_uri("/projects/my game/a.gd") == "file:///projects/my%20game/a.gd"
    assert file_uri("C:/Games/x.gd") == "file:///C%3A/Games/x.gd"


def test_uri_path_round_trips_and_drops_slash_before_a_drive() -> None:
    assert uri_path(file_uri("/projects/my game/a.gd")) == "/projects/my game/a.gd"
    assert uri_path(file_uri("C:/Games/x.gd")) == "C:/Games/x.gd"


def test_res_path_maps_only_inside_the_root() -> None:
    assert res_path("/projects/game/a/b.gd", ROOT) == "res://a/b.gd"
    assert res_path("/projects/GAME/a.gd", ROOT) == "res://a.gd"
    assert res_path("/projects/game2/a.gd", ROOT) == "/projects/game2/a.gd"
    assert res_path("C:\\Games\\x.gd", "C:/Games") == "res://x.gd"


def test_same_root_ignores_case_trailing_slash_and_separators() -> None:
    assert same_root("/Projects/Game/", "/projects/game")
    assert same_root("C:\\Games", "c:/games/")
    assert not same_root("/projects/game2", "/projects/game")


@pytest.mark.parametrize(
    ("host", "dialed"),
    [
        ("127.0.0.1", "127.0.0.1"),
        ("", "127.0.0.1"),
        ("0.0.0.0", "127.0.0.1"),
        ("localhost", "127.0.0.1"),
        ("::", "::1"),
        ("::1", "::1"),
        ("127.0.0.2", "127.0.0.2"),
    ],
)
def test_loopback_host_dials_loopback(host: str, dialed: str) -> None:
    assert loopback_host(host) == dialed


@pytest.mark.parametrize("host", ["192.168.1.20", "example.com", "10.0.0.1"])
def test_loopback_host_refuses_anything_else(host: str) -> None:
    with pytest.raises(GodotCommandError) as excinfo:
        loopback_host(host)
    assert excinfo.value.code == ErrorCode.LSP_UNAVAILABLE
    assert excinfo.value.data["reason"] == "non_loopback_host"


# ----- session ---------------------------------------------------------------


async def test_session_initializes_without_the_initialized_notification() -> None:
    async with FakeLanguageServer() as server:
        async with await GodotLspSession.open("127.0.0.1", server.port, ROOT) as lsp:
            result, notes = await lsp.request(
                "textDocument/documentSymbol", {"textDocument": {"uri": file_uri(PLAYER)}}
            )
        assert result[0]["name"] == "Player"
        assert notes == []
        init = server.received[0]
        assert init["method"] == "initialize"
        assert init["params"]["rootPath"] == ROOT
        assert init["params"]["rootUri"] == file_uri(ROOT)
        ## `initialized` makes Godot push its whole class reference.
        assert "initialized" not in server.methods()


async def test_session_refuses_another_editors_language_server() -> None:
    async with FakeLanguageServer(root="/projects/other") as server:
        with pytest.raises(GodotCommandError) as excinfo:
            await GodotLspSession.open("127.0.0.1", server.port, ROOT)
    error = excinfo.value
    assert error.code == ErrorCode.LSP_WRONG_PROJECT
    assert error.data == {
        "port": server.port,
        "lsp_root": "/projects/other",
        "expected_root": ROOT,
    }
    assert "--lsp-port" in error.message


async def test_session_accepts_a_change_workspace_that_names_the_same_root() -> None:
    ## Godot compares rootPath verbatim, so a trailing slash alone draws a
    ## changeWorkspace naming the very same project.
    async with FakeLanguageServer(root=ROOT) as server:
        session = await GodotLspSession.open("127.0.0.1", server.port, ROOT + "/")
        await session.close()


async def test_session_reports_a_closed_port() -> None:
    async with FakeLanguageServer() as server:
        port = server.port
    with pytest.raises(GodotCommandError) as excinfo:
        await GodotLspSession.open("127.0.0.1", port, ROOT)
    assert excinfo.value.code == ErrorCode.LSP_UNAVAILABLE
    assert excinfo.value.data["reason"] == "connect_failed"
    assert excinfo.value.data["port"] == port


async def test_session_times_out_a_silent_server(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(lsp_module, "REQUEST_TIMEOUT", 0.2)

    async def silent(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        await reader.read()
        writer.close()

    server = await asyncio.start_server(silent, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    try:
        with pytest.raises(GodotCommandError) as excinfo:
            await GodotLspSession.open("127.0.0.1", port, ROOT)
    finally:
        server.close()
        await server.wait_closed()
    assert excinfo.value.data["reason"] == "timeout"


async def test_session_rejects_a_bad_content_length() -> None:
    async def garbage(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        await reader.readuntil(b"\r\n\r\n")
        writer.write(b"Content-Length: lots\r\n\r\n{}")
        await writer.drain()
        await reader.read()
        writer.close()

    server = await asyncio.start_server(garbage, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    try:
        with pytest.raises(GodotCommandError) as excinfo:
            await GodotLspSession.open("127.0.0.1", port, ROOT)
    finally:
        server.close()
        await server.wait_closed()
    assert excinfo.value.data["reason"] == "protocol_error"


# ----- handler ---------------------------------------------------------------


async def test_find_usages_by_symbol_queries_its_declaration() -> None:
    async with FakeLanguageServer() as server:
        server.handlers["textDocument/references"] = lambda params: [
            _location(ENEMY, 7, 4, 7),
            _location(PLAYER, 5, 5, 8),
            _location(PLAYER, 20, 2, 5),
        ]
        runtime = StubRuntime(server.port)
        runtime.connections = [{"path": "res://main.tscn", "line": 9, "method": "hit"}]
        result = await script_handlers.script_find_usages(
            runtime, "res://player.gd", symbol="Player.hit"
        )
        references = server.last("textDocument/references")

    assert runtime.calls[0] == ("lsp_endpoint", {"path": "res://player.gd"})
    assert references["position"] == {"line": 5, "character": 5}
    assert references["textDocument"]["uri"] == file_uri(PLAYER)
    assert result["symbol"] == {
        "path": "res://player.gd",
        "name": "hit",
        "kind": "method",
        "line": 6,
        "column": 6,
        "container": "",
    }
    assert result["usages"] == [
        {
            "path": "res://enemy.gd",
            "line": 8,
            "column": 5,
            "end_column": 8,
            "is_declaration": False,
        },
        {
            "path": "res://player.gd",
            "line": 6,
            "column": 6,
            "end_column": 9,
            "is_declaration": True,
        },
        {
            "path": "res://player.gd",
            "line": 21,
            "column": 3,
            "end_column": 6,
            "is_declaration": False,
        },
    ]
    assert result["usage_count"] == 3
    assert result["file_count"] == 2
    assert result["resolved"] is True
    assert result["truncated"] is False
    assert runtime.calls[1] == ("find_scene_connections", {"method": "hit"})
    assert result["scene_connections"] == runtime.connections
    assert result["scene_connections_match"] == "name"
    assert result["scene_connections_skipped_binary"] == 1


async def test_find_usages_reports_ambiguous_names_with_candidates() -> None:
    async with FakeLanguageServer() as server:
        with pytest.raises(GodotCommandError) as excinfo:
            await script_handlers.script_find_usages(
                StubRuntime(server.port), "res://player.gd", symbol="hit"
            )
    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    candidates = excinfo.value.data["candidates"]
    assert [(c["line"], c["container"]) for c in candidates] == [(6, ""), (11, "Stats")]


async def test_find_usages_qualified_inner_class_member() -> None:
    async with FakeLanguageServer() as server:
        await script_handlers.script_find_usages(
            StubRuntime(server.port), "res://player.gd", symbol="Stats.hit"
        )
        assert server.last("textDocument/references")["position"] == {
            "line": 10,
            "character": 6,
        }


async def test_find_usages_by_declaration_line() -> None:
    async with FakeLanguageServer() as server:
        result = await script_handlers.script_find_usages(
            StubRuntime(server.port), "res://player.gd", line=3, include_scene_connections=False
        )
    assert result["symbol"]["name"] == "died"
    assert result["symbol"]["kind"] == "signal"
    assert "scene_connections" not in result


async def test_find_usages_matches_signals_against_connection_signals() -> None:
    async with FakeLanguageServer() as server:
        runtime = StubRuntime(server.port)
        await script_handlers.script_find_usages(runtime, "res://player.gd", symbol="died")
    assert runtime.calls[-1] == ("find_scene_connections", {"signal": "died"})


async def test_find_usages_skips_scene_scan_for_variables() -> None:
    async with FakeLanguageServer() as server:
        runtime = StubRuntime(server.port)
        result = await script_handlers.script_find_usages(
            runtime, "res://player.gd", symbol="Stats"
        )
    assert result["symbol"]["kind"] == "class"
    assert [command for command, _ in runtime.calls] == ["lsp_endpoint"]


async def test_find_usages_file_root_without_class_name_is_not_a_symbol() -> None:
    async with FakeLanguageServer() as server:
        with pytest.raises(GodotCommandError) as excinfo:
            await script_handlers.script_find_usages(
                StubRuntime(server.port), "res://enemy.gd", symbol="enemy.gd"
            )
    assert excinfo.value.code == ErrorCode.RESOURCE_NOT_FOUND


async def test_find_usages_class_name_root_is_a_symbol() -> None:
    async with FakeLanguageServer() as server:
        result = await script_handlers.script_find_usages(
            StubRuntime(server.port), "res://player.gd", symbol="Player"
        )
        assert server.last("textDocument/references")["position"] == {
            "line": 0,
            "character": 11,
        }
    assert result["symbol"]["kind"] == "class"


async def test_find_usages_at_a_use_site_resolves_the_declaration_elsewhere() -> None:
    async with FakeLanguageServer() as server:
        server.handlers["textDocument/definition"] = lambda params: [_location(PLAYER, 5, 5, 8)]
        server.handlers["textDocument/references"] = lambda params: [
            _location(PLAYER, 5, 5, 8),
            _location(ENEMY, 3, 9, 12),
        ]
        runtime = StubRuntime(server.port)
        result = await script_handlers.script_find_usages(
            runtime, "res://enemy.gd", line=4, column=10
        )
        definition = server.last("textDocument/definition")
        references = server.last("textDocument/references")

    assert definition["position"] == {"line": 3, "character": 9}
    assert references["position"] == {"line": 3, "character": 9}
    assert references["textDocument"]["uri"] == file_uri(ENEMY)
    assert result["symbol"]["path"] == "res://player.gd"
    assert result["symbol"]["name"] == "hit"
    assert [u["is_declaration"] for u in result["usages"]] == [False, True]
    assert runtime.calls[-1] == ("find_scene_connections", {"method": "hit"})


async def test_find_usages_unresolved_position_is_not_reported_as_unused() -> None:
    async with FakeLanguageServer() as server:
        result = await script_handlers.script_find_usages(
            StubRuntime(server.port), "res://player.gd", line=1, column=1
        )
    assert result["symbol"] is None
    assert result["resolved"] is False
    assert result["usages"] == []
    assert "scene_connections" not in result


async def test_find_usages_truncates_to_limit_but_counts_everything() -> None:
    async with FakeLanguageServer() as server:
        server.handlers["textDocument/references"] = lambda params: [
            _location(PLAYER, line, 1, 4) for line in range(10)
        ]
        result = await script_handlers.script_find_usages(
            StubRuntime(server.port),
            "res://player.gd",
            symbol="Player.hit",
            limit=3,
            include_scene_connections=False,
        )
    assert len(result["usages"]) == 3
    assert result["usage_count"] == 10
    assert result["truncated"] is True


async def test_find_usages_without_outline_is_an_error_not_an_empty_answer() -> None:
    async with FakeLanguageServer() as server:
        server.handlers["textDocument/documentSymbol"] = lambda params: []
        with pytest.raises(GodotCommandError) as excinfo:
            await script_handlers.script_find_usages(
                StubRuntime(server.port), "res://player.gd", symbol="hit"
            )
    assert excinfo.value.code == ErrorCode.LSP_UNAVAILABLE
    assert excinfo.value.data["reason"] == "no_outline"


async def test_find_usages_refuses_an_editor_build_without_language_server() -> None:
    runtime = StubRuntime(1, available=False)
    with pytest.raises(GodotCommandError) as excinfo:
        await script_handlers.script_find_usages(runtime, "res://player.gd", symbol="hit")
    assert excinfo.value.data["reason"] == "not_in_build"


async def test_find_usages_refuses_a_non_loopback_host_before_connecting() -> None:
    runtime = StubRuntime(1, host="192.168.0.5")
    with pytest.raises(GodotCommandError) as excinfo:
        await script_handlers.script_find_usages(runtime, "res://player.gd", symbol="hit")
    assert excinfo.value.data["reason"] == "non_loopback_host"


@pytest.mark.parametrize(
    "kwargs",
    [
        {},
        {"column": 3},
        {"line": -1},
        {"symbol": "hit", "limit": 0},
        {"symbol": "hit", "limit": 5001},
    ],
)
async def test_find_usages_validates_params_before_any_call(kwargs: dict) -> None:
    runtime = StubRuntime(1)
    with pytest.raises(GodotCommandError) as excinfo:
        await script_handlers.script_find_usages(runtime, "res://player.gd", **kwargs)
    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    assert runtime.calls == []
