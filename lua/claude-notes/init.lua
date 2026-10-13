local M = {}

local NOTES_FILE = "claude-notes.json"
local MAX_FILE_BYTES = 5 * 1024 * 1024
local MAX_LINE = 10000000
local MAX_POPUP_CHARS = 20000
local FILE_MODE = 384 -- 0600: notes hold code snippets
local WRITE_ATTEMPTS = 5
local WRITE_RETRY_MS = 50
local RELOAD_ATTEMPTS = 5
local RELOAD_RETRY_MS = 200
local WATCH_DEBOUNCE_MS = 100
local WATCH_RESTARTS = 3
local WATCH_RESTART_MS = 1000
local SPINNER_MS = 120
-- Opens the popup after the jump's own CursorMoved, which closes any preview opened before it.
local POPUP_AFTER_JUMP_MS = 30
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local STATUSES = { open = true, queued = true, sent = true, question = true, done = true }

local DEFAULTS = {
  keymaps = true,
  prefix = "<leader>a",
  max_snippet_lines = 80,
  snippet_exclude = { "%.env$", "%.env%.", "%.pem$", "%.key$", "id_rsa", "id_ed25519", "secrets?%." },
  hover = true,
  hover_delay = 500,
  max_label = 120,
  max_range_signs = 200,
  max_notes = 500,
  stale_after = 600,
  git_timeout = 2000,
}

local STYLE = {
  open = { sign = "✎", hl = "DiagnosticWarn", badge = " ✎ note ", group = "Open" },
  queued = { sign = "⇡", hl = "DiagnosticHint", badge = " ⇡ queued ", group = "Queued" },
  sent = { sign = "…", hl = "DiagnosticInfo", badge = " … Claude working ", group = "Sent" },
  question = { sign = "?", hl = "DiagnosticError", badge = " ? Claude asks ", group = "Question" },
  done = { sign = "✓", hl = "DiagnosticOk", badge = " ✓ Claude ", group = "Done" },
}

local ns = vim.api.nvim_create_namespace("claude-notes")
local anchor_ns = vim.api.nvim_create_namespace("claude-notes-anchor")
local config = vim.deepcopy(DEFAULTS)

local function new_state()
  return { repos = {}, marks = {}, orphans = {}, no_repo = {}, dir_repo = {}, orphan_warned = {}, crowded_warned = {}, frame = 1 }
end

local state = new_state()

-- Survives :Lazy reload, which loads a fresh module while the old one's timers keep running.
_G.__claude_notes = _G.__claude_notes or {}
local registry = _G.__claude_notes
registry.open = registry.open or {}

local function track(handle)
  table.insert(registry.open, handle)
  return handle
end

local function close(handle)
  if not handle then
    return
  end
  if not handle:is_closing() then
    handle:stop()
    handle:close()
  end
  for i, open in ipairs(registry.open) do
    if open == handle then
      table.remove(registry.open, i)
      break
    end
  end
end

local function teardown()
  for i = #registry.open, 1, -1 do
    close(registry.open[i])
  end
  -- Earlier versions of this plugin kept their timers and watchers under `handles`.
  for _, handle in ipairs(registry.handles or {}) do
    if not handle:is_closing() then
      handle:stop()
      handle:close()
    end
  end
  registry.open, registry.handles, registry.spinner, registry.hover = {}, nil, nil, nil
end

local function now()
  local t = vim.uv.clock_gettime("realtime")
  return t.sec + t.nsec / 1e9
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Claude notes" })
end

local function plural(n, word)
  return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

local function one_line(text, max)
  local line = text:match("[^\n]*"):gsub("%c", " ")
  local cut = text:find("\n") ~= nil
  if vim.fn.strchars(line) > max then
    line, cut = vim.fn.strcharpart(line, 0, max), true
  end
  return cut and (line .. " …") or line
end

local function range_label(note)
  return note.start == note["end"] and tostring(note.start) or (note.start .. "-" .. note["end"])
end

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

local function git(dir, args)
  local cmd = { "git", "-C", dir }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { text = true }):wait(config.git_timeout)
  if result.code == 124 then
    return nil, string.format("git timed out after %d ms", config.git_timeout)
  end
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or "")
  end
  return vim.trim(result.stdout)
end

local function is_relative_path(file)
  if file == "" or file:sub(1, 1) == "/" or file:find("%c") or file:find("\\", 1, true) then
    return false
  end
  for part in file:gmatch("[^/]+") do
    if part == ".." then
      return false
    end
  end
  return true
end

