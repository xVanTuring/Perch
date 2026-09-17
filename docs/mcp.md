# MCP server (Agent access to notes)

Perch can expose a local [MCP](https://modelcontextprotocol.io) server so an
AI agent (Claude Code, etc.) can read and edit your notes directly, without
going through the GUI.

## Architecture

Hand-rolled JSON-RPC 2.0 over HTTP, no MCP SDK dependency — same approach as
the sibling project [uni-reader](https://github.com/xVanTuring/uni-reader)'s
`Sources/MCP/`. The server runs inside the main Perch process (not a separate
binary), listening via `Network.framework`'s `NWListener` on its own dispatch
queue. Every request is a single POST to `/mcp`; no SSE/streaming, no
persistent connections — one TCP connection per call.

All note/group mutations go through `MCPFacade` (`Sources/Perch/MCP/MCPFacade.swift`),
which calls the exact same methods the GUI uses (`FloatingNotesRegistry.delete`,
`Note.create`, etc.) — an MCP-triggered delete is a normal soft-delete to
Trash, a "pinned" note really opens a floating sticky window, and so on.

## Enabling it

Settings → Agent:

1. **Enable MCP server** — starts/stops immediately, no restart needed.
2. **Allow connections from other devices** — off by default (127.0.0.1
   only). Turning this on listens on all network interfaces; anyone on your
   LAN with the token could read/write your notes.
3. **Allow agents to write** — off by default. While off, only read tools
   work; write tools (create/edit/delete/…) return a clear error telling the
   agent the toggle is disabled.
4. Copy the **access token** (stored in the Keychain) and either of the
   ready-made client config snippets shown at the bottom of the tab.

Every request requires `Authorization: Bearer <token>`.

## Tools

Read (always available):

| Tool | Description |
|---|---|
| `get_state` | Note/group counts, whether write access is enabled |
| `list_notes` | List notes by scope (active/archived/trashed), group, pinned |
| `get_note` | Full content + metadata for one note |
| `search_notes` | Case-insensitive substring search over content |
| `list_groups` | All groups with note counts |

Write (requires "Allow agents to write"):

| Tool | Description |
|---|---|
| `create_note` | Create a note; `pinned:true` also opens it as a sticky |
| `update_note` | Replace a note's content |
| `move_note` | Assign/remove a note's group |
| `set_note_pinned` | Open/close the note's floating sticky window |
| `archive_note` / `unarchive_note` | Move to/from Archive |
| `delete_note` / `restore_note` | Soft-delete to/from Trash |
| `create_group` | Create a new group |

Deliberately left out of v1 (destructive or out of scope): permanent delete,
empty trash, window geometry/display assignment, task checkbox toggling,
import/export.

## Manual testing

```sh
TOKEN="<paste from Settings → Agent>"
URL="http://127.0.0.1:8774/mcp"

curl -s -X POST "$URL" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_state","arguments":{}}}'
```

Or register it with Claude Code:

```sh
claude mcp add --transport http perch http://127.0.0.1:8774/mcp \
  --header "Authorization: Bearer $TOKEN"
```
