local M = {}

local utf8 = "[\194-\244][\128-\191]+"
local readings ---@type table<string, string[]>?
local unavailable = false
local buffers = {} ---@type table<number, table>

vim.api.nvim_create_autocmd("BufWipeout", {
  callback = function(ev)
    buffers[ev.buf] = nil
  end,
})

---@param input string
---@return string?
local function normalize(input)
  if not input:match("^[a-zA-Z]+$") then
    return
  end
  if input:find("%u") and (not vim.go.ignorecase or vim.go.smartcase) then
    return
  end
  return input:lower()
end

---@param pattern Flash.Pattern
---@return string
local function input(pattern)
  local value = pattern()
  if pattern.trigger ~= "" and value:sub(-#pattern.trigger) == pattern.trigger then
    value = value:sub(1, -#pattern.trigger - 1)
  end
  return value
end

local dictionary

local function load()
  if unavailable then
    return
  end
  if not readings then
    local ok, data = pcall(require, "flash.pinyin.data")
    if ok and type(data) == "table" then
      for syllable, chars in pairs(data) do
        if type(syllable) ~= "string" or type(chars) ~= "string" then
          ok = false
          break
        end
      end
    else
      ok = false
    end
    if not ok then
      unavailable = true
      vim.schedule(function()
        vim.notify_once(
          'flash.nvim: Pinyin dictionary is missing or invalid. Set build = "python3 scripts/generate_pinyin.py"'
            .. " in your lazy.nvim spec, run :Lazy build flash.nvim, then restart Neovim."
            .. " Ordinary text search remains available.",
          vim.log.levels.WARN
        )
      end)
      return
    end
    dictionary = { groups = data, classes = {}, patterns = {} }
    readings = {}
    for syllable, chars in pairs(data) do
      for char in chars:gmatch(utf8) do
        readings[char] = readings[char] or {}
        table.insert(readings[char], syllable)
      end
    end
  end
  return dictionary
end

-- Store only dictionary-character runs, deduplicated across the buffer. Line
-- metadata lets on_lines replace the changed range without rescanning the file.
local function change_run(cached, run, delta)
  local count = cached.runs[run] or 0
  local next_count = count + delta
  cached.runs[run] = next_count > 0 and next_count or nil
  if (count == 0) == (next_count == 0) then
    return
  end
  cached.continuations = {}
  if next_count == 0 then
    cached.run_info[run] = nil
  end
  for char in run:gmatch(utf8) do
    local before = cached.chars[char] or 0
    local after = before + (next_count == 0 and -1 or 1)
    cached.chars[char] = after > 0 and after or nil
    if (before == 0) ~= (after == 0) then
      cached.dirty = true
    end
  end
end

local function line_runs(line)
  local runs, chars, previous = {}, {}, 0
  local function flush()
    if #chars > 0 then
      runs[#runs + 1] = table.concat(chars)
      chars = {}
    end
  end
  for start, char, finish in line:gmatch("()([\194-\244][\128-\191]+)()") do
    if start ~= previous or not readings[char] then
      flush()
    end
    if readings[char] then
      chars[#chars + 1] = char
    end
    previous = finish
  end
  flush()
  return runs
end

local function replace_lines(cached, first, last, lines)
  local deltas = {}
  for i = first + 1, last do
    for _, run in ipairs(cached.lines[i]) do
      deltas[run] = (deltas[run] or 0) - 1
    end
  end
  local delta = #lines - (last - first)
  local count = #cached.lines
  if delta > 0 then
    for i = count, last + 1, -1 do
      cached.lines[i + delta] = cached.lines[i]
    end
  elseif delta < 0 then
    for i = last + 1, count do
      cached.lines[i + delta] = cached.lines[i]
    end
    for i = count + delta + 1, count do
      cached.lines[i] = nil
    end
  end
  local previous_line, runs
  for i, line in ipairs(lines) do
    if line ~= previous_line then
      runs = line_runs(line)
      previous_line = line
    end
    cached.lines[first + i] = runs
    for _, run in ipairs(runs) do
      deltas[run] = (deltas[run] or 0) + 1
    end
  end
  for run, delta in pairs(deltas) do
    if delta ~= 0 then
      change_run(cached, run, delta)
    end
  end
end

---@param buf number
local function index(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  if not load() then
    return
  end
  local cached = buffers[buf]
  if not cached then
    cached = { lines = {}, runs = {}, run_info = {}, chars = {}, continuations = {}, dirty = true }
    buffers[buf] = cached
    replace_lines(cached, 0, 0, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = function(_, buffer, _, first, last, new_last)
        if buffers[buffer] ~= cached then
          return true
        end
        replace_lines(cached, first, last, vim.api.nvim_buf_get_lines(buffer, first, new_last, false))
      end,
      on_reload = function(_, buffer)
        if buffers[buffer] == cached then
          replace_lines(cached, 0, #cached.lines, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
        end
      end,
      on_detach = function(_, buffer)
        if buffers[buffer] == cached then
          buffers[buffer] = nil
        end
      end,
    })
  end
  if cached.dirty then
    cached.groups, cached.classes, cached.patterns = {}, {}, {}
    local groups = {}
    for char in pairs(cached.chars) do
      for _, syllable in ipairs(readings[char]) do
        groups[syllable] = groups[syllable] or {}
        table.insert(groups[syllable], char)
      end
    end
    for syllable, chars in pairs(groups) do
      cached.groups[syllable] = table.concat(chars)
    end
    cached.dirty = false
  end
  return cached
end

-- Keep caches bounded during long editing sessions. Clearing a cache only
-- affects compilation time, never the set of matches.
local function put(cache, key, value)
  if vim.tbl_count(cache) >= 128 then
    for old in pairs(cache) do
      cache[old] = nil
    end
  end
  cache[key] = value
  return value
end

local function class(cached, value, exact)
  local key = (exact and "=" or "^") .. value
  if cached.classes[key] == nil then
    local chars, seen = {}, {}
    for syllable, group in pairs(cached.groups) do
      if (exact and syllable == value) or (not exact and syllable:sub(1, #value) == value) then
        for char in group:gmatch(utf8) do
          if not seen[char] then
            seen[char] = true
            chars[#chars + 1] = char
          end
        end
      end
    end
    table.sort(chars)
    put(cached.classes, key, #chars > 0 and ("[" .. table.concat(chars) .. "]") or "")
  end
  return cached.classes[key] ~= "" and cached.classes[key] or nil
end

local budget_error = {}
local regex_limit = 256 * 1024

local function concat(parts, separator)
  local size = 0
  for _, part in ipairs(parts) do
    size = size + #part + #(separator or "")
    if size > regex_limit then
      error(budget_error)
    end
  end
  return table.concat(parts, separator)
end

local function either(parts)
  local unique, seen = {}, {}
  for _, part in ipairs(parts) do
    if part and not seen[part] then
      seen[part] = true
      unique[#unique + 1] = part
    end
  end
  if #unique == 0 then
    return nil
  end
  return #unique == 1 and unique[1] or ("\\%(" .. concat(unique, "\\|") .. "\\)")
end

local function cache_key(value, opts)
  opts = opts or {}
  return value
    .. ":"
    .. (opts.cross_character and "f" or "")
    .. (opts.initials and "i" or "")
    .. (opts.mixed and "m" or "")
end

local function compile_impl(cached, value, opts)
  opts = opts or {}
  local key = cache_key(value, opts)
  if cached.patterns[key] ~= nil then
    return cached.patterns[key] ~= "" and cached.patterns[key] or nil, key
  end
  local initials = {}
  local function tail(pos)
    if initials[pos] == nil then
      local parts = {}
      for i = pos, #value do
        local part = class(cached, value:sub(i, i))
        if not part then
          initials[pos] = false
          return nil
        end
        parts[#parts + 1] = part
      end
      initials[pos] = concat(parts)
    end
    return initials[pos] or nil
  end
  local full, mixed = {}, {}
  local function suffix(pos, mode)
    local memo = mode == "full" and full or mixed
    if memo[pos] ~= nil then
      return memo[pos] or nil
    end
    local parts = {}
    if mode == "full" then
      parts[#parts + 1] = class(cached, value:sub(pos))
    end
    -- A complete syllable consumes at least one letter and leaves at least
    -- one for the next character. All splits remain valid (xi'an / xian).
    for stop = pos, math.min(#value - 1, pos + 5) do
      local head = class(cached, value:sub(pos, stop), true)
      if head then
        local rest
        if mode == "full" then
          rest = suffix(stop + 1, mode)
        else
          rest = either({ tail(stop + 1) or false, suffix(stop + 1, mode) or false })
        end
        if rest then
          parts[#parts + 1] = concat({ head, rest })
        end
      end
    end
    memo[pos] = either(parts) or false
    return memo[pos] or nil
  end
  local parts = { class(cached, value) or false }
  if opts.cross_character then
    parts[#parts + 1] = suffix(1, "full") or false
  end
  if opts.initials and #value >= 2 then
    parts[#parts + 1] = tail(1) or false
  end
  if opts.mixed then
    parts[#parts + 1] = suffix(1, "mixed") or false
  end
  local result = either(parts)
  put(cached.patterns, key, result or "")
  return result, key
end

local function compile(cached, value, opts)
  local ok, result, key = pcall(compile_impl, cached, value, opts)
  if not ok then
    if result ~= budget_error then
      error(result)
    end
    put(cached.patterns, cache_key(value, opts), "")
    vim.schedule(function()
      vim.notify_once(
        "flash.nvim: This pinyin query has too many ambiguous syllable combinations. "
          .. "Use a shorter query or disable mixed/cross_character matching. Ordinary text search remains available.",
        vim.log.levels.WARN
      )
    end)
    return nil
  end
  return result, key
end

local function expand(cached, pattern, opts)
  local value = normalize(input(pattern))
  local chars = cached and value and compile(cached, value, opts)
  return chars and ("\\m\\%(" .. pattern.search .. "\\m\\|" .. chars .. "\\)") or pattern.search
end

---@param buf number
---@param pattern Flash.Pattern
---@param opts? table
---@return string
function M.pattern(buf, pattern, opts)
  if not normalize(input(pattern)) then
    return pattern.search
  end
  return expand(index(buf), pattern, opts)
end

-- Unlike the interactive matcher, this includes characters absent from the
-- current buffer so native n/N also work after edits and in other buffers.
---@param pattern Flash.Pattern
---@param opts? table
---@return string
function M.full_pattern(pattern, opts)
  if not normalize(input(pattern)) then
    return pattern.search
  end
  local expression = expand(load(), pattern, opts)
  if expression ~= pattern.search then
    local ok = pcall(vim.regex, expression)
    if not ok then
      vim.schedule(function()
        vim.notify_once("flash.nvim: Pinyin query exceeds Vim regex limits. Use a shorter query.", vim.log.levels.WARN)
      end)
      return pattern.search
    end
  end
  return expression
end

local function run_info(run)
  local info = { chars = {}, starts = {} }
  for char in run:gmatch(utf8) do
    info.chars[#info.chars + 1] = char
    local seen = {}
    for _, syllable in ipairs(readings[char]) do
      local initial = syllable:sub(1, 1)
      if not seen[initial] then
        seen[initial] = true
        info.starts[initial] = info.starts[initial] or {}
        table.insert(info.starts[initial], #info.chars)
      end
    end
  end
  return info
end

-- Traverse spelling states once per query to collect all legal next letters.
-- Memoization shares ambiguous segmentations, and duplicate runs are visited
-- only once. No per-label regex compilation or full-buffer scans are needed.
local function continuations(cached, value, opts)
  opts = opts or {}
  local key = cache_key(value, opts)
  if cached.continuations[key] then
    return cached.continuations[key]
  end
  local letters, remaining = {}, nil
  local syllables = vim.tbl_keys(cached.groups)
  local function scan(info)
    -- Without a run, compute an upper bound ignoring adjacency. Once every
    -- possible continuation has been found, the remaining runs cannot add any.
    local chars = info and info.chars
    local visited = {}
    local walk
    walk = function(pos, offset, mode)
      if chars and not chars[pos] then
        return
      end
      local id = pos .. ":" .. offset .. ":" .. mode
      if visited[id] then
        return
      end
      visited[id] = true
      local rest = value:sub(offset)
      local function consume(token, next_mode, allowed)
        if #rest < #token then
          if allowed and token:sub(1, #rest) == rest then
            local letter = token:sub(#rest + 1, #rest + 1)
            letters[letter] = true
            if remaining then
              remaining[letter] = nil
            end
          end
        elseif next_mode and rest:sub(1, #token) == token then
          walk(pos + 1, offset + #token, next_mode)
        end
      end
      for _, syllable in ipairs(chars and readings[chars[pos]] or syllables) do
        if mode == "single" then
          consume(syllable, nil, true)
        elseif mode == "full" then
          consume(syllable, "full", true)
        elseif mode == "initials" then
          consume(syllable:sub(1, 1), "initials", true)
        else
          -- A mixed full-spelling prefix needs a following Han character
          -- that can eventually supply the required initials tail.
          consume(syllable, "mixed", not chars or chars[pos + 1] ~= nil)
          if mode == "mixed" then
            consume(syllable:sub(1, 1), "initials", true)
          end
        end
      end
    end
    for _, pos in ipairs(info and (info.starts[value:sub(1, 1)] or {}) or { 1 }) do
      walk(pos, 1, "single")
      if opts.cross_character then
        walk(pos, 1, "full")
      end
      if opts.initials then
        walk(pos, 1, "initials")
      end
      if opts.mixed then
        walk(pos, 1, "mixed_start")
      end
      if remaining and not next(remaining) then
        return
      end
    end
  end
  scan()
  if not opts.cross_character and not opts.initials and not opts.mixed then
    -- The character inventory already proves every single-character prefix.
    return put(cached.continuations, key, letters)
  end
  remaining, letters = letters, {}
  for run in pairs(cached.runs) do
    if not next(remaining) then
      break
    end
    local info = cached.run_info[run] or put(cached.run_info, run, run_info(run))
    scan(info)
  end
  return put(cached.continuations, key, letters)
end

---@param win number
---@param pattern Flash.Pattern
---@param labels string[]
---@param opts? table
---@return string[]
function M.skip(win, pattern, labels, opts)
  if pattern.trigger ~= "" and pattern():sub(-#pattern.trigger) == pattern.trigger then
    return labels
  end
  local value = input(pattern)
  local normalized = normalize(value)
  if not normalized or #labels == 0 then
    return labels
  end
  local cached = index(vim.api.nvim_win_get_buf(win))
  if not cached then
    return labels
  end
  local letters = continuations(cached, normalized, opts)
  return vim.tbl_filter(function(label)
    local char = vim.go.ignorecase and label:lower() or label
    return not normalize(value .. char) or not letters[char:lower()]
  end, labels)
end

-- A mixed-only query may temporarily have no complete matches while the user
-- spells the next syllable. Keep input active only if a real continuation exists.
function M.can_continue(win, pattern, opts)
  if not opts.mixed or (pattern.trigger ~= "" and pattern():sub(-#pattern.trigger) == pattern.trigger) then
    return false
  end
  local value = normalize(input(pattern))
  local cached = value and index(vim.api.nvim_win_get_buf(win))
  return cached ~= nil and next(continuations(cached, value, opts)) ~= nil
end

return M
