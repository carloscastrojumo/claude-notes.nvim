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

vim.fn.delete(base, "rf")
if failures > 0 then
  io.stderr:write(failures .. " case(s) failed\n")
  os.exit(1)
end
print("all passed")