-- The mod and anything else can write this file, so a note is only shown or acted on once its shape checks out.
local function is_valid(note)
  if type(note) ~= "table" or not STATUSES[note.status] then
    return false
  end
  if type(note.id) ~= "string" or note.id == "" or type(note.text) ~= "string" then
    return false
  end
  if type(note.file) ~= "string" or not is_relative_path(note.file) then
    return false
  end
  local start, stop = note.start, note["end"]
  if type(start) ~= "number" or type(stop) ~= "number" or start % 1 ~= 0 or stop % 1 ~= 0 then
    return false
  end
  if start < 1 or stop < start or stop > MAX_LINE then
    return false
  end
  if note.reply ~= nil and type(note.reply) ~= "string" then
    return false
  end
  if note.thread == nil then
    return true
  end
  if type(note.thread) ~= "table" then
    return false
  end
  for _, entry in ipairs(note.thread) do
    if type(entry) ~= "table" or (entry.from ~= "claude" and entry.from ~= "you") or type(entry.text) ~= "string" then
      return false
    end
  end
  return true
end

local function last_question(note)
  local entry = note.thread and note.thread[#note.thread]
  return entry and entry.from == "claude" and entry.text or nil
end

local function split_valid(notes)
  local valid, invalid = {}, 0
  for _, note in ipairs(notes) do
    if is_valid(note) then
      table.insert(valid, note)
    else
      invalid = invalid + 1
    end
  end
  return valid, invalid
end

local function stat_key(stat)
  if not stat then
    return "missing"
  end
  return string.format("%d.%d:%d:%d", stat.mtime.sec, stat.mtime.nsec, stat.size, stat.ino)
end

local function read_file(repo)
  local stat = vim.uv.fs_stat(repo.path)
  if not stat then
    return { version = 1, root = repo.root, notes = {} }, nil
  end
  if stat.size > MAX_FILE_BYTES then
    return nil, nil, repo.path .. " is larger than 5 MB"
  end
  local fd = io.open(repo.path, "r")
  if not fd then
    return nil, nil, "cannot open " .. repo.path
  end
  local text = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true } })
  if not ok or type(data) ~= "table" or type(data.notes) ~= "table" then
    return nil, nil, "cannot parse " .. repo.path
  end
  if type(data.root) ~= "string" then
    data.root = repo.root
  end
  return data, stat
end

local function write_file(repo, data)
  local tmp = string.format("%s.%d.%d.tmp", repo.path, vim.uv.os_getpid(), vim.uv.hrtime())
  local text = vim.json.encode(data) .. "\n"
  local fd, open_err = vim.uv.fs_open(tmp, "w", FILE_MODE)
  if not fd then
    error("cannot write " .. tmp .. ": " .. tostring(open_err))
  end
  local written, write_err = vim.uv.fs_write(fd, text)
  local synced, sync_err = vim.uv.fs_fsync(fd)
  -- Some network and FUSE mounts have no fsync; the rename still replaces the file whole.
  if not synced and (tostring(sync_err):match("^EINVAL") or tostring(sync_err):match("^ENOTSUP")) then
    synced = true
  end
  local closed, close_err = vim.uv.fs_close(fd)
  local err = (written ~= #text and (write_err or "short write")) or (not synced and sync_err) or (not closed and close_err)
  if not err then
    local renamed, rename_err = vim.uv.fs_rename(tmp, repo.path)
    err = not renamed and rename_err
  end
  if err then
    vim.uv.fs_unlink(tmp)
    error("cannot replace " .. repo.path .. ": " .. tostring(err))
  end
  return vim.uv.fs_stat(repo.path)
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

local function cached_repo(buf)
  local path = vim.b[buf].claude_notes_path
  return path and state.repos[path]
end

local function repo_buffers(repo)
  local bufs = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.b[buf].claude_notes_path == repo.path then
      table.insert(bufs, buf)
    end
  end
  return bufs
end

local function find_by_id(notes, id)
  for i, note in ipairs(notes) do
    if type(note) == "table" and note.id == id then
      return note, i
    end
  end
  return nil
end

-- Returns the real path, or nil with why; is_outside tells a symlink escape from a missing file.
local function file_of(repo, file)
  local path = repo.root .. "/" .. file
  local real = vim.uv.fs_realpath(path)
  if not real then
    return nil, file .. " no longer exists", false
  end
  if not vim.fs.relpath(repo.root, real) then
    return nil, file .. " resolves outside the repository", true
  end
  return real
end

local function count_pending(notes)
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

local function is_stale(repo)
  return now() - repo.changed_at > config.stale_after
end

local function is_busy(repo)
  local queued, sent = count_pending(repo.notes)
  return queued + sent > 0 and not is_stale(repo)
end

local function redraw_status()
  if package.loaded.lualine then
    require("lualine").refresh({ place = { "statusline" } })
  else
    vim.cmd("redrawstatus")
  end
end

local function sync_spinner()
  local busy = false
  for _, repo in pairs(state.repos) do
    busy = busy or is_busy(repo)
  end
  if busy and not registry.spinner then
    registry.spinner = track(assert(vim.uv.new_timer()))
    registry.spinner:start(0, SPINNER_MS, vim.schedule_wrap(function()
      state.frame = state.frame % #SPINNER + 1
      redraw_status()
      sync_spinner()
    end))
  elseif not busy and registry.spinner then
    close(registry.spinner)
    registry.spinner = nil
    redraw_status()
  end
end

-- With unsaved edits the marks know where the code is now and the file does not, so they are kept.
local function live_positions(buf)
  local live, orphans = {}, state.orphans[buf] or {}
  if not vim.bo[buf].modified then
    return live, {}
  end
  for mark_id, note_id in pairs(state.marks[buf] or {}) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark_id, { details = true })
    if pos[1] and pos[3].invalid then
      orphans[note_id] = true
    elseif pos[1] then
      live[note_id] = { first = pos[1], last = pos[3].end_row or pos[1] }
    end
  end
  return live, orphans
