local M = {}

local NOTES_FILE = "claude-notes.json"
local ns = vim.api.nvim_create_namespace("claude-notes")
local group = vim.api.nvim_create_augroup("claude-notes", { clear = true })

local config = {
  keymaps = true,
  prefix = "<leader>a",
  max_snippet_lines = 80,
  hover = true,
  hover_delay = 500,
}

local STYLE = {
  open = { sign = "✎", hl = "DiagnosticWarn", badge = " ✎ note ", group = "Open" },
  queued = { sign = "⇡", hl = "DiagnosticHint", badge = " ⇡ queued ", group = "Queued" },
  sent = { sign = "…", hl = "DiagnosticInfo", badge = " … Claude working ", group = "Sent" },
  done = { sign = "✓", hl = "DiagnosticOk", badge = " ✓ Claude ", group = "Done" },
}

local function color(name, attr)
  return vim.api.nvim_get_hl(0, { name = name, link = false })[attr]
end

-- Kept apart from the code's own colors: a reversed status badge, then italic text in popup colors.
local function define_highlights()
  local text = {
    fg = color("Pmenu", "fg") or color("Normal", "fg"),
    bg = color("Pmenu", "bg") or color("CursorLine", "bg"),
    italic = true,
    default = true,
  }
  for _, style in pairs(STYLE) do
    vim.api.nvim_set_hl(0, "ClaudeNotesBadge" .. style.group, { fg = color(style.hl, "fg"), reverse = true, bold = true, default = true })
    vim.api.nvim_set_hl(0, "ClaudeNotesText" .. style.group, text)
  end
end

local repos = {}
local marks = {}
local shown

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Claude notes" })
end

local function git(dir, args)
  local cmd = { "git", "-C", dir }
  vim.list_extend(cmd, args)
  local out = vim.system(cmd, { text = true }):wait()
  if out.code ~= 0 then
    return nil, vim.trim(out.stderr or "")
  end
  return vim.trim(out.stdout)
end

local function encode_file(data)
  local notes = {}
  for _, note in ipairs(data.notes) do
    table.insert(notes, vim.json.encode(note))
  end
  -- vim.json encodes an empty table as an object; the mod expects an array.
  return string.format('{"version":1,"root":%s,"notes":[%s]}\n', vim.json.encode(data.root), table.concat(notes, ","))
end

local function read_file(repo)
  local fd = io.open(repo.path, "r")
  if not fd then
    return { version = 1, root = repo.root, notes = {} }
  end
  local text = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= "table" or type(data.notes) ~= "table" then
    return nil, "cannot parse " .. repo.path
  end
  data.root = data.root or repo.root
  return data
end

local function write_file(repo, data)
  local tmp = repo.path .. ".tmp"
  local fd, err = io.open(tmp, "w")
  if not fd then
    error("cannot write " .. tmp .. ": " .. tostring(err))
  end
  fd:write(encode_file(data))
  fd:close()
  local ok, rename_err = vim.uv.fs_rename(tmp, repo.path)
  if not ok then
    error("cannot replace " .. repo.path .. ": " .. tostring(rename_err))
  end
end

