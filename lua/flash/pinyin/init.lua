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
    dictionary = { groups = data, classes = {}, patterns = {}, matches = {} }
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

---@param buf number
local function index(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if buffers[buf] and buffers[buf].tick == tick then
    return buffers[buf]
  end
  if not load() then
    return
  end
  -- Only include characters actually present in this buffer. Huge dictionary
  -- classes make Vim's regex matching slow, even on a small visible region.
  local groups, seen = {}, {}
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, line in ipairs(lines) do
    for char in line:gmatch(utf8) do
      if not seen[char] then
        seen[char] = true
        for _, syllable in ipairs(readings[char] or {}) do
          groups[syllable] = (groups[syllable] or "") .. char
        end
      end
    end
  end
  buffers[buf] = { tick = tick, groups = groups, classes = {}, patterns = {}, matches = {}, lines = lines }
  return buffers[buf]
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
  if not normalize(value) then
    return labels
  end
  local cached = index(vim.api.nvim_win_get_buf(win))
  if not cached then
    return labels
  end
  return vim.tbl_filter(function(label)
    local char = vim.go.ignorecase and label:lower() or label
    local next_value = normalize(value .. char)
    if not next_value then
      return true
    end
    local expression, key = compile(cached, next_value, opts)
    key = key or cache_key(next_value, opts)
    if opts and opts.mixed then
      -- A full syllable may still be in progress before entering the initials
      -- tail. Reserve its continuation only when a following Han character
      -- actually exists, allowing e.g. zhongw -> zhongwu -> zhongwuh.
      local pending = compile(cached, next_value, { cross_character = true })
      if pending then
        local all = class(cached, "")
        local ok, combined = pcall(function()
          return either({ expression or false, concat({ pending, all }) })
        end)
        if ok then
          expression = combined
        end
      end
      key = key .. ":pending"
    end
    if not expression then
      return true
    end
    if cached.matches[key] == nil then
      local ok, regex = pcall(vim.regex, "\\m" .. expression)
      if not ok then
        vim.schedule(function()
          vim.notify_once(
            "flash.nvim: Pinyin query exceeds Vim regex limits. Use a shorter query.",
            vim.log.levels.WARN
          )
        end)
        put(cached.matches, key, false)
        return true
      end
      local found = false
      for _, line in ipairs(cached.lines) do
        if regex:match_str(line) ~= nil then
          found = true
          break
        end
      end
      put(cached.matches, key, found)
    end
    return not cached.matches[key]
  end, labels)
end

return M