end

local function render(buf)
  local live, orphans = live_positions(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  state.marks[buf] = {}
  state.orphans[buf] = orphans
  local repo = cached_repo(buf)
  if not repo then
    return
  end
  local rel = relpath(repo, buf)
  local count = vim.api.nvim_buf_line_count(buf)
  local drawn = 0
  for _, note in ipairs(repo.notes) do
    if note.file == rel and drawn >= config.max_notes then
      if not state.crowded_warned[buf] then
        state.crowded_warned[buf] = true
        notify(string.format("%s has more than %d notes; only the first %d are shown", rel, config.max_notes, config.max_notes), vim.log.levels.WARN)
      end
      break
    end
    if note.file == rel then
      drawn = drawn + 1
      local style = STYLE[note.status]
      local at = live[note.id]
      local first = math.min(at and at.first or (note.start - 1), count - 1)
      local last = math.min(math.max(at and at.last or (note["end"] - 1), first), count - 1)
      local label = note.text
      if note.status == "done" then
        label = note.reply or "done"
      elseif note.status == "question" then
        label = last_question(note) or note.text
      end
      label = one_line(label, config.max_label)
      local last_line = vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1] or ""
      local id = vim.api.nvim_buf_set_extmark(buf, ns, first, 0, {
        end_row = last,
        end_col = #last_line,
        invalidate = true,
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
      state.marks[buf][id] = note.id
      for row = first + 1, math.min(last, first + config.max_range_signs) do
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { sign_text = "┃", sign_hl_group = style.hl, priority = 19 })
      end
    end
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
  local finished, asked = 0, 0
  for _, note in ipairs(after) do
    if was[note.id] ~= nil and was[note.id] ~= note.status then
      finished = finished + (note.status == "done" and 1 or 0)
      asked = asked + (note.status == "question" and 1 or 0)
    end
  end
  if finished > 0 then
    notify("Claude finished " .. plural(finished, "note"))
  end
  if asked > 0 then
    notify(string.format("Claude has a question on %s; answer with %sr", plural(asked, "note"), config.prefix), vim.log.levels.WARN)
  end
end

local function pending_statuses(notes)
  local by_id = {}
  for _, note in ipairs(notes) do
    if note.status == "queued" or note.status == "sent" then
      by_id[note.id] = note.status
    end
  end
  return by_id
end

-- Only a pending note moving on counts; new or edited open notes say nothing about Claude.
local function is_progress(before, after)
  local was, is = pending_statuses(before), pending_statuses(after)
  for id, status in pairs(was) do
    if is[id] ~= status then
      return true
    end
  end
  for id in pairs(is) do
    if not was[id] then
      return true
    end
  end
  return false
end

local function apply(repo, data, stat)
  local valid, invalid = split_valid(data.notes)
  announce(repo.notes, valid)
  if invalid ~= repo.invalid and invalid > 0 then
    notify(string.format("skipping %s in %s: malformed", plural(invalid, "note"), repo.path), vim.log.levels.WARN)
  end
  if not repo.is_loaded then
    repo.changed_at = stat and (stat.mtime.sec + stat.mtime.nsec / 1e9) or now()
  elseif is_progress(repo.notes, valid) then
    repo.changed_at = now()
  end
  repo.is_loaded = true
  repo.invalid = invalid
  repo.notes = valid
  render_repo(repo)
end

local function reload(repo, attempt)
  attempt = attempt or 0
  if state.repos[repo.path] ~= repo then
    return
  end
  local stat = vim.uv.fs_stat(repo.path)
  if stat and stat_key(stat) == repo.written then
    return
  end
  local data, read_stat, err = read_file(repo)
  if not data then
    -- The mod may be mid-write; try again before reporting it.
    if attempt < RELOAD_ATTEMPTS then
      vim.defer_fn(function()
        reload(repo, attempt + 1)
      end, RELOAD_RETRY_MS)
    else
      notify(err, vim.log.levels.ERROR)
    end
    return
  end
  apply(repo, data, read_stat)
end

-- change returns "reject", "skip" or nothing (write); nothing locks the file, so it is re-checked before replacing.
local function update_notes(repo, change)
  local err
  for attempt = 1, WRITE_ATTEMPTS do
    if attempt > 1 then
      vim.uv.sleep(WRITE_RETRY_MS)
    end
    local data, stat, read_err = read_file(repo)
    err = read_err or "the notes file kept changing while saving; try again"
    if data then
      local ok, verdict = pcall(change, data.notes)
      if not ok then
        notify(tostring(verdict), vim.log.levels.ERROR)
        return false, "error"
      end
      if verdict == "reject" then
        return false, "rejected"
      end
      if verdict == "skip" then
        return true, "unchanged"
      end
      if stat_key(vim.uv.fs_stat(repo.path)) == stat_key(stat) then
        local written_ok, written = pcall(write_file, repo, data)
        if not written_ok then
          notify(tostring(written), vim.log.levels.ERROR)
          return false, "error"
        end
        repo.written = stat_key(written)
        apply(repo, data, written)
        return true
      end
    end
  end
  notify(err, vim.log.levels.WARN)
  return false, "busy"
end

local function watch(repo, restarts)
  restarts = restarts or 0
  local watcher = track(assert(vim.uv.new_fs_event()))
  local is_due = false
  local dir = vim.fs.dirname(repo.path)
  watcher:start(dir, {}, function(err, filename)
    if err then
      vim.schedule(function()
        close(watcher)
        if state.repos[repo.path] ~= repo then
          return
        end
        if restarts < WATCH_RESTARTS then
          notify(string.format("watching %s failed (%s); restarting", dir, err), vim.log.levels.WARN)
          vim.defer_fn(function()
            if state.repos[repo.path] == repo then
              watch(repo, restarts + 1)
            end
          end, WATCH_RESTART_MS)
        else
          notify(string.format("watching %s failed (%s); restart Neovim to see Claude's replies", dir, err), vim.log.levels.ERROR)
        end
      end)
      return
    end
    if filename ~= NOTES_FILE or is_due then
      return
    end
    is_due = true
    vim.defer_fn(function()
      is_due = false
      reload(repo)
    end, WATCH_DEBOUNCE_MS)
  end)
end

local function repo_at(dir, quiet)
  local known = state.dir_repo[dir]
  if known and state.repos[known] then
    return state.repos[known]
  end
  if quiet and state.no_repo[dir] then
    return nil
  end
  local out, err = git(dir, { "rev-parse", "--show-toplevel", "--absolute-git-dir" })
  if not out then
    state.no_repo[dir] = true
    if not quiet then
      notify("not in a git repository: " .. err, vim.log.levels.WARN)
    end
    return nil
  end
  state.no_repo[dir] = nil
  local root, gitdir = unpack(vim.split(out, "\n"))
  local notes_path = gitdir .. "/" .. NOTES_FILE
  state.dir_repo[dir] = notes_path
  local repo = state.repos[notes_path]
  if not repo then
    repo = { root = vim.uv.fs_realpath(root) or root, path = notes_path, notes = {}, invalid = 0, changed_at = now() }
    state.repos[notes_path] = repo
    reload(repo)
    watch(repo)
  end
  return repo
end

local function repo_for(buf, quiet)
  local repo = cached_repo(buf)
  if repo then
    return repo
  end
  local path = buf_path(buf)
  if not path then
    return nil
  end
  repo = repo_at(vim.fs.dirname(path), quiet)
  if repo then
    vim.b[buf].claude_notes_path = repo.path
  end
  return repo
end

local function note_under_cursor(buf, repo)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { overlap = true })) do
    local id = state.marks[buf] and state.marks[buf][mark[1]]
    local note = id and find_by_id(repo.notes, id)
    if note then
      return note
    end
  end
  return nil
