"""MCP tools for script creation, reading, and management.

Top-level: ``script_create``, ``script_attach``, ``script_patch`` (high-traffic).
Everything else (detach, read, find_symbols, reload, find_usages) collapses into
``script_manage``.
"""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import script as script_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Script (.gd / .cs) reading, detachment, and outline.

Resource form: ``godot://script/{path}`` — prefer for active-session reads.

Ops:
  • read(path)
        Read full source, line count, file size.
  • detach(path)
        Remove the currently attached script from a node. Undoable.
  • find_symbols(path)
        Outline a script. .gd: class_name, extends, functions, signals,
        @export vars. .cs: class, base type, methods, [Signal] delegates,
        [Export] members. Response ``language`` says which parser ran.
  • reload(paths=["res://"], reset_static=False)
        Refresh stale loaded GDScripts after files were edited outside the
        editor (hot reload without restarting): every loaded .gd under
        ``paths`` (files or folders) whose file changed on disk is
        recompiled in place, then every loaded script that preloads or
        extends it, dependencies first — so preloaded helpers and test
        dependencies run the new code. reset_static=True also reloads the
        unchanged scripts in ``paths`` without keeping state, which resets
        static variables to their initializers (only @tool scripts run
        initializers in the editor); a script with live instances keeps
        its state and reports ``instances_alive``. A script that fails to
        compile keeps its old code (``failed``, reason parse_error) and its
        dependents are skipped (dependency_failed). Scripts reached only by
        load() or class_name are not followed. The Godot AI plugin's own
        scripts are never reloaded. Not undoable.
  • find_usages(path, symbol="", line=0, column=0,
                include_scene_connections=True, limit=200)
        Semantic references of a GDScript symbol across every .gd in the
        project, from the editor's own GDScript language server (inherited
        calls and other files included). Name the symbol declared in
        ``path`` by ``symbol`` (qualify an ambiguous name as ``Inner.name``
        or ``ClassName.name``) or by its declaration ``line`` (1-based, as
        find_symbols reports it); add ``column`` to query any identifier at
        that position, including a use of a symbol declared elsewhere.
        ``symbol`` in the reply is the declaration with its own ``path``
        (another file for an inherited member), or null when the position
        is not a script declaration's identifier (a native method, a
        keyword). Returns ``usages`` [{path, line, column, end_column,
        is_declaration}] sorted by file, ``usage_count``, ``file_count``,
        ``truncated``. ``resolved=false`` (no usages) means the position
        did not resolve to a symbol, not that it is unused. For a method or
        signal, ``scene_connections`` lists the .tscn/.tres
        ``[connection]`` entries naming it — matched by name only, so a
        same-named method on another script also matches. Reads saved
        files, not unsaved editor buffers; uses by string (``call("x")``)
        and calls on untyped values (``func f(x): x.hit()``) are not found.
        The editor blocks while the server scans (seconds on large
        projects). Errors: LSP_UNAVAILABLE (``data.reason``),
        LSP_WRONG_PROJECT when another editor holds the language-server
        port — launch this editor with ``--lsp-port <port>``.

Language support: GDScript is the full contract. C# (.cs) is text-only —
files are written, read and outlined, but Godot AI does not build .NET or
report C# compiler errors; inspect the editor Build panel or ``dotnet build``
terminal output. ``logs_read`` does not capture .NET compiler output.
"""


def register_script_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def script_create(
        ctx: Context,
        path: str,
        content: str = "",
        session_id: str = "",
    ) -> dict:
        """Create a script file on disk: GDScript (.gd, validated) or C# (.cs, text only).

        Writes content to the path. Overwrites if it exists. Registers the
        file with the editor. New files include ``data.cleanup.rm`` listing
        the file and, when supported by the editor, its ``.uid`` sidecar;
        overwrite omits it.

        .gd: source is parse-validated and the response carries
        ``diagnostics`` (``diagnostics_status="checked"``); an already-loaded
        script is refreshed in place. .cs: written as text only — Godot AI
        does not compile .NET, so ``diagnostics_status="not_checked"`` and
        ``validation_hint`` says to build the project (editor Build button
        or ``dotnet build``) to see compiler errors. ``dotnet_editor``
        reports whether the connected editor build has .NET at all. Any
        other extension is rejected; use filesystem_manage op="write_text".

        Args:
            path: res:// path ending in .gd or .cs (e.g. "res://scripts/player.gd").
            content: GDScript or C# source. Empty creates a blank file.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await script_handlers.script_create(runtime, path=path, content=content)

    @mcp.tool(meta=DEFER_META)
    async def script_patch(
        ctx: Context,
        path: str,
        old_text: str,
        new_text: str,
        replace_all: bool = False,
        session_id: str = "",
    ) -> dict:
        """Anchor-based string-replace edit on a .gd or .cs file.

        Finds an exact ``old_text`` and replaces with ``new_text``. Fails
        on multiple matches unless ``replace_all=True``; fails on zero matches.
        Exact byte match (whitespace significant). Triggers filesystem scan.
        .gd: parse-validated (``diagnostics``) and an already-loaded GDScript
        is refreshed in place so the next call runs the new code (response
        reloaded=true; otherwise reload_reason says why). .cs: text only —
        ``diagnostics_status="not_checked"``, ``reload_reason=
        "csharp_requires_build"``; rebuild the .NET assembly to run it.
        Not undoable via Ctrl+Z.

        Args:
            path: res:// path ending in .gd or .cs.
            old_text: Exact substring to find. Must be unique unless replace_all.
            new_text: Replacement (empty deletes).
            replace_all: Replace every occurrence. Default False.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await script_handlers.script_patch(
            runtime,
            path=path,
            old_text=old_text,
            new_text=new_text,
            replace_all=replace_all,
        )

    @mcp.tool(meta=DEFER_META)
    async def script_attach(
        ctx: Context,
        path: str,
        script_path: str,
        session_id: str = "",
    ) -> dict:
        """Attach a script to a node in the scene tree.

        Replaces any existing script on the node. Undoable.

        Args:
            path: Scene path of the node (e.g. "/Main/Player").
            script_path: res:// path of the .gd (e.g. "res://scripts/player.gd").
                A .cs requires a .NET-enabled editor build; other builds get a
                clear error. Build the assembly before expecting executable behavior.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await script_handlers.script_attach(
            runtime,
            path=path,
            script_path=script_path,
        )

    register_manage_tool(
        mcp,
        tool_name="script_manage",
        description=_DESCRIPTION,
        ops={
            "read": script_handlers.script_read,
            "detach": script_handlers.script_detach,
            "find_symbols": script_handlers.script_find_symbols,
            "reload": script_handlers.script_reload,
            "find_usages": script_handlers.script_find_usages,
        },
        read_resource_forms={
            "read": "godot://script/{path*}",
            "find_symbols": None,  ## Per-script symbol lookup; no resource form.
            "reload": None,  ## Mutates editor state; no resource form.
            "find_usages": None,  ## Per-symbol language-server query; no resource form.
        },
    )
