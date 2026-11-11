-- domain: note_retrieval
-- The panel of related notes: a window on the right that shows the notes closest to the note in
-- the window you came from, and follows you from note to note (`BufEnter`, debounced). Keys exist
-- only in the panel's own buffer: `<CR>` opens the note in the previous window, `l` writes a link
-- to it there at the cursor, `q` closes the panel.
local config = require('note_retrieval.config')
local debounce = require('note_retrieval.kit.debounce')
local edits = require('note_retrieval.kit.edits')
local index = require('note_retrieval.index')
local links = require('note_retrieval.links')
local roots = require('note_retrieval.roots')
local scratch = require('note_retrieval.kit.scratch')
local search = require('note_retrieval.search')

local uv = vim.uv or vim.loop

local M = {}

M.NAME = 'note-retrieval://related'
M.WIDTH = 44
M.DEBOUNCE_MS = 150

-- The next step for a vault with no usable index, one short line (the panel does not wrap, so the
-- message of the index with its long path would cut the step off).
M.HINT_EIGEN = ':NoteRetrieval reindex builds it'
M.HINT_OTHER = ':checkhealth note_retrieval'

local GROUP = 'NoteRetrievalPanel'

-- The panel that is open: its buffer, the vault it shows notes of and, per line, the note (path
-- from the vault root) that line stands for.
local state = { buf = nil, root = nil, rows = {} }
local debouncer

local function is_open()
  return state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf) and #vim.fn.win_findbuf(state.buf) > 0
end

local function folder_of(path)
  local dir = vim.fs.dirname(path)
  return dir == '.' and '(vault root)' or dir
end

--- The marks in words: nothing here is told by color or icon alone.
local function mark_words(mark, built_ms)
  if mark == 'changed' then
    return 'changed since the index'
  elseif mark == 'maybe' then
    return ('may be stale, index from %s'):format(
      os.date('%Y-%m-%d %H:%M', math.floor((built_ms or 0) / 1000))
    )
  end
  return nil
end

