-- vendored from nvim-kit@0.16.1 (lua/nvim_kit/walk.lua) — do not edit; re-vendor
-- Walking a directory tree for Markdown notes: the paths of every `*.md` under a root, relative to
-- it, `/`-separated and sorted by bytes. Synchronous (`vim.uv.fs_scandir`), so it belongs in a
-- command or a startup step, not in a fast callback loop.
local M = {}

local uv = vim.uv or vim.loop
local text = require((...):gsub('walk$', '') .. 'text')

local function starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

--- The paths of all Markdown notes (`*.md`, extension in lower case) under `root`, relative to it
--- and `/`-separated, sorted by bytes (`text.byte_less`), as `{ paths = {...}, skipped = {...} }`.
--- `skipped` lists the directories that could not be read, or not to the end because the read
--- failed half way (the notes listed before the failure stay in `paths`); relative,
--- `/`-separated, sorted the same way, `.` for the root itself. Their notes are missing from
--- `paths`, so the caller must say so. A `root` that
--- cannot be read raises: an empty result for a vault that is not there would look like an empty
--- vault.
---
--- `opts.exclude` is a list of prefixes of the relative path (`'Templates/'`, case-sensitive
--- `startsWith`; a directory is pruned when its path plus `/` starts with one, so its notes are
--- never listed). `opts.skip(rel_dir)` is a predicate over the relative path of a directory (no
--- trailing `/`) that prunes the directory when it returns true; it does not count as unreadable.
--- A name that starts with `.` (file or directory, so `.git`, `.obsidian`, `.trash`) is never
--- entered or listed. Symbolic links to directories are not followed (no cycle); a symbolic link
--- to a Markdown file is listed, a broken one is not.
---
--- Measured 2026-10-26 on Neovim 0.12.6 (macOS, APFS, warm cache): a personal vault of 10 766 notes
--- in 1 115 directories (dot directories left out; `find` counts the same 10 766), walks in 34-42 ms
--- over five runs.
function M.markdown(root, opts)
  if type(root) ~= 'string' or root == '' then
    error('nvim-kit walk: markdown(root, opts?) needs a root directory', 2)
  end
  opts = opts or {}
  local exclude = opts.exclude or {}
  local skip = opts.skip
  if type(exclude) ~= 'table' then
    error('nvim-kit walk: markdown: opts.exclude must be a list of strings', 2)
  end
  for _, prefix in ipairs(exclude) do
    if type(prefix) ~= 'string' then
      error('nvim-kit walk: markdown: opts.exclude must be a list of strings', 2)
    end
  end
  if skip ~= nil and type(skip) ~= 'function' then
    error('nvim-kit walk: markdown: opts.skip must be a function', 2)
  end
  root = root:gsub('/+$', '')
  if root == '' then
    root = '/'
  end

  local function excluded(rel)
    for _, prefix in ipairs(exclude) do
      if starts_with(rel, prefix) then
        return true
      end
    end
    return false
  end

  local paths, skipped = {}, {}
  local base = root == '/' and '' or root
  local stack = { '' }
  while #stack > 0 do
    local rel_dir = table.remove(stack)
    local abs_dir = rel_dir == '' and (base == '' and '/' or base) or (base .. '/' .. rel_dir)
    local handle, err = uv.fs_scandir(abs_dir)
    if not handle then
      if rel_dir == '' then
        error(('nvim-kit walk: markdown: cannot read %s: %s'):format(root, tostring(err)), 2)
      end
      skipped[#skipped + 1] = rel_dir
    else
      local prefix = rel_dir == '' and '' or (rel_dir .. '/')
      while true do
        local name, kind = uv.fs_scandir_next(handle)
        if not name then
          if kind ~= nil then
            -- (nil, error) in the middle of a directory is no end of it: what was listed before
            -- stays, and the directory is reported as not fully read
            skipped[#skipped + 1] = rel_dir == '' and '.' or rel_dir
          end
          break
        end
        if name:sub(1, 1) ~= '.' then
          local rel = prefix .. name
          if kind == nil or kind == 'unknown' or kind == 'link' then
            -- a link counts by its target; a link to a directory is not followed
            local st = uv.fs_stat(base .. '/' .. rel)
            if st and st.type == 'file' then
              kind = 'file'
            elseif kind == 'link' then
              kind = 'link-skipped'
            else
              local lst = uv.fs_lstat(base .. '/' .. rel)
              kind = lst and lst.type or 'unknown'
            end
          end
          if kind == 'directory' then
            if not excluded(rel .. '/') and not (skip and skip(rel)) then
              stack[#stack + 1] = rel
            end
          elseif kind == 'file' then
            if name:sub(-3) == '.md' and #name > 3 and not excluded(rel) then
              paths[#paths + 1] = rel
            end
          end
        end
      end
    end
  end
  table.sort(paths, text.byte_less)
  table.sort(skipped, text.byte_less)
  return { paths = paths, skipped = skipped }
end

return M