local function buf_path(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" then
    return nil
  end
  return vim.uv.fs_realpath(name) or name
end

local function relpath(repo, buf)
  local path = buf_path(buf)
  return path and vim.fs.relpath(repo.root, path)
end

local render

local function repo_buffers(repo)
  local bufs = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.b[buf].claude_notes_path == repo.path then
      table.insert(bufs, buf)
    end
  end
  return bufs
end

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local frame = 1

local function pending(notes)
  local queued, sent = 0, 0
  for _, note in ipairs(notes) do
    if note.status == "queued" then
      queued = queued + 1
    elseif note.status == "sent" then
      sent = sent + 1
    end
  end
  return queued, sent
end

local function redraw_status()
  if package.loaded.lualine then
    require("lualine").refresh({ place = { "statusline" } })
  else
    vim.cmd("redrawstatus")
  end
end

local function stop_spinner()
  local timer = _G.__claude_notes_spinner
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
  _G.__claude_notes_spinner = nil
end

local function sync_spinner()
  local busy = false
  for _, repo in pairs(repos) do
    local queued, sent = pending(repo.notes)
    busy = busy or queued + sent > 0
  end
  if busy and not _G.__claude_notes_spinner then
    local timer = assert(vim.uv.new_timer())
    timer:start(0, 120, vim.schedule_wrap(function()
      frame = frame % #SPINNER + 1
      redraw_status()
    end))
    _G.__claude_notes_spinner = timer
  elseif not busy and _G.__claude_notes_spinner then
    stop_spinner()
    redraw_status()
  end
end

local function render_repo(repo)
  for _, buf in ipairs(repo_buffers(repo)) do
    render(buf)
  end
  sync_spinner()
end

local function announce(before, after)
  local was = {}
  for _, note in ipairs(before) do
    was[note.id] = note.status
  end
  local count = 0
  for _, note in ipairs(after) do
    if note.status == "done" and was[note.id] ~= nil and was[note.id] ~= "done" then
      count = count + 1
    end
  end
  if count > 0 then
    notify(string.format("Claude finished %d note%s", count, count == 1 and "" or "s"))
  end
end

local function reload(repo, attempt)
  local data, err = read_file(repo)
  if not data then
    -- The mod may be mid-write; try again before reporting it.
    if (attempt or 0) < 5 then
      vim.defer_fn(function()
        reload(repo, (attempt or 0) + 1)
      end, 200)
    else
      notify(err, vim.log.levels.ERROR)
    end
    return
  end
  announce(repo.notes, data.notes)
  repo.notes = data.notes
  render_repo(repo)
end

local function watch(repo)
  if repo.watcher then
    return
  end
  local watcher = assert(vim.uv.new_fs_event())
  local pending = false
  local dir = vim.fs.dirname(repo.path)
  watcher:start(dir, {}, function(err, filename)
    if err then
      vim.schedule(function()
        notify("watching " .. dir .. " failed: " .. err, vim.log.levels.ERROR)
      end)
      return
    end
    if filename ~= NOTES_FILE or pending then
      return
    end
    pending = true
    vim.defer_fn(function()
      pending = false
      reload(repo)
    end, 100)
  end)
  repo.watcher = watcher
  table.insert(_G.__claude_notes_watchers, watcher)
end

local function repo_for(buf, quiet)
  local cached = vim.b[buf].claude_notes_path
  if cached and repos[cached] then
    return repos[cached]
  end
  local path = buf_path(buf)
  if not path then
    return nil
  end
  local out, err = git(vim.fs.dirname(path), { "rev-parse", "--show-toplevel", "--absolute-git-dir" })
  if not out then
    if not quiet then
      notify("not in a git repository: " .. err, vim.log.levels.WARN)
    end
    return nil
  end
  local root, gitdir = unpack(vim.split(out, "\n"))
  local notes_path = gitdir .. "/" .. NOTES_FILE
  local repo = repos[notes_path]
  if not repo then
    repo = { root = vim.uv.fs_realpath(root) or root, path = notes_path, notes = {} }
    repos[notes_path] = repo
    local data, read_err = read_file(repo)
    if not data then
      notify(read_err, vim.log.levels.ERROR)
    else
      repo.notes = data.notes
    end
    watch(repo)
  end
  vim.b[buf].claude_notes_path = notes_path
  return repo
end

local function mutate(repo, change)
  local data, err = read_file(repo)
  if not data then
    notify(err, vim.log.levels.ERROR)
    return false
  end
  change(data.notes)
  local ok, write_err = pcall(write_file, repo, data)
  if not ok then
    notify(write_err, vim.log.levels.ERROR)
    return false
  end
  repo.notes = data.notes
  render_repo(repo)
  return true
end

render = function(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  marks[buf] = {}
  local path = vim.b[buf].claude_notes_path
  local repo = path and repos[path]
  if not repo then
    return
  end
  local rel = relpath(repo, buf)
  local count = vim.api.nvim_buf_line_count(buf)
  for _, note in ipairs(repo.notes) do
    if note.file == rel then
      local style = STYLE[note.status] or STYLE.open
      local first = math.min(math.max(note.start - 1, 0), count - 1)
      local last = math.min(math.max(note["end"] - 1, first), count - 1)
      local label = note.text:match("[^\n]*")
      if note.status == "done" then
        label = note.reply or "done"
      end
      local last_line = vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1] or ""
      local id = vim.api.nvim_buf_set_extmark(buf, ns, first, 0, {
        end_row = last,
        end_col = #last_line,
        sign_text = style.sign,
        sign_hl_group = style.hl,
        virt_text = {
          { "  " },
          { style.badge, "ClaudeNotesBadge" .. style.group },
          { " " .. label .. " ", "ClaudeNotesText" .. style.group },
        },
        virt_text_pos = "eol",
        priority = 20,
      })
      marks[buf][id] = note.id
      for row = first + 1, last do
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { sign_text = "┃", sign_hl_group = style.hl, priority = 19 })
      end
    end
  end