--- The text of the panel and what each line stands for. `model = { note, results?, message?,
--- warning?, mark?, built_ms? }`: the first line names the note, the number of rows and the mark;
--- with `message` (no index, no row for the note, nothing close) the next line says that instead
--- of rows. A row reads `0.83  Title — folder`. Returns `lines, rows` (`rows[lnum]` = the note's
--- path from the vault root).
---@param model table
---@return string[] lines
---@return table<integer, string> rows
function M.build(model)
  local results = model.results or {}
  local head = ('Related to %s: %d note%s'):format(model.note, #results, #results == 1 and '' or 's')
  local words = mark_words(model.mark, model.built_ms)
  if words then
    head = head .. '; ' .. words
  end
  local lines, rows = { head }, {}
  if model.warning then
    lines[#lines + 1] = 'Warning: ' .. model.warning
  end
  if model.hint then
    lines[#lines + 1] = model.hint
  end
  if model.message then
    lines[#lines + 1] = model.message
  end
  for _, r in ipairs(results) do
    lines[#lines + 1] = ('%.2f  %s — %s'):format(r.score, r.title, folder_of(r.path))
    rows[#lines] = r.path
  end
  return lines, rows
end

-- The note `buf` shows, if it is one of a vault: its path from the vault root and the root.
local function note_of(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) or vim.bo[buf].buftype ~= '' then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if not name:find('%.md$') then
    return nil
  end
  local root = roots.find_root(name, (config.resolve()))
  if not root then
    return nil
  end
  name = vim.fs.normalize(name)
  if name:sub(1, #root + 1) ~= root .. '/' then
    return nil
  end
  return name:sub(#root + 2), root
end

-- The notes the text of `buf` links to that the index knows: a set of paths.
local function linked_notes(buf, own, paths)
  local set, n = {}, 0
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  if not text:find('[', 1, true) then
    return set, n
  end
  local seen = {}
  for _, t in ipairs(links.targets(text)) do
    local path
    if not seen[t.target] then
      seen[t.target] = true
      path = links.resolve(t.target, paths)
    end
    if path and path ~= own and not set[path] then
      set[path] = true
      n = n + 1
    end
  end
  return set, n
end

--- Shows the notes related to the note in `buf` (default: the current buffer) in the panel, if the
--- panel is open and `buf` is a note of a vault; any other buffer leaves the panel as it is.
--- Returns the lines shown, or nil when nothing was done.
---@param buf? integer
---@return string[]|nil
function M.update(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not is_open() or buf == state.buf then
    return nil
  end
  local rel, root = note_of(buf)
  if not rel then
    return nil
  end
  local cfg = (config.resolve())
  local model = { note = rel }
  local loaded, warning = index.current(root)
  if not loaded then
    model.message = warning
    model.hint = roots.mode(root, cfg) == 'eigen' and M.HINT_EIGEN or M.HINT_OTHER
  else
    local linked, hidden = {}, 0
    if cfg.hide_linked then
      linked, hidden = linked_notes(buf, rel, loaded.paths)
    end
    -- hidden notes are cut from the answer afterwards, so ask for as many more
    -- `related` answers `results, warning` or `nil, message`; the warning of a torn reload is the
    -- one `index.current` gave just now, too
    local found, why = search.related(rel, { root = root, k = cfg.k + hidden })
    if not found then
      model.message, model.warning = why, warning
    else
      local shown = {}
      for _, r in ipairs(found) do
        if not linked[r.path] and #shown < cfg.k then
          shown[#shown + 1] = r
        end
      end
      model.results, model.warning = shown, warning or why
      if #shown == 0 then
        model.message = search.NO_RESULTS
      end
      model.mark, model.built_ms = index.stale_mark(rel, root), loaded.built_ms
    end
  end
  local lines, rows = M.build(model)
  state.root, state.rows = root, rows
  scratch.set_lines(state.buf, lines)
  return lines
end

-- A window that shows a note (a normal file buffer, not the panel, no float): what a note may be
-- opened or a link written in. An explorer, help or quickfix window is not.
local function is_note_win(win, panel_win)
  return win ~= panel_win
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_config(win).relative == ''
    and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ''
end

-- The window the person came from if it still shows a note, else any other window that does.
local function previous_win()
  local panel_win = vim.api.nvim_get_current_win()
  local nr = vim.fn.winnr('#')
  local prev = nr > 0 and vim.fn.win_getid(nr) or 0
  if prev ~= 0 and is_note_win(prev, panel_win) then
    return prev
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_note_win(win, panel_win) then
      return win
    end
  end
  return nil
end

local function warn(msg)
  vim.notify('note-retrieval: ' .. msg, vim.log.levels.WARN)
end

-- The note under the cursor of the panel, only if its file is still there: a row of an index can
-- outlive the file (moved, deleted since), and `<CR>` must never open an empty buffer under its name.
local function note_under_cursor()
  local path = state.rows[vim.api.nvim_win_get_cursor(0)[1]]
  if not path then
    return nil
  end
  if not uv.fs_stat(state.root .. '/' .. path) then
    warn(path .. ' no longer exists')
    return nil
  end
  return path
end

--- Opens the file `abs` in the window the person came from (or a new one to the left of the panel
--- when there is none) — never in the panel's own window. Meant to be called with the cursor in
--- the panel; `<CR>` and the picker of `:NoteRetrieval search` do.
---@param abs string
function M.open_file(abs)
  local win, made = previous_win(), false
  if not win then
    -- no note window (the panel is alone, or the others are an explorer, help...): a new one to the
    -- left of the panel, which keeps its width, the new window takes the rest
    local panel_win = vim.api.nvim_get_current_win()
    vim.cmd('topleft vsplit')
    win, made = vim.api.nvim_get_current_win(), true
    vim.api.nvim_win_set_width(panel_win, M.WIDTH)
  end
  vim.api.nvim_set_current_win(win)
  local ok, err = pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(abs))
  if not ok then
    warn(tostring(err))
    if made and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

--- Whether the current buffer is the panel's.
---@return boolean
function M.is_current()
  return state.buf ~= nil and vim.api.nvim_get_current_buf() == state.buf
end

local function open_note()
  local path = note_under_cursor()
  if path then
    M.open_file(state.root .. '/' .. path)
  end
end

-- What a link to `path` says: the name of the note; where that name alone would not find this
-- note (another note ends with it too), its path, so the link is not left ambiguous.
local function link_text(kind, path)
  local name = roots.title_of(path)
  local loaded = index.current(state.root)
  if kind == 'wiki' and loaded and links.resolve(name, loaded.paths) ~= path then
    return links.format(kind, path, (path:gsub('%.md$', '')))
  end
  return links.format(kind, path, name)
end

local function insert_link()
  local path = note_under_cursor()
  if not path then
    return
  end
  local win = previous_win()
  local buf = win and vim.api.nvim_win_get_buf(win)
  if not buf or vim.bo[buf].buftype ~= '' or not vim.bo[buf].modifiable then
    warn('no note window to put the link in')
    return
  end
  local text = link_text((config.resolve()).link_format, path)
  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  -- after the character under the cursor, like `a`; a second link then lands behind the first
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  if line ~= '' then
    col = col + #vim.fn.strcharpart(line, vim.fn.charidx(line, col), 1)
  end
  -- `edits.apply` closes the open undo block in the note buffer first, or the link and the last
  -- typed change there would be undone together (see nvim-plugins AGENTS.md, Gotchas).
  edits.apply(buf, row - 1, { line }, { { start = col, stop = col, text = text } })
  vim.api.nvim_win_set_cursor(win, { row, col + #text - 1 })
end

local function teardown()
  state = { buf = nil, root = nil, rows = {} }
  if debouncer then
    debouncer.cancel()
  end
  pcall(vim.api.nvim_del_augroup_by_name, GROUP)
end

function M.close()
  local buf = state.buf
  teardown()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    scratch.close(buf)
  end
end

local function on_enter(buf)
  if buf == state.buf or not note_of(buf) then
    return
  end
  debouncer.call(buf)
end

--- Opens the panel on the right, or closes it when it is open. It shows the notes related to the
--- note you are in and follows you from note to note; the cursor stays in the window you came from.
function M.toggle()
  if is_open() then
    return M.close()
  end
  debouncer = debouncer
    or debounce.new(M.DEBOUNCE_MS, function(buf)
      if state.buf then
        M.update(buf)
      end
    end)
  local origin = vim.api.nvim_get_current_win()
  local note_buf = vim.api.nvim_get_current_buf()
  vim.cmd(('botright %dvsplit'):format(M.WIDTH))
  local win = vim.api.nvim_get_current_win()
  local buf = scratch.open(M.NAME, { 'Related notes: open a note of a vault' }, {
    filetype = 'note-retrieval',
    keys = {
      ['<CR>'] = open_note,
      ['l'] = insert_link,
      ['q'] = M.close,
    },
  })
  for name, value in pairs({
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    wrap = false,
    winfixwidth = true,
  }) do
    vim.wo[win][name] = value
  end
  state = { buf = buf, root = nil, rows = {} }
  vim.api.nvim_set_current_win(origin)
  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    callback = function(args)
      on_enter(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', { group = group, buffer = buf, callback = teardown })
  M.update(note_buf)
end

return M
