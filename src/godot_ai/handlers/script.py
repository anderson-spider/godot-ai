"""Shared handlers for script tools."""

from __future__ import annotations

from typing import Any

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.godot_client.lsp import (
    GodotLspSession,
    file_uri,
    loopback_host,
    lsp_error,
    res_path,
    uri_path,
)
from godot_ai.handlers._readiness import require_writable_async
from godot_ai.protocol.errors import ErrorCode
from godot_ai.runtime.direct import DirectRuntime

## LSP SymbolKind values the GDScript language server emits.
_SYMBOL_KINDS = {
    5: "class",
    6: "method",
    7: "property",
    10: "enum",
    12: "function",
    13: "variable",
    14: "constant",
    22: "enum_member",
    24: "signal",
}
_CALLABLE_KINDS = {6, 12}
_SIGNAL_KIND = 24
_USAGE_LIMIT_MAX = 5000


async def script_create(runtime: DirectRuntime, path: str, content: str = "") -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "create_script",
        {"path": path, "content": content},
    )


async def script_patch(
    runtime: DirectRuntime,
    path: str,
    old_text: str,
    new_text: str,
    replace_all: bool = False,
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "patch_script",
        {
            "path": path,
            "old_text": old_text,
            "new_text": new_text,
            "replace_all": replace_all,
        },
    )


async def script_read(runtime: DirectRuntime, path: str) -> dict:
    return await runtime.send_command("read_script", {"path": path})


async def script_attach(runtime: DirectRuntime, path: str, script_path: str) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "attach_script",
        {"path": path, "script_path": script_path},
    )


async def script_detach(runtime: DirectRuntime, path: str) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command("detach_script", {"path": path})


async def script_find_symbols(runtime: DirectRuntime, path: str) -> dict:
    return await runtime.send_command("find_symbols", {"path": path})


async def script_reload(
    runtime: DirectRuntime,
    paths: list[str] | str | None = None,
    reset_static: bool = False,
) -> dict:
    await require_writable_async(runtime)
    params: dict = {"reset_static": reset_static}
    if paths:
        params["paths"] = [paths] if isinstance(paths, str) else list(paths)
    return await runtime.send_command("reload_scripts", params)


def _invalid(message: str, **data: Any) -> GodotCommandError:
    return GodotCommandError(code=ErrorCode.INVALID_PARAMS, message=message, data=data)


def _outline(symbols: list) -> list[dict]:
    """Flatten the language server's symbol tree to declarations with containers.

    The root is the script itself: named after its class_name when it has
    one (a findable symbol, and a valid qualifier: ``Player.hit``), else
    after its file (neither).
    """
    flat: list[dict] = []

    def walk(node: dict, containers: list[str], class_name: str) -> None:
        start = node.get("selectionRange", {}).get("start", {})
        flat.append(
            {
                "name": node.get("name", ""),
                "kind": node.get("kind"),
                "line": int(start.get("line", 0)),
                "character": int(start.get("character", 0)),
                "containers": containers,
                "class_name": class_name,
            }
        )
        for child in node.get("children", []) or []:
            if isinstance(child, dict):
                walk(child, containers + [node.get("name", "")], class_name)

    for root in symbols:
        if not isinstance(root, dict):
            continue
        root_name = str(root.get("name", ""))
        class_name = "" if root_name.endswith(".gd") else root_name
        if class_name:
            walk({**root, "children": []}, [], "")
        for child in root.get("children", []) or []:
            if isinstance(child, dict):
                walk(child, [], class_name)
    return flat


def _names(decl: dict) -> set[str]:
    """Every spelling ``symbol`` may use for ``decl``: bare, by inner class, by class_name."""
    qualified = ".".join(decl["containers"] + [decl["name"]])
    names = {decl["name"], qualified}
    if decl["class_name"]:
        names.add(decl["class_name"] + "." + qualified)
    return names


def _describe(decl: dict) -> dict:
    described = {
        "name": decl["name"],
        "kind": _SYMBOL_KINDS.get(decl["kind"], str(decl["kind"])),
        "line": decl["line"] + 1,
        "column": decl["character"] + 1,
        "container": ".".join(decl["containers"]),
    }
    if "path" in decl:
        described = {"path": decl["path"], **described}
    return described


async def _declaration_at(
    lsp: GodotLspSession, uri: str, position: dict, outlines: dict[str, list[dict]], root: str
) -> dict | None:
    """The declaration the identifier at ``position`` resolves to, or None.

    Godot's ``definition`` answers with the declaration's name range, which
    is the ``selectionRange`` its outline reports, possibly in another file.
    """
    locations, _ = await lsp.request(
        "textDocument/definition", {"textDocument": {"uri": uri}, "position": position}
    )
    if not isinstance(locations, list) or len(locations) != 1:
        return None
    location = locations[0] if isinstance(locations[0], dict) else {}
    decl_uri = str(location.get("uri", ""))
    start = location.get("range", {}).get("start", {})
    if decl_uri not in outlines:
        symbols, _ = await lsp.request(
            "textDocument/documentSymbol", {"textDocument": {"uri": decl_uri}}
        )
        outlines[decl_uri] = _outline(symbols or [])
    for decl in outlines[decl_uri]:
        if decl["line"] == start.get("line") and decl["character"] == start.get("character"):
            return {**decl, "path": res_path(uri_path(decl_uri), root)}
    return None


