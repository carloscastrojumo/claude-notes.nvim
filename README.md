<p align="center"><img src="assets/icon.svg" width="128" alt=""></p>

# claude-notes.nvim

Leave notes on code as you read it in Neovim, then hand them to Claude Code in one go. Mark a line or a block, say what you want changed, send. Claude's reply shows up next to the code, so you stop pasting snippets into prompts.

```
✎ note       you left a note here
⇡ queued     sent, waiting for a Claude session to pick it up
… working    Claude is on it
? asks       Claude needs your answer before it can do this one
✓ Claude     done; the first line of the reply sits at the end of the line
```

Notes are stored in `.git/claude-notes.json`, so they never get committed. The other half is the **nvim-notes** Claude Code mod (not in this repo): a session running it picks up your notes, works through them, and writes each reply back. Notes and the code they point at go to the model, so keep secrets and customer data out of them.

## Install

Needs Neovim 0.11+, git, and Claude Code with the nvim-notes mod (`claude --plugin-dir <mod>`).

```lua
{ "carloscastrojumo/claude-notes.nvim", lazy = false, opts = {} }
```

## Use

1. In Claude Code, run `/notes watch` in the session that should work on your notes.
2. In Neovim, press `<leader>aa` on a line or a visual selection, write the note, `<C-s>` to save.
3. Save your files and press `<leader>aS` to send. Unsaved buffers with notes block the send, because Claude reads the files on disk.
4. If Claude needs more from you, the note turns `?` and you get a notification. Save the file, then answer with `<leader>ar`; the note goes back to Claude with the question and your answer.
5. You get a notification as replies come in. Rest the cursor on a `✓` line to read the whole reply, or walk through them with `<leader>an`.

| Key | Command | |
| --- | --- | --- |
| `<leader>aa` | `:[range]ClaudeNote [text]` | Note on the line or selection |
| `<leader>aS` | `:ClaudeNotesSend` | Send open notes |
| `<leader>ar` | `:ClaudeNoteReply` | Answer Claude's question on this line |
| `<leader>an` / `<leader>ap` | `:ClaudeNoteNext` / `:ClaudeNotePrev` | Next / previous reply or question |
| `<leader>as` | `:ClaudeNoteShow` | Show the note and reply on this line |
| `<leader>ae` | `:ClaudeNoteEdit` | Edit a note that hasn't been sent |
| `<leader>ad` | `:ClaudeNoteDelete` | Delete a note (not while Claude is working on it) |
| `<leader>al` | `:ClaudeNotes` | List notes in quickfix |
| `<leader>ac` | `:ClaudeNotesClear` | Clear done notes |

Notes follow your edits and record their new lines when you save the file. If you delete a note's code, it stays put and you get a warning. If a note can't be saved, your text lands in the `"` register.

## Status line

`require("claude-notes").status()` shows a spinner while notes are with Claude (`⠹ Claude: 1 question · 2 in progress`) and says so when nothing has moved for `stale_after` seconds. With lualine:

```lua
lualine_x = { { function() return require("claude-notes").status() end, color = "DiagnosticInfo" } },
```

## Options

```lua
require("claude-notes").setup({
  keymaps = true,
  prefix = "<leader>a",
  max_snippet_lines = 80,  -- code lines stored with a note
  snippet_exclude = { "%.env$", "%.env%.", "%.pem$", "%.key$", "id_rsa", "id_ed25519", "secrets?%." },
  hover = true,            -- pop up a reply when the cursor rests on it
  hover_delay = 500,
  max_label = 120,         -- characters shown at the end of the line
  max_range_signs = 200,
  max_notes = 500,         -- per file, and in the quickfix list
  stale_after = 600,       -- seconds
  git_timeout = 2000,      -- ms
})
```

`snippet_exclude` holds Lua patterns for paths whose code is never copied into the notes file. Colors come from `ClaudeNotesBadge{Open,Queued,Sent,Question,Done}` and `ClaudeNotesText{Open,Queued,Sent,Question,Done}`; define them to override.

## Known limitations

Nothing locks the notes file, so a mod write that lands at the exact moment of a Neovim write can be lost. A save can wait up to ~200 ms while the mod is mid-write. A repository created inside a directory Neovim already knows isn't noticed until you `:cd`. One Neovim per repository is assumed.

## Tests

```sh
nvim --headless --clean -u NONE --cmd "set rtp+=." -l tests/run.lua
```