end

local function find_note(buf, repo)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local found = vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { overlap = true })
  for _, mark in ipairs(found) do
    local id = marks[buf] and marks[buf][mark[1]]
    if id then
      for _, note in ipairs(repo.notes) do
        if note.id == id then
          return note
        end
      end
    end
  end
  return nil
end

local function note_at_cursor(buf)
  local repo = repo_for(buf)
  if not repo then
    return nil
  end
  local note = find_note(buf, repo)
  if note then
    return repo, note
  end
  notify("no note on this line", vim.log.levels.WARN)
  return nil
end

local function popup(note)
  local style = STYLE[note.status] or STYLE.open
  local lines = { string.format("**%s** · `%s:%d-%d`", vim.trim(style.badge), note.file, note.start, note["end"]), "" }
  if note.reply then
    vim.list_extend(lines, vim.split(note.reply, "\n"))
    vim.list_extend(lines, { "", "---", "", "*Your note:*" })
  end
  vim.list_extend(lines, vim.split(note.text, "\n"))
  local _, win = vim.lsp.util.open_floating_preview(lines, "markdown", {
    border = "rounded",
    focus_id = "claude-notes",
    focus = false,
    max_width = math.min(80, vim.o.columns - 4),
  })
  shown = { win = win, id = note.id }
end

local function is_shown(note)
  return shown ~= nil and shown.id == note.id and vim.api.nvim_win_is_valid(shown.win)
end

local function hover_later()
  local timer = _G.__claude_notes_hover
  if not timer then
    return
  end
  timer:stop()
  timer:start(config.hover_delay, 0, vim.schedule_wrap(function()
    if vim.api.nvim_get_mode().mode ~= "n" then
      return
    end
    local buf = vim.api.nvim_get_current_buf()
    local path = vim.b[buf].claude_notes_path
    local repo = path and repos[path]
    local note = repo and find_note(buf, repo)
    if note and note.status == "done" and not is_shown(note) then
      popup(note)
    end
  end))
end

local function jump(step)
  local buf = vim.api.nvim_get_current_buf()
  local repo = repo_for(buf)
  if not repo then
    return
  end
  local done = vim.tbl_filter(function(note)
    return note.status == "done"
  end, repo.notes)
  if #done == 0 then
    notify("no Claude replies yet")
    return
  end
  table.sort(done, function(a, b)
    return a.file < b.file or (a.file == b.file and a.start < b.start)
  end)
  local rel = relpath(repo, buf) or ""
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local function after(note)
    return note.file > rel or (note.file == rel and note.start > line)
  end
  local target
  if step > 0 then
    for _, note in ipairs(done) do
      if after(note) then
        target = note
        break
      end
    end
    target = target or done[1]
  else
    for i = #done, 1, -1 do
      local note = done[i]
      if note.file < rel or (note.file == rel and note.start < line) then
        target = note
        break
      end
    end
    target = target or done[#done]
  end
  if target.file ~= rel then
    vim.cmd.edit(vim.fn.fnameescape(repo.root .. "/" .. target.file))
  end
  local count = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.min(target.start, count), 0 })
  vim.cmd("normal! zz")
  -- After the jump's own CursorMoved, which would close a popup opened now.
  vim.defer_fn(function()
    popup(target)
  end, 30)
end

function M.next_reply()
  jump(1)
end

function M.prev_reply()
  jump(-1)
end

local function new_id(notes)
  local taken = {}
  for _, note in ipairs(notes) do
    taken[note.id] = true
  end
  while true do
    local id = string.format("%06x", math.random(0, 0xffffff))
    if not taken[id] then
      return id
    end
  end
end

