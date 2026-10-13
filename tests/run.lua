local notes = require("claude-notes")
local ns = vim.api.nvim_create_namespace("claude-notes")
local base = vim.uv.fs_realpath(vim.fn.tempname():match("(.*)/")) .. "/claude-notes-test"
local notified = {}
vim.notify = function(msg)
  table.insert(notified, msg)
end

local failures = 0
local R

local function check(cond, what)
  if not cond then
    error(what, 2)
  end
  print("  ok  " .. what)
end

local function wait_for(cond, ms)
  return vim.wait(ms or 1500, cond, 20)
end

local function settle(ms)
  vim.wait(ms or 300, function()
    return false
  end, 20)
end

local function new_repo()
  vim.cmd("silent! %bwipeout!")
  R = base .. "/" .. vim.uv.hrtime()
  vim.fn.mkdir(R .. "/src", "p")
  vim.fn.writefile({ "package main", "", "func main() {", '\tprintln("hi")', "}" }, R .. "/src/app.go")
  for _, args in ipairs({ { "init", "-q" }, { "add", "." }, { "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init" } }) do
    local out = vim.system(vim.list_extend({ "git", "-C", R }, args)):wait()
    assert(out.code == 0, "git " .. table.concat(args, " ") .. " failed: " .. (out.stderr or ""))
  end
end

local function notes_path()
  return R .. "/.git/claude-notes.json"
end

local function read_notes()
  local fd = io.open(notes_path())
  if not fd then
    return { notes = {} }, ""
  end
  local text = fd:read("*a")
  fd:close()
  return vim.json.decode(text), text
end

-- Writes the file in place, as the mod does.
local function write_notes(data)
  local fd = assert(io.open(notes_path(), "w"))
  fd:write(vim.json.encode(data))
  fd:close()
end

local function note(id, over)
  return vim.tbl_extend("force", { id = id, file = "src/app.go", start = 3, ["end"] = 3, snippet = "", text = "note " .. id, status = "open", createdAt = "" }, over or {})
end

local function eol_chunks(line)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
    if mark[4].virt_text and (line == nil or mark[2] == line - 1) then
      return mark[4].virt_text
    end
  end
  return {}
end

local function eol_text(line)
  local all = {}
  for _, chunk in ipairs(eol_chunks(line)) do
    table.insert(all, chunk[1])
  end
  return table.concat(all)
end

local function popup_text()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
    end
  end
  return nil
end

local function close_popups()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      vim.api.nvim_win_close(win, true)
    end
  end
end

local function open_app(opts)
  notes.setup(opts or {})
  vim.cmd("edit " .. R .. "/src/app.go")
end

local function case(name, body)
  print(name)
  notified = {}
  new_repo()
  local ok, err = pcall(body)
  close_popups()
  if not ok then
    failures = failures + 1
    io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
  end
end