end

local function note_at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local repo = repo_for(buf)
  if not repo then
    return nil
  end
  local note = note_under_cursor(buf, repo)
  if not note then
    notify("no note on this line", vim.log.levels.WARN)
    return nil
  end
  return repo, note
end

local function capped(text)
  if vim.fn.strchars(text) <= MAX_POPUP_CHARS then
    return text
  end
  return vim.fn.strcharpart(text, 0, MAX_POPUP_CHARS) .. "\n\n… (cut; the rest is in the notes file)"
end

local function popup(note)
  local style = STYLE[note.status]
  local file = note.file:gsub("`", "'")
  local lines = { string.format("**%s** · `%s:%s`", vim.trim(style.badge), file, range_label(note)), "" }
  if note.reply then
    vim.list_extend(lines, vim.split(capped(note.reply), "\n"))
    vim.list_extend(lines, { "", "---", "" })
  end
  vim.list_extend(lines, { "*Your note:*" })
  vim.list_extend(lines, vim.split(capped(note.text), "\n"))
  for _, entry in ipairs(note.thread or {}) do
    vim.list_extend(lines, { "", entry.from == "claude" and "**Claude asked:**" or "*You answered:*" })
    vim.list_extend(lines, vim.split(capped(entry.text), "\n"))
  end
  local _, win = vim.lsp.util.open_floating_preview(lines, "markdown", {
    border = "rounded",
    focus_id = "claude-notes",
    focus = false,
    max_width = math.max(20, math.min(80, vim.o.columns - 4)),
  })
  state.shown = { win = win, id = note.id }