local function editor(title, initial, on_submit)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].completion = false
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial or "", "\n"))
  local width = math.min(80, vim.o.columns - 4)
  local height = math.min(10, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    footer = " <C-s> save · q cancel ",
    footer_pos = "right",
  })
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local function submit()
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    vim.cmd("stopinsert")
    close()
    if text ~= "" then
      on_submit(text)
    end
  end
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf })
  vim.keymap.set("n", "q", close, { buffer = buf })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf })
  if initial == nil or initial == "" then
    vim.cmd("startinsert")
  end
end

function M.add(line1, line2, text)
  local buf = vim.api.nvim_get_current_buf()
  local repo = repo_for(buf)
  if not repo then
    return
  end
  local rel = relpath(repo, buf)
  if not rel then
    notify("this buffer is not a file under " .. repo.root, vim.log.levels.WARN)
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
  if #lines > config.max_snippet_lines then
    lines = vim.list_slice(lines, 1, config.max_snippet_lines)
  end
  local function save(note_text)
    mutate(repo, function(notes)
      table.insert(notes, {
        id = new_id(notes),
        file = rel,
        start = line1,
        ["end"] = line2,
        snippet = table.concat(lines, "\n"),
        text = note_text,
        status = "open",
        createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      })
    end)
  end
  if text and text ~= "" then
    save(text)
  else
    local where = line1 == line2 and tostring(line1) or (line1 .. "-" .. line2)
    editor("Note for Claude · " .. rel .. ":" .. where, "", save)
  end
end

function M.edit()
  local buf = vim.api.nvim_get_current_buf()
  local repo, note = note_at_cursor(buf)
  if not note then
    return
  end
  if note.status ~= "open" then
    notify("only open notes can be edited; this one is " .. note.status, vim.log.levels.WARN)
    return
  end
  editor("Edit note " .. note.id, note.text, function(text)
    mutate(repo, function(notes)
      for _, one in ipairs(notes) do
        if one.id == note.id then
          one.text = text
        end
      end
    end)
  end)
end

function M.delete()
  local buf = vim.api.nvim_get_current_buf()
  local repo, note = note_at_cursor(buf)
  if not note then
    return
  end
  mutate(repo, function(notes)
    for i, one in ipairs(notes) do
      if one.id == note.id then
        table.remove(notes, i)
        return
      end
    end
  end)
end

function M.show()
  local buf = vim.api.nvim_get_current_buf()
  local _, note = note_at_cursor(buf)
  if not note then
    return
  end
  popup(note)
end

function M.list()
  local repo = repo_for(vim.api.nvim_get_current_buf(), true)
  if not repo then
    local out = git(vim.fn.getcwd(), { "rev-parse", "--absolute-git-dir" })
    repo = out and repos[out .. "/" .. NOTES_FILE]
  end
  if not repo then
    notify("open a file in the repository first", vim.log.levels.WARN)
    return
  end
  local items = {}
  for _, note in ipairs(repo.notes) do
    local text = string.format("[%s] %s", note.status, note.text:match("[^\n]*"))
    if note.reply then
      text = text .. "  ↳ " .. note.reply
    end
    table.insert(items, { filename = repo.root .. "/" .. note.file, lnum = note.start, end_lnum = note["end"], text = text })
  end
  vim.fn.setqflist({}, " ", { title = "Claude notes", items = items })
  vim.cmd("copen")
end

function M.send()
  local repo = repo_for(vim.api.nvim_get_current_buf())
  if not repo then
    return
  end
  local count = 0
  local ok = mutate(repo, function(notes)
    for _, note in ipairs(notes) do
      if note.status == "open" then
        note.status = "queued"
        count = count + 1
      end
    end
  end)
  if not ok then
    return
  end
  if count == 0 then
    notify("no open notes to send")
  else
    notify(string.format("Queued %d note%s for Claude", count, count == 1 and "" or "s"))
  end
end

function M.clear()
  local repo = repo_for(vim.api.nvim_get_current_buf())
  if not repo then
    return
  end
  mutate(repo, function(notes)
    for i = #notes, 1, -1 do
      if notes[i].status == "done" then
        table.remove(notes, i)
      end
    end
  end)
end

