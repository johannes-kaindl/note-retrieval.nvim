-- vendored from nvim-kit@0.17.1 (lua/nvim_kit/edits.lua) — do not edit; re-vendor
-- Byte offsets into a range of buffer lines, and replacements applied back to them. The text of a
-- range is its lines joined with "\n" plus one final "\n" (what a search over the range sees, see
-- nvim_kit.rg). Offsets and columns are bytes, as Neovim's are, so multibyte characters need no
-- conversion. The final "\n" belongs to the range's text, not to the buffer: an edit that reaches
-- into it ends at the end of the last line instead, so text after the range is never joined in.
local M = {}

--- The text a search over lines sees: the lines joined with "\n", plus a final "\n".
function M.text(lines)
  return table.concat(lines, '\n') .. '\n'
end

--- The byte offset of each line's start in M.text(lines) (0-based offsets, 1-based list).
function M.line_starts(lines)
  local starts, at = {}, 0
  for i, l in ipairs(lines) do
    starts[i] = at
    at = at + #l + 1
  end
  return starts
end

--- Row and column (0-based, relative to the first line, bytes) of a byte offset into
--- M.text(lines). An offset at or past the final "\n" is the end of the last line.
function M.position(lines, starts, offset)
  local n = #lines
  if n == 0 then
    return 0, 0
  end
  if offset >= starts[n] + #lines[n] then
    return n - 1, #lines[n]
  end
  local lo, hi = 1, n
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if starts[mid] <= offset then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return lo - 1, offset - starts[lo]
end

--- Each edit { start, stop, text } (byte offsets into M.text(lines), stop exclusive) with its
--- positions added: row, col, end_row, end_col (0-based, relative to the first line). An edit
--- that reaches into the final "\n" loses one trailing "\n" of its text, since that "\n" stays.
function M.locate(lines, list)
  local starts = M.line_starts(lines)
  local total = #M.text(lines)
  local out = {}
  for i, e in ipairs(list) do
    local row, col = M.position(lines, starts, e.start)
    local end_row, end_col = M.position(lines, starts, e.stop)
    local text = e.text
    if e.stop >= total and text:sub(-1) == '\n' then
      text = text:sub(1, -2)
    end
    out[i] = vim.tbl_extend('force', e, {
      row = row,
      col = col,
      end_row = end_row,
      end_col = end_col,
      text = text,
    })
  end
  return out
end

--- Replace the edits' spans of buf, whose lines first..first+#lines-1 (0-based first) must still
--- be exactly lines: else nothing is written and the result is false, 'changed'. Edits are
--- { start, stop, text } as for M.locate; they go in back to front, so earlier offsets stay
--- valid, and all of them form one undo step; insertions at one offset keep their order in list.
--- Raises on invalid arguments (first a whole number >= 0, lines a list of strings, each edit
--- whole numbers 0 <= start <= stop and a string text, edits over an empty lines) and on
--- overlapping edits, always before anything is read or written. Returns true, count.
function M.apply(buf, first, lines, list)
  if type(first) ~= 'number' or first < 0 or first % 1 ~= 0 then
    error('nvim-kit edits: apply needs first (a whole number >= 0, the 0-based first line)', 2)
  end
  if type(lines) ~= 'table' then
    error('nvim-kit edits: apply needs lines (a list of strings)', 2)
  end
  for i, l in ipairs(lines) do
    if type(l) ~= 'string' then
      error(('nvim-kit edits: apply needs lines (a list of strings), line %d is not'):format(i), 2)
    end
  end
  if type(list) ~= 'table' then
    error('nvim-kit edits: apply needs list (a list of edits)', 2)
  end
  for i, e in ipairs(list) do
    if
      type(e) ~= 'table'
      or type(e.start) ~= 'number'
      or type(e.stop) ~= 'number'
      or e.start % 1 ~= 0
      or e.stop % 1 ~= 0
      or e.start < 0
      or e.stop < e.start
      or type(e.text) ~= 'string'
    then
      local why = 'nvim-kit edits: apply: edit %d needs whole numbers 0 <= start <= stop and text'
      error(why:format(i) .. ' (a string)', 2)
    end
  end
  if #lines == 0 and #list > 0 then
    error('nvim-kit edits: apply: edits over empty lines (nothing to edit)', 2)
  end
  local now = vim.api.nvim_buf_get_lines(buf, first, first + #lines, false)
  if not vim.deep_equal(now, lines) then
    return false, 'changed'
  end
  local located = M.locate(lines, list)
  local index = {}
  for i, e in ipairs(located) do
    index[e] = i
  end
  -- Back to front. Insertions at one offset: the one written last lands in front, so the later
  -- one in list goes first.
  table.sort(located, function(a, b)
    if a.start ~= b.start then
      return a.start > b.start
    end
    if a.stop ~= b.stop then
      return a.stop > b.stop
    end
    return index[a] > index[b]
  end)
  for i = 2, #located do
    if located[i].stop > located[i - 1].start then
      error(
        ('nvim-kit edits: edits overlap at bytes %d..%d and %d..%d'):format(
          located[i].start,
          located[i].stop,
          located[i - 1].start,
          located[i - 1].stop
        ),
        2
      )
    end
  end
  -- Close the buffer's open undo block first. Vim closes it on a keystroke only in the current
  -- buffer: an edit typed in buf before switching away would otherwise join these edits, and one
  -- `u` would take back both (measured 2026-10-14).
  vim.api.nvim_buf_call(buf, function()
    vim.cmd('let &g:undolevels = &g:undolevels')
  end)
  for _, e in ipairs(located) do
    vim.api.nvim_buf_set_text(
      buf,
      first + e.row,
      e.col,
      first + e.end_row,
      e.end_col,
      vim.split(e.text, '\n', { plain = true })
    )
  end
  return true, #located
end

return M
