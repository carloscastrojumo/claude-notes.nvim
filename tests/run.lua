local R = vim.uv.fs_realpath(vim.fn.tempname():match("(.*)/")) .. "/claude-notes-test"
vim.fn.delete(R, "rf")
vim.fn.mkdir(R .. "/src", "p")
vim.fn.writefile({ "package main", "", "func main() {", '\tprintln("hi")', "}" }, R .. "/src/app.go")
for _, args in ipairs({ { "init", "-q" }, { "add", "." }, { "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init" } }) do
  local out = vim.system(vim.list_extend({ "git", "-C", R }, args)):wait()
  assert(out.code == 0, "git " .. table.concat(args, " ") .. " failed: " .. (out.stderr or ""))
end
local notes = require("claude-notes")
local notified = {}
vim.notify = function(msg, level) table.insert(notified, msg) end
notes.setup({})
vim.cmd("edit " .. R .. "/src/app.go")
local function check(cond, what) if not cond then io.stderr:write("FAIL: " .. what .. "\n"); os.exit(1) end; print("ok  " .. what) end
local function file() local f = io.open(R .. "/.git/claude-notes.json"); local t = f:read("*a"); f:close(); return vim.json.decode(t), t end

notes.add(3, 5, "add a timeout here")
local data, raw = file()
check(#data.notes == 1, "note written")
check(data.notes[1].file == "src/app.go" and data.notes[1].start == 3 and data.notes[1]["end"] == 5, "file and range recorded")
check(data.notes[1].snippet:find('println') ~= nil, "snippet recorded")
check(raw:find('"notes":%[') ~= nil, "notes is a JSON array")
local marks = vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("claude-notes"), 0, -1, { details = true })
check(#marks == 3, "sign on each line of the range (" .. #marks .. ")")

vim.api.nvim_buf_set_lines(0, 0, 0, false, { "// one", "// two" })
vim.cmd("silent write")
data = file()
check(data.notes[1].start == 5 and data.notes[1]["end"] == 7, "range follows edits on save (" .. data.notes[1].start .. "-" .. data.notes[1]["end"] .. ")")

local id = data.notes[1].id
data.notes[1].status = "done"; data.notes[1].reply = "added a 5s timeout"
local f = io.open(R .. "/.git/claude-notes.json", "w"); f:write(vim.json.encode(data)); f:close()
vim.wait(2000, function() return #notified > 0 end, 50)
check(notified[1] == "Claude finished 1 note", "resolution announced: " .. tostring(notified[1]))
marks = vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("claude-notes"), 0, -1, { details = true })
local chunks = marks[1][4].virt_text or {}
check(chunks[2] and chunks[2][1] == " ✓ Claude " and chunks[2][2] == "ClaudeNotesBadgeDone", "done note has a Claude badge")
check(chunks[3] and chunks[3][1] == " added a 5s timeout " and chunks[3][2] == "ClaudeNotesTextDone", "done note shows the reply in its own color")
local badge = vim.api.nvim_get_hl(0, { name = "ClaudeNotesBadgeDone" })
local text = vim.api.nvim_get_hl(0, { name = "ClaudeNotesTextDone" })
check(badge.reverse == true and text.italic == true, "badge is reversed and the reply italic")

notes.add(1, 1, "second")
notes.clear()
data = file()
check(#data.notes == 1 and data.notes[1].text == "second", "clear removes resolved notes")
notes.list()
check(#vim.fn.getqflist() == 1, "quickfix lists notes")
vim.cmd("wincmd p")

notes.send()
data = file()
check(data.notes[1].status == "queued", "send queues open notes")
check(notified[#notified] == "Queued 1 note for Claude", "send says how many: " .. notified[#notified])
notes.send()
check(notified[#notified] == "no open notes to send", "a second send has nothing to queue")
local function eol_text()
  local m = vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("claude-notes"), 0, -1, { details = true })
  for _, one in ipairs(m) do
    if one[4].virt_text then
      local all = {}
      for _, chunk in ipairs(one[4].virt_text) do table.insert(all, chunk[1]) end
      return table.concat(all)
    end
  end
  return ""
end
check(notes.status():find("Claude: 1 queued$") ~= nil, "status line shows the queued note: " .. notes.status())
check(_G.__claude_notes_spinner ~= nil, "spinner runs while notes are pending")
check(eol_text():find("⇡ queued  second", 1, true) ~= nil, "queued note says it is waiting: " .. eol_text())
data = file()
data.notes[1].status = "sent"
f = io.open(R .. "/.git/claude-notes.json", "w"); f:write(vim.json.encode(data)); f:close()
vim.wait(1000, function() return notes.status():find("in progress") ~= nil end, 50)
check(notes.status():find("Claude: 1 in progress$") ~= nil, "status line shows the note in progress: " .. notes.status())
check(eol_text():find("… Claude working  second", 1, true) ~= nil, "sent note says Claude is on it: " .. eol_text())

package.loaded["claude-notes"] = nil
notes = require("claude-notes")
notes.setup({})
vim.cmd("edit")
data = file()
data.notes[1].status = "done"; data.notes[1].reply = "ok"
local before = #notified
f = io.open(R .. "/.git/claude-notes.json", "w"); f:write(vim.json.encode(data)); f:close()
vim.wait(1000, function() return false end, 50)
check(#notified == before + 1, "after a reload one notification, not one per load (" .. (#notified - before) .. ")")
check(notes.status() == "", "status line is empty once nothing is pending")
check(_G.__claude_notes_spinner == nil, "spinner stops once nothing is pending")

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
    if vim.api.nvim_win_get_config(win).relative ~= "" then vim.api.nvim_win_close(win, true) end
  end
end

local b = io.open(R .. "/src/b.go", "w"); b:write("package main\n\nfunc b() {}\n"); b:close()
data = file()
data.notes = {
  { id = "n1", file = "src/app.go", start = 3, ["end"] = 3, snippet = "", text = "why main?", status = "done", reply = "it is the entry point", createdAt = "" },
  { id = "n2", file = "src/b.go", start = 3, ["end"] = 3, snippet = "", text = "rename b", status = "done", reply = "renamed to helper", createdAt = "" },
  { id = "n3", file = "src/b.go", start = 1, ["end"] = 1, snippet = "", text = "still open", status = "open", createdAt = "" },
}
f = io.open(R .. "/.git/claude-notes.json", "w"); f:write(vim.json.encode(data)); f:close()
vim.wait(1000, function() return false end, 50)
vim.cmd("edit " .. R .. "/src/app.go")

vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
vim.wait(1000, function() return popup_text() ~= nil end, 50)
check((popup_text() or ""):find("it is the entry point", 1, true) ~= nil, "resting on a done note pops up the reply")
check((popup_text() or ""):find("why main?", 1, true) ~= nil, "the popup also shows your note")
close_popups()

vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
vim.wait(800, function() return false end, 50)
check(popup_text() == nil, "no popup on a line without a note")

notes.next_reply()
check(vim.api.nvim_win_get_cursor(0)[1] == 3 and vim.fn.expand("%:t") == "app.go", "next goes to the reply below in the same file")
vim.wait(500, function() return popup_text() ~= nil end, 50)
check((popup_text() or ""):find("it is the entry point", 1, true) ~= nil, "next shows the reply")
close_popups()
notes.next_reply()
check(vim.fn.expand("%:t") == "b.go" and vim.api.nvim_win_get_cursor(0)[1] == 3, "next moves to the reply in the next file, skipping open notes")
close_popups()
notes.next_reply()
check(vim.fn.expand("%:t") == "app.go" and vim.api.nvim_win_get_cursor(0)[1] == 3, "next wraps around to the first reply")
close_popups()
notes.prev_reply()
check(vim.fn.expand("%:t") == "b.go" and vim.api.nvim_win_get_cursor(0)[1] == 3, "previous wraps back to the last reply")
close_popups()
vim.fn.delete(R, "rf")
print("all passed")