end

local function is_shown(note)
  return state.shown ~= nil and state.shown.id == note.id and vim.api.nvim_win_is_valid(state.shown.win)
end

local function hover_later()
  local timer = registry.hover
  if not timer then
    return
  end
  timer:stop()
  timer:start(config.hover_delay, 0, vim.schedule_wrap(function()
    if vim.api.nvim_get_mode().mode ~= "n" then
      return
    end
    local buf = vim.api.nvim_get_current_buf()
    local repo = cached_repo(buf)
    local note = repo and note_under_cursor(buf, repo)
    if note and (note.status == "done" or note.status == "question") and not is_shown(note) then
      popup(note)
    end
  end))
end

local function precedes(a_file, a_line, b_file, b_line)
  return a_file < b_file or (a_file == b_file and a_line < b_line)
end

local function neighbor(replies, file, line, step)
  if step > 0 then
    for _, note in ipairs(replies) do
      if precedes(file, line, note.file, note.start) then
        return note
      end
    end
    return replies[1]
  end
  for i = #replies, 1, -1 do
    if precedes(replies[i].file, replies[i].start, file, line) then
      return replies[i]
    end
  end
  return replies[#replies]
end

local function jump(step)
  local buf = vim.api.nvim_get_current_buf()
  local repo = repo_for(buf)
  if not repo then
    return
  end
  local replies = vim.tbl_filter(function(note)
    return note.status == "done" or note.status == "question"
  end, repo.notes)
  if #replies == 0 then
    notify("no Claude replies yet")
    return
  end
  table.sort(replies, function(a, b)
    return precedes(a.file, a.start, b.file, b.start)
  end)
  local rel = relpath(repo, buf) or ""
  local target = neighbor(replies, rel, vim.api.nvim_win_get_cursor(0)[1], step)
  if target.file ~= rel then
    local path, why = file_of(repo, target.file)
    if not path then
      notify(why, vim.log.levels.WARN)
      return
    end
    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
    if not ok then
      notify(tostring(err), vim.log.levels.WARN)
      return
    end
  end
  local here = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(target.start, vim.api.nvim_buf_line_count(here))), 0 })
  vim.cmd("normal! zz")
  vim.defer_fn(function()
    if vim.api.nvim_get_current_buf() == here then
      popup(target)
    end
  end, POPUP_AFTER_JUMP_MS)
end

local function new_id(notes)
  local taken = {}
  for _, note in ipairs(notes) do
    if type(note) == "table" and note.id then
      taken[note.id] = true
    end
  end
  for _ = 1, 100 do
    local id = string.format("%06x", math.random(0, 0xffffff))
    if not taken[id] then
      return id
    end
  end
  error("could not find a free note id")
end

