# claude-notes.nvim

Leave review notes on lines of code while you read it in Neovim, and have a Claude Code session work through them. Instead of copying code into a prompt, you mark the line or block, write what you want, and send. Claude's reply comes back next to the code.

```
✎ note       a line you left a note on
⇡ queued     sent, waiting for a Claude session to pick it up
… working    Claude is on it
✓ Claude     done, with the first line of Claude's reply at the end of the line
┃            the rest of a multi-line note's range
```

## How it works

Notes live in one JSON file per repository, inside its git directory (`.git/claude-notes.json`), so they never show up in `git status` or get committed. Each git worktree has its own.

This plugin only writes and reads that file. The other half is the **nvim-notes** Claude Code mod, which is not in this repo: a Claude Code session running it in the same repository picks up queued notes, sends them to Claude as one prompt, and records each reply back into the file through a `resolve_note` tool Claude calls. The plugin sees the file change and updates the signs.

Note text and the code around it are sent to the model, so keep customer data and secrets out of notes.

## Requirements

- Neovim 0.11 or newer (tested on 0.12)
- git
- Claude Code with the nvim-notes mod loaded, e.g. `claude --plugin-dir <path to the mod>`

## Install

lazy.nvim:

```lua
{
  "carloscastrojumo/claude-notes.nvim",
  lazy = false,
  opts = {},
}
```

## Workflow

1. Start Claude Code in the repository with the mod loaded, and run `/notes watch` in that session. Only a watching session picks up notes, so with several sessions open in one repo you choose which one works on them.
2. In Neovim, put the cursor on a line (or select a block) and press `<leader>aa`. Write the note in the popup and press `<C-s>`.
3. Leave as many notes as you like, across files.
4. Save the files you noted, then press `<leader>aS` to send. Claude reads the files on disk, so sending is refused while a buffer with open notes has unsaved changes. The status line shows a spinner while Claude works.
5. When a note is done you get a "Claude finished N notes" notification, the sign turns to `✓` and the reply shows at the end of the line. Rest the cursor on the line to read the whole reply, or press `<leader>an` to walk through every reply.

If Claude changed a file you have open, reload it with `:e` (or `:checktime`).

## Keys and commands

| Key | Command | What it does |
| --- | --- | --- |
| `<leader>aa` (normal) | `:ClaudeNote [text]` | Note on the current line; opens the editor unless text is given |
| `<leader>aa` (visual) | `:'<,'>ClaudeNote` | Note on the selected lines |
| `<leader>aS` | `:ClaudeNotesSend` | Queue every open note for Claude |
| `<leader>an` | `:ClaudeNoteNext` | Jump to the next Claude reply, across files, and pop it up |
| `<leader>ap` | `:ClaudeNotePrev` | Jump to the previous reply |
| `<leader>as` | `:ClaudeNoteShow` | Show the note on this line and its reply |
| `<leader>ae` | `:ClaudeNoteEdit` | Edit the note on this line, while it is still open |
| `<leader>ad` | `:ClaudeNoteDelete` | Delete the note on this line; open, queued and done notes can go, a note Claude is working on cannot |
| `<leader>al` | `:ClaudeNotes` | All notes in the quickfix list, for the current buffer's repository or else the working directory's |
| `<leader>ac` | `:ClaudeNotesClear` | Remove the done notes |

In the note editor: `<C-s>` saves (insert or normal mode), `q` or `<Esc>` cancels and asks first if you wrote something.

Notes follow your edits: while a buffer has unsaved changes its signs stay on the code they were placed on, and saving records the new lines for open and queued notes. Notes Claude has taken stay where they were. If you delete every line a note covers, the note stays at its old line and you get a warning, instead of sliding onto the code next to it.

If a note is sent while you are editing it, saving the edit leaves the note alone and puts your text in the `"` register.

## Status line