local function sync_positions(buf)
  local path = vim.b[buf].claude_notes_path
  local repo = path and repos[path]
  if not repo or not marks[buf] then
    return
  end
  local moved = {}
  for mark_id, note_id in pairs(marks[buf]) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark_id, { details = true })
    if pos[1] then
      moved[note_id] = { start = pos[1] + 1, ["end"] = (pos[3].end_row or pos[1]) + 1 }
    end
  end
  local changed = false
  for _, note in ipairs(repo.notes) do
    local to = moved[note.id]
    if to and note.status ~= "done" and (to.start ~= note.start or to["end"] ~= note["end"]) then
      changed = true
    end
  end
  if not changed then
    return
  end
  mutate(repo, function(notes)
    for _, note in ipairs(notes) do
      local to = moved[note.id]
      if to and note.status ~= "done" then
        note.start, note["end"] = to.start, to["end"]
      end
    end
  end)
end

function M.status()
  local path = vim.b.claude_notes_path
  local repo = path and repos[path]
  if not repo then
    return ""
  end
  local queued, sent = pending(repo.notes)
  if queued + sent == 0 then
    return ""
  end
  local parts = {}
  if sent > 0 then
    table.insert(parts, sent .. " in progress")
  end
  if queued > 0 then
    table.insert(parts, queued .. " queued")
  end
  return SPINNER[frame] .. " Claude: " .. table.concat(parts, " · ")
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  -- A reload (:Lazy reload) gets a fresh module; the previous one's watchers would keep firing.
  for _, old in ipairs(_G.__claude_notes_watchers or {}) do
    if not old:is_closing() then
      old:stop()
      old:close()
    end
  end
  _G.__claude_notes_watchers = {}
  _G.__claude_notes_hover = nil
  if config.hover then
    _G.__claude_notes_hover = assert(vim.uv.new_timer())
    table.insert(_G.__claude_notes_watchers, _G.__claude_notes_hover)
  end
  stop_spinner()
  math.randomseed(vim.uv.hrtime())
  define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_highlights })

  vim.api.nvim_create_user_command("ClaudeNote", function(o)
    M.add(o.line1, o.line2, o.args)
  end, { range = true, nargs = "*", desc = "Leave a note for Claude on the line or range" })
  vim.api.nvim_create_user_command("ClaudeNoteEdit", M.edit, { desc = "Edit the open note on this line" })
  vim.api.nvim_create_user_command("ClaudeNoteDelete", M.delete, { desc = "Delete the note on this line" })
  vim.api.nvim_create_user_command("ClaudeNoteShow", M.show, { desc = "Show the note on this line" })
  vim.api.nvim_create_user_command("ClaudeNotes", M.list, { desc = "List Claude notes in quickfix" })
  vim.api.nvim_create_user_command("ClaudeNoteNext", M.next_reply, { desc = "Jump to the next Claude reply" })
  vim.api.nvim_create_user_command("ClaudeNotePrev", M.prev_reply, { desc = "Jump to the previous Claude reply" })
  vim.api.nvim_create_user_command("ClaudeNotesSend", M.send, { desc = "Queue open notes for Claude" })
  vim.api.nvim_create_user_command("ClaudeNotesClear", M.clear, { desc = "Remove resolved Claude notes" })

  if config.keymaps then
    local p = config.prefix
    vim.keymap.set("n", p .. "a", "<cmd>ClaudeNote<CR>", { desc = "Claude: note on line" })
    vim.keymap.set("x", p .. "a", ":ClaudeNote<CR>", { desc = "Claude: note on selection", silent = true })
    vim.keymap.set("n", p .. "e", M.edit, { desc = "Claude: edit note" })
    vim.keymap.set("n", p .. "d", M.delete, { desc = "Claude: delete note" })
    vim.keymap.set("n", p .. "s", M.show, { desc = "Claude: show note" })
    vim.keymap.set("n", p .. "l", M.list, { desc = "Claude: list notes" })
    vim.keymap.set("n", p .. "n", M.next_reply, { desc = "Claude: next reply" })
    vim.keymap.set("n", p .. "p", M.prev_reply, { desc = "Claude: previous reply" })
    vim.keymap.set("n", p .. "S", M.send, { desc = "Claude: send open notes" })
    vim.keymap.set("n", p .. "c", M.clear, { desc = "Claude: clear resolved notes" })
  end

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    callback = function(ev)
      if repo_for(ev.buf, true) then
        render(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      sync_positions(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      marks[ev.buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", { group = group, callback = hover_later })

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and repo_for(buf, true) then
      render(buf)
    end
  end
end

return M