local function editor(title, initial, on_submit, on_cancel)
  initial = initial or ""
  local is_submitted = false
  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].completion = false
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if not is_submitted and on_cancel then
        on_cancel()
      end
    end,
  })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial, "\n"))
  local width = math.max(20, math.min(80, vim.o.columns - 4))
  local height = math.max(3, math.min(10, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    footer = " <C-s> save · q cancel ",
    footer_pos = "right",
  })
  local function text()
    return vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  end
  local function close_window()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local function submit()
    local written = text()
    is_submitted = written ~= ""
    vim.cmd("stopinsert")
    close_window()
    if written ~= "" then
      on_submit(written)
    end
  end
  local function cancel()
    local written = text()
    if written ~= "" and written ~= vim.trim(initial) and vim.fn.confirm("Discard this note?", "&Discard\n&Keep editing", 2) ~= 1 then
      return
    end
    close_window()
  end
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf, desc = "Save the note" })
  vim.keymap.set("n", "q", cancel, { buffer = buf, desc = "Cancel" })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, desc = "Cancel" })
  if initial == "" then
    vim.cmd("startinsert")
  end
end

local function keep_text(text, why)
  vim.fn.setreg('"', text)
  notify(why .. '; your text is in the " register', vim.log.levels.WARN)
end

local function has_open_note(repo, rel)
  for _, note in ipairs(repo.notes) do
    if note.file == rel and note.status == "open" then
      return true
    end
  end
  return false
end

