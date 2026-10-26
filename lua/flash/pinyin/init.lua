local M = {}

local utf8 = "[\194-\244][\128-\191]+"
local readings ---@type table<string, string[]>?
local unavailable = false
local buffers = {} ---@type table<number, {tick:number, groups:table<string, string>, classes:table<string, string>}>

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

---@param buf number
local function index(buf)
  if unavailable then
    return
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if buffers[buf] and buffers[buf].tick == tick then
    return buffers[buf]
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
    readings = {}
    for syllable, chars in pairs(data) do
      for char in chars:gmatch(utf8) do
        readings[char] = readings[char] or {}
        table.insert(readings[char], syllable)
      end
    end
  end
  -- Only include characters actually present in this buffer. Huge dictionary
  -- classes make Vim's regex matching slow, even on a small visible region.
  local groups, seen = {}, {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    for char in line:gmatch(utf8) do
      if not seen[char] then
        seen[char] = true
        for _, syllable in ipairs(readings[char] or {}) do
          groups[syllable] = (groups[syllable] or "") .. char
        end
      end
    end
  end
  buffers[buf] = { tick = tick, groups = groups, classes = {} }
  return buffers[buf]
end

---@param buf number
---@param value string
---@return string?
local function class(buf, value)
  local prefix = normalize(value)
  if not prefix then
    return
  end
  local cached = index(buf)
  if not cached then
    return
  end
  if cached.classes[prefix] == nil then
    local chars = {}
    for syllable, group in pairs(cached.groups) do
      if syllable:sub(1, #prefix) == prefix then
        chars[#chars + 1] = group
      end
    end
    -- A repeated character in a class still yields one match per position.
    cached.classes[prefix] = #chars > 0 and ("[" .. table.concat(chars) .. "]") or ""
  end
  return cached.classes[prefix] ~= "" and cached.classes[prefix] or nil
end

---@param buf number
---@param pattern Flash.Pattern
---@return string
function M.pattern(buf, pattern)
  local chars = class(buf, input(pattern))
  return chars and ("\\m\\%(" .. pattern.search .. "\\m\\|" .. chars .. "\\)") or pattern.search
end

---@param win number
---@param pattern Flash.Pattern
---@param labels string[]
---@return string[]
function M.skip(win, pattern, labels)
  if pattern.trigger ~= "" and pattern():sub(-#pattern.trigger) == pattern.trigger then
    return labels
  end
  local value = input(pattern)
  if not normalize(value) then
    return labels
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.tbl_filter(function(label)
    -- Follow the existing conservative case handling for jump labels. The
    -- buffer index already tells us which continuations have actual matches.
    local char = vim.go.ignorecase and label:lower() or label
    return class(buf, value .. char) == nil
  end, labels)
end

return M