`require("claude-notes").status()` returns a spinner and counts for the current buffer's repository while notes are queued or with Claude (`⠹ Claude: 2 in progress · 1 queued`), and an empty string otherwise. If no queued or in-progress note has changed status for `stale_after` seconds (no Claude session is watching, or it stopped), the spinner stops and the text says so (`Claude: 1 queued · no update for 12m`). After a restart that time counts from the notes file's last change. For lualine:

```lua
lualine_x = {
  {
    function() return require("claude-notes").status() end,
    cond = function() return package.loaded["claude-notes"] ~= nil end,
    color = "DiagnosticInfo",
  },
},
```

## Options

Defaults:

```lua
require("claude-notes").setup({
  keymaps = true,          -- set the keys above
  prefix = "<leader>a",    -- prefix for every key
  max_snippet_lines = 80,  -- lines of code stored with a note
  -- Lua patterns on the lowercased repo-relative path; matching files get no snippet copied
  snippet_exclude = { "%.env$", "%.env%.", "%.pem$", "%.key$", "id_rsa", "id_ed25519", "secrets?%." },
  hover = true,            -- pop up a done note's reply when the cursor rests on it
  hover_delay = 500,       -- ms before the popup
  max_label = 120,         -- characters of note or reply shown at the end of the line
  max_range_signs = 200,   -- range signs drawn for a long note
  max_notes = 500,         -- notes drawn per file
  stale_after = 600,       -- seconds without a change before pending notes count as stuck
  git_timeout = 2000,      -- ms for the git call that finds a buffer's repository
})
```

`snippet_exclude` replaces the default list when given. Claude still reads the file itself when it works on the note; the exclusion only keeps a copy of those lines out of the notes file.

## Colors

The text at the end of a line is a badge in the status color, then the note or reply in your popup-menu colors, so it doesn't read as code. Define any of these groups to override them:

- `ClaudeNotesBadgeOpen`, `ClaudeNotesBadgeQueued`, `ClaudeNotesBadgeSent`, `ClaudeNotesBadgeDone`
- `ClaudeNotesTextOpen`, `ClaudeNotesTextQueued`, `ClaudeNotesTextSent`, `ClaudeNotesTextDone`

Signs use `DiagnosticWarn`, `DiagnosticHint`, `DiagnosticInfo` and `DiagnosticOk`.

## The notes file

```json
{
  "version": 1,
  "root": "/path/to/repo",
  "notes": [
    {
      "id": "a85e4e",
      "file": "src/app.go",
      "start": 4,
      "end": 4,
      "snippet": "\tprintln(\"hi\")",
      "text": "make this print hello world instead",
      "status": "done",
      "createdAt": "2026-10-13T13:57:49Z",
      "reply": "Changed println(\"hi\") to println(\"hello world\").",
      "resolvedAt": "2026-10-13T13:58:00.279Z",
      "claimedBy": "<Claude session id>"
    }
  ]
}
```

`status` is `open`, `queued`, `sent` or `done`. The plugin sets `open` and `queued`; the mod sets `sent`, `done`, `reply` and `claimedBy`.

Both sides rewrite the whole file. The plugin writes a temp file (mode `0600`, since notes hold code), syncs it and renames it over the old one, so a failed write leaves the old file intact. It keeps fields it doesn't know about, re-checks the file just before replacing it, and redoes its change on the fresh copy if the mod wrote in between or the read caught the mod mid-write (up to five tries). Nothing locks the file, so a mod write landing in the instant between that check and the rename can still be lost.

A note is skipped with a warning, and left in the file untouched, when it is not an object; its `id`, `text` or `file` is missing, empty or not a string; its `status` is unknown; `start` and `end` are not whole numbers with `1 <= start <= end <= 10000000`; `reply` is set but not a string; or `file` is absolute or contains `..`, a backslash or a control character. Neither a jump nor the quickfix list opens a file that resolves outside the repository, for example through a symlink.

## Tests

```sh
nvim --headless --clean -u NONE --cmd "set rtp+=." -l tests/run.lua
```

Each case builds its own scratch git repository in a temp directory. They are removed when every case passes and kept for inspection when one fails.