local function is_excluded(rel)
  local lower = rel:lower()
  for _, pattern in ipairs(config.snippet_exclude) do
    if lower:find(pattern) then
      return true
    end
  end
  return false
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
  local function save(note_text, first, last)
    local snippet = ""
    if not is_excluded(rel) then
      snippet = table.concat(vim.list_slice(vim.api.nvim_buf_get_lines(buf, first - 1, last, false), 1, config.max_snippet_lines), "\n")
    end
    local saved = update_notes(repo, function(notes)
      table.insert(notes, {
        id = new_id(notes),
        file = rel,
        start = first,
        ["end"] = last,
        snippet = snippet,
        text = note_text,
        status = "open",
        createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      })
    end)
    if not saved then
      keep_text(note_text, "the note was not saved")
    end
  end
  if text and text ~= "" then
    save(text, line1, line2)
    return
  end
  -- The buffer can change while the editor is open, so the range is read back from a mark on save.
  local last_line = vim.api.nvim_buf_get_lines(buf, line2 - 1, line2, false)[1] or ""
  local anchor = vim.api.nvim_buf_set_extmark(buf, anchor_ns, line1 - 1, 0, { end_row = line2 - 1, end_col = #last_line, invalidate = true })
  local function drop_anchor()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_del_extmark(buf, anchor_ns, anchor)
    end
  end
  editor("Note for Claude · " .. rel .. ":" .. range_label({ start = line1, ["end"] = line2 }), "", function(note_text)
    local pos = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_extmark_by_id(buf, anchor_ns, anchor, { details = true }) or {}
    drop_anchor()
    if not pos[1] or pos[3].invalid then
      keep_text(note_text, "the lines for this note are gone")
      return
    end
    save(note_text, pos[1] + 1, (pos[3].end_row or pos[1]) + 1)
  end, drop_anchor)
end

function M.edit()
  local repo, note = note_at_cursor()
  if not note then
    return
  end
  if note.status ~= "open" then
    notify("only open notes can be edited; this one is " .. note.status, vim.log.levels.WARN)
    return
  end
  editor("Edit note " .. note.id, note.text, function(text)
    local saved, why = update_notes(repo, function(notes)
      local current = find_by_id(notes, note.id)
      if not current or current.status ~= "open" then
        return "reject"
      end
      current.text = text
    end)
    if not saved then
      keep_text(text, why == "rejected" and "the note was sent or removed while you edited it" or "the edit was not saved")
    end
  end)
end

function M.reply()
  local repo, note = note_at_cursor()
  if not note then
    return
  end
  local question = note.status == "question" and last_question(note)
  if not question then
    notify("Claude has no open question on this note", vim.log.levels.WARN)
    return
  end
  for _, buf in ipairs(repo_buffers(repo)) do
    if vim.bo[buf].modified and relpath(repo, buf) == note.file then
      notify("save first, Claude reads the files on disk: " .. note.file, vim.log.levels.WARN)
      return
    end
  end
  editor("Answer Claude · " .. one_line(question, 60), "", function(text)
    local saved, why = update_notes(repo, function(notes)
      local current = find_by_id(notes, note.id)
      if not current or current.status ~= "question" then
        return "reject"
      end
      current.thread = current.thread or {}
      table.insert(current.thread, { from = "you", text = text })
      current.status = "queued"
    end)
    if saved then
      notify("Answer queued for Claude")
    else
      keep_text(text, why == "rejected" and "the question was answered or removed meanwhile" or "the answer was not saved")
    end
  end)
end

function M.delete()
  local repo, note = note_at_cursor()
  if not note then
    return
  end
  local _, why = update_notes(repo, function(notes)
    local current, index = find_by_id(notes, note.id)
    if not current then
      return "skip"
    end
    if current.status == "sent" then
      return "reject"
    end
    table.remove(notes, index)
  end)
  if why == "rejected" then
    notify("Claude is working on this note; wait for the reply or run /notes reopen in Claude first", vim.log.levels.WARN)
  end
end

function M.show()
  local _, note = note_at_cursor()
  if note then
    popup(note)
  end
end

function M.list()
  local repo = repo_for(vim.api.nvim_get_current_buf(), true) or repo_at(vim.fn.getcwd(), true)
  if not repo then
    notify("neither this buffer nor the working directory is in a git repository", vim.log.levels.WARN)
    return
  end
  local items = {}
  for _, note in ipairs(repo.notes) do
    if #items >= config.max_notes then
      notify(string.format("listing the first %d notes of %d", config.max_notes, #repo.notes), vim.log.levels.WARN)
      break
    end
    local path, _, is_outside = file_of(repo, note.file)
    if not is_outside then
      local text = string.format("[%s] %s", note.status, one_line(note.text, config.max_label))
      if note.reply then
        text = text .. "  ↳ " .. one_line(note.reply, config.max_label)
      end
      table.insert(items, { filename = path or (repo.root .. "/" .. note.file), lnum = note.start, end_lnum = note["end"], text = text })
    end
  end
  vim.fn.setqflist({}, " ", { title = "Claude notes", items = items })
  vim.cmd("copen")
end

function M.send()
  local repo = repo_for(vim.api.nvim_get_current_buf())
  if not repo then
    return
  end
  local unsaved = {}
  for _, buf in ipairs(repo_buffers(repo)) do
    local rel = vim.bo[buf].modified and relpath(repo, buf)
    if rel and has_open_note(repo, rel) then
      table.insert(unsaved, rel)
    end
  end
  if #unsaved > 0 then
    notify("save first, Claude reads the files on disk: " .. table.concat(unsaved, ", "), vim.log.levels.WARN)
    return
  end
  local count = 0
  local saved = update_notes(repo, function(notes)
    count = 0
    for _, note in ipairs(notes) do
      if is_valid(note) and note.status == "open" then
        note.status = "queued"
        count = count + 1
      end
    end
    if count == 0 then
      return "skip"
    end
  end)
  if saved then
    notify(count == 0 and "no open notes to send" or ("Queued " .. plural(count, "note") .. " for Claude"))
  end
end

function M.clear()
  local repo = repo_for(vim.api.nvim_get_current_buf())
  if not repo then
    return
  end
  update_notes(repo, function(notes)
    local before = #notes
    for i = #notes, 1, -1 do
      if is_valid(notes[i]) and notes[i].status == "done" then
        table.remove(notes, i)
      end
    end
    if #notes == before then
      return "skip"
    end
  end)
end

function M.next_reply()
  jump(1)
end

function M.prev_reply()
  jump(-1)
end

local function sync_positions(buf)
  local repo = cached_repo(buf)
  -- Still modified after a write means it went elsewhere (:w other.txt); the file's lines did not change.
  if not repo or not state.marks[buf] or vim.bo[buf].modified then
    return
  end
  local orphans = state.orphans[buf] or {}
  local positions = {}
  for mark_id, note_id in pairs(state.marks[buf]) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark_id, { details = true })
    if pos[1] and pos[3].invalid then
      orphans[note_id] = true
    elseif pos[1] and not orphans[note_id] then
      positions[note_id] = { start = pos[1] + 1, ["end"] = (pos[3].end_row or pos[1]) + 1 }
    end
  end
  state.orphans[buf] = {}
  local moves = {}
  for _, note in ipairs(repo.notes) do
    local to = positions[note.id]
    if orphans[note.id] and not state.orphan_warned[note.id] then
      state.orphan_warned[note.id] = true
      notify(string.format("the code under note %s was deleted; the note stays at %s:%d", note.id, note.file, note.start), vim.log.levels.WARN)
    elseif to and (to.start ~= note.start or to["end"] ~= note["end"]) then
      moves[note.id] = to
    end
  end
  if next(moves) == nil then
    render(buf)
    return
  end
  update_notes(repo, function(notes)
    for _, note in ipairs(notes) do
      local to = is_valid(note) and moves[note.id]
      if to then
        note.start, note["end"] = to.start, to["end"]
      end
    end
  end)
end

function M.status()
  local repo = cached_repo(vim.api.nvim_get_current_buf())
  if not repo then
    return ""
  end
  local queued, sent = count_pending(repo.notes)
  local questions = #vim.tbl_filter(function(note)
    return note.status == "question"
  end, repo.notes)
  if queued + sent + questions == 0 then
    return ""
  end
  local parts = {}
  if questions > 0 then
    table.insert(parts, plural(questions, "question"))
  end
  if sent > 0 then
    table.insert(parts, sent .. " in progress")
  end
  if queued > 0 then
    table.insert(parts, queued .. " queued")
  end
  if queued + sent == 0 then
    return "? Claude: " .. table.concat(parts, " · ")
  end
  if is_stale(repo) then
    local minutes = math.floor((now() - repo.changed_at) / 60)
    return string.format("Claude: %s · no update for %dm", table.concat(parts, " · "), minutes)
  end
  return SPINNER[state.frame] .. " Claude: " .. table.concat(parts, " · ")
end

local function actions()
  return {
    {
      name = "ClaudeNote",
      key = "a",
      desc = "note on the line or selection",
      command = function(o)
        M.add(o.line1, o.line2, o.args)
      end,
      command_opts = { range = true, nargs = "*" },
      maps = { n = "<cmd>ClaudeNote<CR>", x = ":ClaudeNote<CR>" },
    },
    { name = "ClaudeNotesSend", key = "S", desc = "send open notes", run = M.send },
    { name = "ClaudeNoteNext", key = "n", desc = "next reply", run = M.next_reply },
    { name = "ClaudeNotePrev", key = "p", desc = "previous reply", run = M.prev_reply },
    { name = "ClaudeNoteShow", key = "s", desc = "show the note on this line", run = M.show },
    { name = "ClaudeNoteEdit", key = "e", desc = "edit the note on this line", run = M.edit },
    { name = "ClaudeNoteReply", key = "r", desc = "answer Claude's question on this line", run = M.reply },
    { name = "ClaudeNoteDelete", key = "d", desc = "delete the note on this line", run = M.delete },
    { name = "ClaudeNotes", key = "l", desc = "list notes in quickfix", run = M.list },
    { name = "ClaudeNotesClear", key = "c", desc = "clear done notes", run = M.clear },
  }
end

local function create_autocmds(group)
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_highlights })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    callback = function(ev)
      if repo_for(ev.buf, true) then
        render(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufFilePost", {
    group = group,
    callback = function(ev)
      vim.b[ev.buf].claude_notes_path = nil
      repo_for(ev.buf, true)
      render(ev.buf)
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
      state.marks[ev.buf], state.orphans[ev.buf], state.crowded_warned[ev.buf] = nil, nil, nil
    end,
  })
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      state.no_repo, state.dir_repo = {}, {}
    end,
  })
  if config.hover then
    vim.api.nvim_create_autocmd("CursorMoved", { group = group, callback = hover_later })
  end
end

function M.setup(opts)
  if vim.fn.has("nvim-0.11") == 0 then
    notify("claude-notes needs Neovim 0.11 or newer", vim.log.levels.ERROR)
    return
  end
  config = vim.tbl_extend("force", vim.deepcopy(DEFAULTS), opts or {})
  teardown()
  state = new_state()
  math.randomseed(vim.uv.hrtime())
  define_highlights()
  if config.hover then
    registry.hover = track(assert(vim.uv.new_timer()))
  end

  for _, action in ipairs(actions()) do
    local desc = "Claude: " .. action.desc
    vim.api.nvim_create_user_command(action.name, action.command or function()
      action.run()
    end, vim.tbl_extend("force", { desc = desc }, action.command_opts or {}))
    if config.keymaps then
      for mode, rhs in pairs(action.maps or { n = action.run }) do
        vim.keymap.set(mode, config.prefix .. action.key, rhs, { desc = desc, silent = true })
      end
    end
  end

  create_autocmds(vim.api.nvim_create_augroup("claude-notes", { clear = true }))

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and repo_for(buf, true) then
      render(buf)
    end
  end
end

return M