case("adding a note writes it and draws it", function()
  open_app()
  notes.add(3, 5, "add a timeout here")
  local data, raw = read_notes()
  check(#data.notes == 1, "note written")
  check(data.notes[1].file == "src/app.go" and data.notes[1].start == 3 and data.notes[1]["end"] == 5, "file and range recorded")
  check(data.notes[1].snippet:find("println") ~= nil, "snippet recorded")
  check(raw:find('"notes":%[') ~= nil, "notes is a JSON array")
  check(#vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) == 3, "a sign on each line of the range")
end)

case("notes follow edits on save, and a deleted line keeps its note in place", function()
  open_app()
  notes.add(3, 5, "range")
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "// one", "// two" })
  vim.cmd("silent write")
  local data = read_notes()
  check(data.notes[1].start == 5 and data.notes[1]["end"] == 7, "range follows edits on save")

  notes.add(1, 1, "on the comment")
  local id = read_notes().notes[2].id
  vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
  vim.cmd("silent write")
  local moved = read_notes().notes[2]
  check(moved.id == id and moved.start == 1, "a note whose line was deleted is not moved onto the neighbouring code")
  check(notified[#notified]:find("was deleted") ~= nil, "and the person is told: " .. tostring(notified[#notified]))
end)

case("a reply from the mod is announced once and drawn apart from the code", function()
  open_app()
  notes.add(4, 4, "why hi?")
  local data = read_notes()
  data.notes[1].status = "done"
  data.notes[1].reply = "it greets\nsecond line\27[31m"
  write_notes(data)
  check(wait_for(function()
    return #notified > 0
  end), "a notification arrives")
  check(notified[1] == "Claude finished 1 note", "resolution announced: " .. tostring(notified[1]))
  local chunks = eol_chunks(4)
  check(chunks[2] and chunks[2][1] == " ✓ Claude " and chunks[2][2] == "ClaudeNotesBadgeDone", "done note has a Claude badge")
  check(chunks[3] and chunks[3][1] == " it greets … " and chunks[3][2] == "ClaudeNotesTextDone", "a multi-line reply shows its first line only: " .. vim.inspect(chunks[3]))
  check(vim.api.nvim_get_hl(0, { name = "ClaudeNotesBadgeDone" }).reverse == true, "badge is reversed")
  check(vim.api.nvim_get_hl(0, { name = "ClaudeNotesTextDone" }).italic == true, "reply is italic")
end)

case("malformed notes are skipped, kept in the file, and do not break the rest", function()
  write_notes({
    version = 1,
    root = R,
    owner = "mod",
    notes = {
      note("ok1", { start = 4, ["end"] = 4, tags = {} }),
      { id = "bad1", file = "src/app.go", start = "x", status = "open", text = "t" },
      note("bad2", { file = "../../etc/hosts" }),
      note("bad3", { file = "/etc/hosts" }),
      note("bad4", { status = "later" }),
      note("bad5", { reply = 42, status = "done" }),
    },
  })
  open_app()
  check(eol_text(4):find("note ok1", 1, true) ~= nil, "the valid note is drawn")
  check(#vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) == 1, "the malformed ones are not")
  check(notified[1] == "skipping 5 notes in " .. notes_path() .. ": malformed", "the person is told: " .. tostring(notified[1]))
  notes.add(1, 1, "new")
  local data, raw = read_notes()
  check(#data.notes == 7, "a write keeps the malformed notes for whoever wrote them")
  check(data.owner == "mod", "unknown top-level keys survive a write")
  check(raw:find('"tags":[]', 1, true) ~= nil, "empty arrays stay arrays")
end)

case("a write that races another writer is redone on the fresh file", function()
  write_notes({ version = 1, root = R, notes = { note("a1"), note("b2") } })
  open_app()
  local real_open = io.open
  local armed = true
  io.open = function(path, mode)
    if armed and path == notes_path() and (mode == nil or mode == "r") then
      armed = false
      local fd = real_open(path, "r")
      local text = fd:read("*a")
      fd:close()
      -- The mod writes a reply right after Neovim read the file.
      local data = vim.json.decode(text)
      data.notes[2].status = "done"
      data.notes[2].reply = "kept"
      local out = real_open(path, "w")
      out:write(vim.json.encode(data) .. "  ")
      out:close()
      return {
        read = function()
          return text
        end,
        close = function() end,
      }
    end
    return real_open(path, mode)
  end
  local ok, err = pcall(notes.send)
  io.open = real_open
  check(ok, "send ran: " .. tostring(err))
  local data = read_notes()
  check(data.notes[2].reply == "kept", "the mod's reply was not overwritten")
  check(data.notes[1].status == "queued", "and the send still happened")
end)

case("edit and delete leave notes Claude has alone", function()
  write_notes({ version = 1, root = R, notes = { note("a1", { start = 4, ["end"] = 4 }), note("s1", { status = "sent", start = 3, ["end"] = 3 }) } })
  open_app()
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  notes.edit()
  local editor_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, { "rewritten" })
  local data = read_notes()
  data.notes[1].status = "sent"
  write_notes(data)
  settle(400)
  vim.fn.maparg("<C-s>", "n", false, true).callback()
  check(read_notes().notes[1].text == "note a1", "an edit saved after the note was sent does not change it")
  check(vim.fn.getreg('"') == "rewritten", "the edit is kept in the unnamed register")

  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  notes.delete()
  check(#read_notes().notes == 2, "a note Claude is working on is not deleted")
  check(notified[#notified]:find("Claude is working on this note", 1, true) ~= nil, "and the person is told why")
end)

case("send queues open notes, but not from an unsaved buffer", function()
  open_app()
  notes.add(4, 4, "first")
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "// unsaved" })
  notes.send()
  check(read_notes().notes[1].status == "open", "nothing is queued while the buffer has unsaved changes")
  check(notified[#notified]:find("save first", 1, true) ~= nil, "the person is told to save: " .. notified[#notified])
  vim.cmd("silent write")
  notes.send()
  check(read_notes().notes[1].status == "queued", "send queues open notes once saved")
  check(notified[#notified] == "Queued 1 note for Claude", "send says how many")
  notes.send()
  check(notified[#notified] == "no open notes to send", "a second send has nothing to queue")
end)

case("the status line and spinner follow pending notes", function()
  write_notes({ version = 1, root = R, notes = { note("q1", { status = "queued", start = 4, ["end"] = 4 }) } })
  open_app()
  check(_G.__claude_notes.spinner ~= nil, "the spinner starts for notes already pending when Neovim opens")
  check(notes.status():find("Claude: 1 queued$") ~= nil, "status shows the queued note: " .. notes.status())
  check(eol_text(4):find("⇡ queued  note q1", 1, true) ~= nil, "queued note says so: " .. eol_text(4))
  local data = read_notes()
  data.notes[1].status = "sent"
  write_notes(data)
  check(wait_for(function()
    return notes.status():find("in progress") ~= nil
  end), "status follows the mod")
  check(eol_text(4):find("… Claude working  note q1", 1, true) ~= nil, "sent note says Claude is working: " .. eol_text(4))
  data.notes[1].status = "done"
  data.notes[1].reply = "ok"
  write_notes(data)
  check(wait_for(function()
    return notes.status() == ""
  end), "status is empty once nothing is pending")
  check(_G.__claude_notes.spinner == nil, "the spinner stops")
end)

case("a note stuck with Claude stops the spinner after stale_after", function()
  write_notes({ version = 1, root = R, notes = { note("s1", { status = "sent" }) } })
  open_app({ stale_after = 0.3 })
  check(_G.__claude_notes.spinner ~= nil, "the spinner runs at first")
  check(wait_for(function()
    return _G.__claude_notes.spinner == nil
  end), "the spinner stops once nothing changed for stale_after")
  check(notes.status():find("no update for 0m", 1, true) ~= nil, "status says it is stale: " .. notes.status())
end)

case("setup twice keeps one watcher and one notification", function()
  write_notes({ version = 1, root = R, notes = { note("a1", { status = "sent" }) } })
  open_app()
  open_app()
  local data = read_notes()
  data.notes[1].status = "done"
  data.notes[1].reply = "ok"
  write_notes(data)
  check(wait_for(function()
    return #notified > 0
  end), "a change is still picked up after a second setup")
  settle(500)
  check(#notified == 1, "and announced once (" .. #notified .. ")")
end)

case("hover and next/previous reply", function()
  vim.fn.writefile({ "package main", "", "func b() {}" }, R .. "/src/b.go")
  write_notes({
    version = 1,
    root = R,
    notes = {
      note("n1", { text = "why main?", status = "done", reply = "it is the entry point" }),
      note("n2", { file = "src/b.go", text = "rename b", status = "done", reply = "renamed to helper" }),
      note("n3", { file = "src/b.go", start = 1, ["end"] = 1, text = "still open" }),
    },
  })
  open_app()
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  check(wait_for(function()
    return popup_text() ~= nil
  end), "resting on a done note pops up")
  check(popup_text():find("it is the entry point", 1, true) ~= nil and popup_text():find("why main?", 1, true) ~= nil, "with the reply and the note")
  close_popups()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  settle(800)
  check(popup_text() == nil, "no popup on a line without a note")

  notes.next_reply()
  check(vim.api.nvim_win_get_cursor(0)[1] == 3 and vim.fn.expand("%:t") == "app.go", "next goes to the reply below")
  check(wait_for(function()
    return popup_text() ~= nil
  end, 500) and popup_text():find("it is the entry point", 1, true) ~= nil, "and shows it")
  close_popups()
  notes.next_reply()
  check(vim.fn.expand("%:t") == "b.go" and vim.api.nvim_win_get_cursor(0)[1] == 3, "next moves to the next file, skipping open notes")
  close_popups()
  notes.next_reply()
  check(vim.fn.expand("%:t") == "app.go" and vim.api.nvim_win_get_cursor(0)[1] == 3, "next wraps around")
  close_popups()
  notes.prev_reply()
  check(vim.fn.expand("%:t") == "b.go", "previous wraps back")
  close_popups()

  vim.o.hidden = false
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "// unsaved" })
  local ok = pcall(notes.next_reply)
  vim.o.hidden = true
  check(ok and vim.fn.expand("%:t") == "b.go", "a jump from an unsaved buffer reports instead of failing")
  check(notified[#notified]:find("E37", 1, true) ~= nil, "with Neovim's reason: " .. notified[#notified])
end)

case("a jump never opens a file outside the repository", function()
  local outside = R .. "-outside"
  vim.fn.mkdir(outside, "p")
  vim.fn.writefile({ "secret" }, outside .. "/f.txt")
  assert(vim.uv.fs_symlink(outside, R .. "/link"))
  write_notes({ version = 1, root = R, notes = { note("x1", { file = "link/f.txt", start = 1, ["end"] = 1, status = "done", reply = "r" }) } })
  open_app()
  notes.next_reply()
  check(vim.fn.expand("%:t") == "app.go", "the outside file is not opened")
  check(notified[#notified]:find("outside the repository", 1, true) ~= nil, "the person is told: " .. notified[#notified])
  vim.fn.delete(outside, "rf")
end)

case("snippets are not copied from secret-looking files, and long ranges are capped", function()
  vim.fn.writefile({ "TOKEN=abc" }, R .. "/.env")
  notes.setup({ max_range_signs = 10 })
  vim.cmd("edit " .. R .. "/.env")
  notes.add(1, 1, "rotate this")
  check(read_notes().notes[1].snippet == "", "no snippet from .env")
  local lines = {}
  for i = 1, 500 do
    lines[i] = "line " .. i
  end
  vim.fn.writefile(lines, R .. "/src/long.txt")
  vim.cmd("edit " .. R .. "/src/long.txt")
  notes.add(1, 500, "whole file")
  check(#vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) == 11, "range signs are capped at max_range_signs")
end)

case("clear and list", function()
  write_notes({ version = 1, root = R, notes = { note("d1", { status = "done", reply = "ok" }), note("o1", { start = 4, ["end"] = 4 }) } })
  open_app()
  notes.list()
  check(#vim.fn.getqflist() == 2, "quickfix lists every note")
  vim.cmd("cclose")
  notes.clear()
  local data = read_notes()
  check(#data.notes == 1 and data.notes[1].id == "o1", "clear removes done notes only")
end)

case("unsaved edits keep marks where the code is now", function()
  write_notes({ version = 1, root = R, notes = { note("a1", { start = 4, ["end"] = 4 }) } })
  open_app()
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "// one", "// two" })
  notes.add(1, 1, "another note while unsaved")
  check(eol_text(6):find("note a1", 1, true) ~= nil, "the first note stays on its moved code after another write: " .. eol_text(6))
  vim.cmd("silent write")
  local moved = read_notes().notes[1]
  check(moved.id == "a1" and moved.start == 6, "and saving records where it moved to: " .. moved.start)
end)

case("a failed write leaves the notes file as it was", function()
  write_notes({ version = 1, root = R, notes = { note("a1") } })
  open_app()
  local _, before = read_notes()
  local real_write = vim.uv.fs_write
  vim.uv.fs_write = function()
    return nil, "ENOSPC: no space left on device"
  end
  local ok = pcall(notes.add, 4, 4, "lost")
  vim.uv.fs_write = real_write
  local _, after = read_notes()
  check(ok and after == before, "the original file is untouched")
  check(table.concat(notified, "\n"):find("ENOSPC", 1, true) ~= nil, "the error is reported")
  check(vim.fn.getreg('"') == "lost", "and the note's text is kept in the unnamed register")
  local leftovers = vim.fn.glob(R .. "/.git/claude-notes.json.*.tmp", false, true)
  check(#leftovers == 0, "no temp file is left behind")
  notes.add(4, 4, "kept")
  check(vim.uv.fs_stat(notes_path()).mode % 512 == 384, "the file is written readable by its owner only")
end)

case("a write retries while the mod is mid-write", function()
  write_notes({ version = 1, root = R, notes = { note("a1", { start = 4, ["end"] = 4 }) } })
  open_app()
  local real_open = io.open
  local reads = 0
  io.open = function(path, mode)
    if path == notes_path() and (mode == nil or mode == "r") then
      reads = reads + 1
      if reads == 1 then
        return { read = function() return '{"version":1,"notes":[{"id"' end, close = function() end }
      end
    end
    return real_open(path, mode)
  end
  local ok = pcall(notes.send)
  io.open = real_open
  check(ok and read_notes().notes[1].status == "queued", "send goes through after a half-written read")
  check(notified[#notified] == "Queued 1 note for Claude", "with no error shown: " .. notified[#notified])
end)

case("nulls and odd values in the file are skipped without hiding later notes", function()
  local fd = assert(io.open(notes_path(), "w"))
  local with_null = vim.json.encode({ version = 1, root = R, notes = { note("a1", { start = 1, ["end"] = 1 }) } }):gsub('"notes":%[', '"notes":[null,')
  fd:write(with_null)
  fd:close()
  local data = read_notes()
  table.insert(data.notes, note("b1", { start = 4, ["end"] = 4 }))
  table.insert(data.notes, note("c1", { file = "src/app\n.go" }))
  table.insert(data.notes, note("d1", { start = 1, ["end"] = 1e12 }))
  write_notes(data)
  open_app()
  check(eol_text(4):find("note b1", 1, true) ~= nil, "a note after a null is still drawn")
  check(notified[1]:find("skipping 3 notes", 1, true) ~= nil, "the null, the newline path and the huge line are counted: " .. tostring(notified[1]))
end)

case("nothing is written when nothing changed", function()
  write_notes({ version = 1, root = R, notes = { note("d1", { status = "sent" }) } })
  open_app()
  local before = vim.uv.fs_stat(notes_path())
  notes.send()
  notes.clear()
  local after = vim.uv.fs_stat(notes_path())
  check(before.mtime.nsec == after.mtime.nsec and before.ino == after.ino, "send and clear with nothing to do leave the file alone")
  check(notified[#notified] == "no open notes to send", "and send still says so")
end)

case("deleting a queued note is allowed", function()
  write_notes({ version = 1, root = R, notes = { note("q1", { status = "queued" }) } })
  open_app()
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  notes.delete()
  check(#read_notes().notes == 0, "a queued note no session has taken can be deleted")
end)

case("the quickfix list leaves out files outside the repository", function()
  local outside = R .. "-outside"
  vim.fn.mkdir(outside, "p")
  vim.fn.writefile({ "x" }, outside .. "/f.txt")
  assert(vim.uv.fs_symlink(outside, R .. "/link"))
  write_notes({ version = 1, root = R, notes = { note("in1"), note("out1", { file = "link/f.txt", start = 1, ["end"] = 1 }) } })
  open_app()
  notes.list()
  local items = vim.fn.getqflist()
  check(#items == 1 and items[1].text:find("note in1", 1, true) ~= nil, "only the note inside the repository is listed")
  vim.cmd("cclose")
  vim.fn.delete(outside, "rf")
end)

case("huge replies and crowded files are capped", function()
  write_notes({ version = 1, root = R, notes = { note("big", { status = "done", reply = string.rep("x", 100000) }) } })
  open_app({ max_notes = 3 })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  notes.show()
  check(#(popup_text() or "") < 25000, "the popup shows a capped reply (" .. #(popup_text() or "") .. " chars)")
  close_popups()
  local many = {}
  for i = 1, 10 do
    many[i] = note("m" .. i, { start = 1, ["end"] = 1 })
  end
  write_notes({ version = 1, root = R, notes = many })
  check(wait_for(function()
    return #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) == 3
  end), "only max_notes notes are drawn per file")
  check(notified[#notified]:find("more than 3 notes", 1, true) ~= nil, "and the person is told: " .. notified[#notified])
end)

case("staleness counts from the last status change, and from the file for old notes", function()
  write_notes({ version = 1, root = R, notes = { note("s1", { status = "sent" }) } })
  local old = os.time() - 3600
  vim.uv.fs_utime(notes_path(), old, old)
  open_app({ stale_after = 60 })
  check(_G.__claude_notes.spinner == nil, "a note sent an hour ago does not start the spinner")
  check(notes.status():find("no update for 60m", 1, true) ~= nil, "and status says how long: " .. notes.status())
  notes.add(1, 1, "unrelated")
  check(_G.__claude_notes.spinner == nil, "adding an unrelated note does not count as progress")
end)

case("closed timers leave the registry", function()
  write_notes({ version = 1, root = R, notes = {} })
  open_app()
  local base_count = #_G.__claude_notes.open
  for _ = 1, 5 do
    notes.add(4, 4, "x")
    notes.send()
    local data = read_notes()
    for _, n in ipairs(data.notes) do
      n.status = "done"
    end
    write_notes(data)
    check(wait_for(function()
      return _G.__claude_notes.spinner == nil
    end), "the spinner stops after round " .. _)
  end
  check(#_G.__claude_notes.open == base_count, "spinner starts and stops do not pile up handles (" .. #_G.__claude_notes.open .. " vs " .. base_count .. ")")
end)

case("files in a known directory don't run git again", function()
  vim.fn.writefile({ "package main" }, R .. "/src/b.go")
  open_app()
  local real_system = vim.system
  local calls = 0
  vim.system = function(cmd, ...)
    if cmd[1] == "git" then
      calls = calls + 1
    end
    return real_system(cmd, ...)
  end
  vim.cmd("edit " .. R .. "/src/b.go")
  vim.system = real_system
  check(calls == 0, "opening a second file in the same directory reuses the repository (" .. calls .. " git calls)")
end)

case("a note's range follows edits made while its editor is open", function()
  open_app()
  local code_buf = vim.api.nvim_get_current_buf()
  notes.add(4, 4)
  local editor_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(code_buf, 0, 0, false, { "// added above" })
  vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, { "the println" })
  vim.fn.maparg("<C-s>", "i", false, true).callback()
  local added = read_notes().notes[1]
  check(added.start == 5 and added.snippet:find("println", 1, true) ~= nil, "the note lands on the moved line: " .. added.start)
end)

case("reloading over an older version closes its timers instead of failing", function()
  local old_timer = vim.uv.new_timer()
  old_timer:start(100000, 0, function() end)
  _G.__claude_notes = { handles = { old_timer } }
  package.loaded["claude-notes"] = nil
  local fresh = require("claude-notes")
  local ok, err = pcall(fresh.setup, {})
  notes = fresh
  check(ok, "setup works with the older version's state: " .. tostring(err))
  check(old_timer:is_closing(), "and closes the older version's timers")
end)

case("notes Claude has also follow edits on save", function()
  write_notes({ version = 1, root = R, notes = { note("s1", { status = "sent", start = 4, ["end"] = 4 }), note("d1", { status = "done", reply = "ok", start = 3, ["end"] = 3 }) } })
  open_app()
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "// added" })
  vim.cmd("silent write")
  local data = read_notes()
  check(data.notes[1].start == 5 and data.notes[2].start == 4, "sent and done notes record their new lines")
  check(eol_text(5):find("Claude working", 1, true) ~= nil and eol_text(4):find("ok", 1, true) ~= nil, "and their signs stay on the code")
end)

case("two notes started at once both land on their lines", function()
  open_app()
  local code_win = vim.api.nvim_get_current_win()
  notes.add(4, 4)
  local first = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_win(code_win)
  notes.add(1, 1)
  local second = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(second, 0, -1, false, { "second" })
  vim.fn.maparg("<C-s>", "i", false, true).callback()
  vim.api.nvim_set_current_win(vim.fn.bufwinid(first))
  vim.api.nvim_buf_set_lines(first, 0, -1, false, { "first" })
  vim.fn.maparg("<C-s>", "i", false, true).callback()
  local by_text = {}
  for _, n in ipairs(read_notes().notes) do
    by_text[n.text] = n.start
  end
  check(by_text.first == 4 and by_text.second == 1, "neither note's range is lost: " .. vim.inspect(by_text))
end)

case("a cancelled note leaves no anchor behind", function()
  open_app()
  local code_buf = vim.api.nvim_get_current_buf()
  notes.add(4, 4)
  vim.cmd("stopinsert")
  vim.fn.maparg("q", "n", false, true).callback()
  local anchors = vim.api.nvim_buf_get_extmarks(code_buf, vim.api.nvim_create_namespace("claude-notes-anchor"), 0, -1, {})
  check(#anchors == 0, "the anchor is removed when the editor closes without saving")
end)

case("the quickfix list is capped", function()
  local many = {}
  for i = 1, 10 do
    many[i] = note("m" .. i)
  end
  write_notes({ version = 1, root = R, notes = many })
  open_app({ max_notes = 4 })
  notes.list()
  check(#vim.fn.getqflist() == 4, "only max_notes notes are listed")
  vim.cmd("cclose")
end)

case("text typed in the editor survives a failed save", function()
  open_app()
  notes.add(4, 4)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "keep me" })
  local real_write = vim.uv.fs_write
  vim.uv.fs_write = function()
    return nil, "ENOSPC: no space left on device"
  end
  vim.fn.maparg("<C-s>", "i", false, true).callback()
  vim.uv.fs_write = real_write
  check(vim.fn.getreg('"') == "keep me", "the text is in the unnamed register")
  check(notified[#notified]:find('the note was not saved; your text is in the " register', 1, true) ~= nil, "and the person is told: " .. notified[#notified])
end)

case("writing a buffer to another file does not move notes", function()
  write_notes({ version = 1, root = R, notes = { note("a1", { start = 4, ["end"] = 4 }) } })
  open_app()
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "// one", "// two" })
  vim.cmd("silent write " .. vim.fn.fnameescape(R .. "/copy.go"))
  check(read_notes().notes[1].start == 4, "the note keeps the line it has in the real file")
  vim.cmd("silent write")
  check(read_notes().notes[1].start == 6, "and moves once the buffer is written to its own file")
end)

case("deleting the lines of a done note warns too", function()
  write_notes({ version = 1, root = R, notes = { note("d1", { status = "done", reply = "ok", start = 4, ["end"] = 4 }) } })
  open_app()
  vim.api.nvim_buf_set_lines(0, 3, 4, false, {})
  vim.cmd("silent write")
  check(read_notes().notes[1].start == 4, "the done note stays at its old line")
  check(notified[#notified]:find("was deleted", 1, true) ~= nil, "and the person is told: " .. tostring(notified[#notified]))
end)

if failures == 0 then
  vim.fn.delete(base, "rf")
end
if failures > 0 then
  io.stderr:write(failures .. " case(s) failed; scratch repositories kept in " .. base .. "\n")
  os.exit(1)
end
print("all passed")