def _pick_declaration(outline: list[dict], path: str, symbol: str, line: int) -> dict:
    candidates = outline
    if line:
        candidates = [d for d in candidates if d["line"] == line - 1]
    if symbol:
        candidates = [d for d in candidates if symbol in _names(d)]
    if len(candidates) == 1:
        return candidates[0]
    where = f"{symbol!r}" if symbol else f"line {line}"
    if not candidates:
        hint = (
            "pass column too to query an identifier that is used, not declared, there"
            if line and not symbol
            else 'check script_manage(op="find_symbols") for declared names'
        )
        raise GodotCommandError(
            code=ErrorCode.RESOURCE_NOT_FOUND,
            message=f"No declaration of {where} in {path}; {hint}.",
            data={"path": path},
        )
    raise _invalid(
        f"{where} matches {len(candidates)} declarations in {path}; pass line, or "
        "qualify the name with its inner class (Inner.name) or class_name.",
        candidates=[_describe(d) for d in candidates],
    )


async def script_find_usages(
    runtime: DirectRuntime,
    path: str,
    symbol: str = "",
    line: int = 0,
    column: int = 0,
    include_scene_connections: bool = True,
    limit: int = 200,
) -> dict:
    if not symbol and not line:
        raise _invalid("Pass symbol (a declared name) or line, optionally with column.")
    if line < 0 or column < 0 or (column and not line):
        raise _invalid("line and column are 1-based; column needs line.", line=line, column=column)
    if not 1 <= limit <= _USAGE_LIMIT_MAX:
        raise _invalid(f"limit must be between 1 and {_USAGE_LIMIT_MAX}.", limit=limit)

    endpoint = await runtime.send_command("lsp_endpoint", {"path": path})
    if not endpoint.get("available"):
        raise lsp_error(
            "not_in_build",
            "This editor build has no GDScript language server.",
        )
    host = loopback_host(str(endpoint.get("host", "")))
    port = int(endpoint.get("port", 0))
    project_root = str(endpoint.get("project_root", ""))
    uri = file_uri(str(endpoint.get("file", "")))

    async with await GodotLspSession.open(host, port, project_root) as lsp:
        symbols, _ = await lsp.request(
            "textDocument/documentSymbol", {"textDocument": {"uri": uri}}
        )
        outline = _outline(symbols or [])
        if not outline and not column:
            raise lsp_error(
                "no_outline",
                f"The language server returned no outline for {path}; it may not parse. "
                'Check script_manage(op="read") diagnostics.',
                path=path,
            )
        if column:
            position = {"line": line - 1, "character": column - 1}
            declaration = await _declaration_at(lsp, uri, position, {uri: outline}, project_root)
        else:
            declaration = {**_pick_declaration(outline, path, symbol, line), "path": path}
            position = {"line": declaration["line"], "character": declaration["character"]}
        references, _ = await lsp.request(
            "textDocument/references",
            {
                "textDocument": {"uri": uri},
                "position": position,
                "context": {"includeDeclaration": True},
            },
        )

    usages = []
    for ref in references or []:
        start = ref.get("range", {}).get("start", {})
        end = ref.get("range", {}).get("end", {})
        ref_path = res_path(uri_path(str(ref.get("uri", ""))), project_root)
        usage = {
            "path": ref_path,
            "line": int(start.get("line", 0)) + 1,
            "column": int(start.get("character", 0)) + 1,
            "end_column": int(end.get("character", 0)) + 1,
            "is_declaration": declaration is not None
            and ref_path == declaration["path"]
            and int(start.get("line", -1)) == declaration["line"]
            and int(start.get("character", -1)) == declaration["character"],
        }
        usages.append(usage)
    usages.sort(key=lambda u: (u["path"], u["line"], u["column"]))

    result: dict[str, Any] = {
        "path": path,
        "symbol": _describe(declaration) if declaration else None,
        "position": {"line": position["line"] + 1, "column": position["character"] + 1},
        ## Godot always lists a resolved declaration among its references, so
        ## an empty list means the position did not resolve, not "unused".
        "resolved": bool(usages),
        "usages": usages[:limit],
        "usage_count": len(usages),
        "file_count": len({u["path"] for u in usages}),
        "truncated": len(usages) > limit,
        "source": "gdscript_language_server",
        "notes": [
            "Reads saved files: unsaved editor buffers are not included.",
            'Name-based uses (call("x"), connect("x", ...), has_method) are not found.',
            "Calls on a value with no static or inferred type (an untyped parameter) "
            "are not found.",
        ],
    }
    if include_scene_connections and declaration is not None:
        match: dict[str, str] = {}
        if declaration["kind"] in _CALLABLE_KINDS:
            match["method"] = declaration["name"]
        elif declaration["kind"] == _SIGNAL_KIND:
            match["signal"] = declaration["name"]
        if match:
            scan = await runtime.send_command("find_scene_connections", match)
            result["scene_connections"] = scan.get("connections", [])
            result["scene_connections_match"] = "name"
            result["scene_connections_truncated"] = bool(scan.get("truncated"))
            result["scene_connections_skipped_binary"] = int(scan.get("skipped_binary", 0))
    return result
