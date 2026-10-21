"""Integration tests: duplicate_grid, window sizing, input recording and export ops.

Each test drives the real MCP tool through the server to a mock plugin and
checks the command and params that reach the editor, then the reply shape.
"""

from __future__ import annotations

import asyncio

import pytest


async def _call(mcp_stack, tool: str, args: dict, command: str, reply: dict) -> tuple[dict, object]:
    client, plugin = mcp_stack
    seen: dict = {}

    async def respond():
        cmd = await plugin.recv_command()
        seen.update(cmd)
        await plugin.send_response(cmd["request_id"], reply)

    task = asyncio.create_task(respond())
    result = await client.call_tool(tool, args)
    await task
    assert seen["command"] == command
    return seen["params"], result


class TestNodeDuplicateGridTool:
    async def test_duplicate_grid_forwards_steps_and_template(self, mcp_stack):
        reply = {
            "original_path": "/Main/Tile",
            "rows": 2,
            "columns": 2,
            "type": "Node2D",
            "created": [
                {"path": "/Main/Tile_r0c1", "row": 0, "col": 1, "position": {"x": 32, "y": 0}}
            ],
            "count": 3,
            "undoable": True,
        }
        params, result = await _call(
            mcp_stack,
            "node_manage",
            {
                "op": "duplicate_grid",
                "params": {
                    "path": "/Main/Tile",
                    "rows": 2,
                    "columns": 2,
                    "column_step": [32, 0],
                    "row_step": [0, 32],
                    "name_template": "{name}_r{row}c{col}",
                },
            },
            "duplicate_node_grid",
            reply,
        )
        assert params == {
            "path": "/Main/Tile",
            "rows": 2,
            "columns": 2,
            "column_step": [32, 0],
            "row_step": [0, 32],
            "name_template": "{name}_r{row}c{col}",
        }
        assert result.data["count"] == 3
        assert result.data["undoable"] is True


class TestWindowSizeTools:
    async def test_project_run_forwards_window_size(self, mcp_stack):
        params, result = await _call(
            mcp_stack,
            "project_run",
            {"window_size": [800, 500], "autosave": False},
            "run_project",
            {
                "mode": "main",
                "scene": "",
                "autosave": False,
                "undoable": False,
                "window": {"requested": [800, 500], "run_args_found": True},
            },
        )
        assert params["window_size"] == [800, 500]
        assert result.data["window"]["requested"] == [800, 500]

    async def test_window_set_size_is_a_game_command(self, mcp_stack):
        params, result = await _call(
            mcp_stack,
            "game_manage",
            {"op": "window_set_size", "params": {"size": [1024, 640]}},
            "game_command",
            {"requested": [1024, 640], "actual": [1024, 640], "embedded": False, "applied": True},
        )
        assert params == {"op": "window_set_size", "params": {"size": [1024, 640]}}
        assert result.data["applied"] is True


class TestInputRecordingTools:
    @pytest.mark.parametrize(
        ("op", "op_params"),
        [
            ("input_record_start", {"path": "user://takes/a.json"}),
            ("input_record_stop", {}),
            ("input_replay", {"path": "user://takes/a.json"}),
            ("input_replay_status", {}),
        ],
    )
    async def test_recording_ops_are_game_commands(self, mcp_stack, op, op_params):
        params, result = await _call(
            mcp_stack,
            "game_manage",
            {"op": op, "params": op_params},
            "game_command",
            {"op": op, "source": "game"},
        )
        assert params == {"op": op, "params": op_params}
        assert result.data["op"] == op


class TestExportTools:
    async def test_export_presets(self, mcp_stack):
        presets = [{"name": "macOS", "platform": "macOS", "export_path": "builds/a.zip"}]
        _, result = await _call(
            mcp_stack,
            "project_manage",
            {"op": "export_presets"},
            "export_presets",
            {"presets": presets, "count": 1},
        )
        assert result.data["presets"] == presets

    async def test_export_forwards_preset_path_and_debug(self, mcp_stack):
        params, result = await _call(
            mcp_stack,
            "project_manage",
            {"op": "export", "params": {"preset": "macOS", "path": "/tmp/b/a.zip", "debug": False}},
            "export_project",
            {
                "preset": "macOS",
                "path": "/tmp/b/a.zip",
                "debug": False,
                "size_bytes": 10,
                "messages": [],
            },
        )
        assert params == {"preset": "macOS", "path": "/tmp/b/a.zip", "debug": False}
        assert result.data["size_bytes"] == 10
