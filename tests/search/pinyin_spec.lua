local State = require("flash.state")
local Util = require("flash.util")
local assert = require("luassert")

describe("pinyin search", function()
  local states, buf, previous_buf, ignorecase, smartcase, extra_win, extra_buf
  local saved_pinyin, saved_data, saved_loader, saved_notify, autocmds
  local search_register, searchforward, hlsearch, saved_notify_once

  local function state(pattern, opts)
    local ret = State.new(vim.tbl_deep_extend("force", {
      pattern = pattern,
      search = { pinyin = true, multi_window = false },
      label = { uppercase = false },
    }, opts or {}))
    states[#states + 1] = ret
    return ret
  end

  local function set(text)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n"))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
  end

  local function positions(s, opts)
    return vim.tbl_map(function(match)
      return { { match.pos[1], match.pos[2] }, { match.end_pos[1], match.end_pos[2] } }
    end, s:get_matcher(s.win):get(opts))
  end

  before_each(function()
    states = {}
    saved_pinyin, saved_data = package.loaded["flash.pinyin"], package.loaded["flash.pinyin.data"]
    saved_loader, saved_notify = package.preload["flash.pinyin.data"], vim.notify
    saved_notify_once = vim.notify_once
    package.loaded["flash.pinyin"] = nil
    package.loaded["flash.pinyin.data"] = {
      hao = "好浩号",
      ni = "你",
      jiao = "角",
      jue = "角",
      nv = "女",
      zhong = "中钟",
      wen = "文",
      wu = "午",
      wa = "哇",
      zui = "最",
      huo = "火",
      xi = "西",
      xian = "先",
      an = "安",
    }
    search_register = vim.fn.getreg("/")
    searchforward, hlsearch = vim.v.searchforward, vim.o.hlsearch
    autocmds = {}
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = "BufWipeout" })) do
      if autocmd.id then
        autocmds[autocmd.id] = true
      end
    end
    ignorecase, smartcase = vim.go.ignorecase, vim.go.smartcase
    vim.go.ignorecase, vim.go.smartcase = true, true
    previous_buf = vim.api.nvim_get_current_buf()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
  end)

  after_each(function()
    for _, s in ipairs(states) do
      s:hide()
    end
    if extra_win and vim.api.nvim_win_is_valid(extra_win) then
      vim.api.nvim_win_close(extra_win, true)
    end
    if extra_buf and vim.api.nvim_buf_is_valid(extra_buf) then
      vim.api.nvim_buf_delete(extra_buf, { force = true })
    end
    extra_win, extra_buf = nil, nil
    vim.api.nvim_set_current_buf(previous_buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.go.ignorecase, vim.go.smartcase = ignorecase, smartcase
    vim.fn.setreg("/", search_register)
    vim.v.searchforward, vim.o.hlsearch = searchforward, hlsearch
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = "BufWipeout" })) do
      if autocmd.id and not autocmds[autocmd.id] then
        vim.api.nvim_del_autocmd(autocmd.id)
      end
    end
    package.loaded["flash.pinyin"], package.loaded["flash.pinyin.data"] = saved_pinyin, saved_data
    package.preload["flash.pinyin.data"], vim.notify = saved_loader, saved_notify
    vim.notify_once = saved_notify_once
  end)

  it("keeps literal search working and warns once when the dictionary is missing", function()
    package.loaded["flash.pinyin.data"] = nil
    local loads, warnings = 0, {}
    package.preload["flash.pinyin.data"] = function()
      loads = loads + 1
      error("dictionary is not installed")
    end
    vim.notify = function(message, level)
      warnings[#warnings + 1] = { message = message, level = level }
    end
    set("好 hao")
    assert.same({ { { 1, 4 }, { 1, 6 } } }, positions(state("hao")))
    set("好 hala hao")
    assert.same({
      { { 1, 4 }, { 1, 5 } },
      { { 1, 9 }, { 1, 10 } },
    }, positions(state("ha")))
    vim.wait(100, function()
      return #warnings > 0
    end)
    assert.equals(1, loads)
    assert.equals(1, #warnings)
    assert.equals(vim.log.levels.WARN, warnings[1].level)
    assert.is_not_nil(warnings[1].message:find("generate_pinyin.py", 1, true))
  end)

  it("combines Chinese prefixes with literal matches using original byte positions", function()
    set("😀\t好 hala hao")
    assert.same({
      { { 1, 5 }, { 1, 5 } },
      { { 1, 9 }, { 1, 10 } },
      { { 1, 14 }, { 1, 15 } },
    }, positions(state("ha")))
    assert.same({
      { { 1, 5 }, { 1, 5 } },
      { { 1, 14 }, { 1, 16 } },
    }, positions(state("hao")))
  end)

  it("accepts every reading and deduplicates a character with multiple matching readings", function()
    set("角 角")
    local expected = { { { 1, 0 }, { 1, 0 } }, { { 1, 4 }, { 1, 4 } } }
    for _, pattern in ipairs({ "j", "jiao", "jue" }) do
      assert.same(expected, positions(state(pattern)))
    end
    set("女")
    assert.same({ { { 1, 0 }, { 1, 0 } } }, positions(state("nv")))
  end)

  it("does not match inside syllables or concatenate Chinese characters", function()
    set("你好 好A")
    for _, pattern in ipairs({ "ao", "nihao", "nh", "haoA" }) do
      assert.same({}, positions(state(pattern)))
    end
    assert.same({ { { 1, 0 }, { 1, 3 } } }, positions(state("你好")))
  end)

  it("matches full syllables and a final prefix with every valid segmentation", function()
    set("中文 先 西安")
    local opts = { search = { pinyin_options = { cross_character = true } } }
    for _, pattern in ipairs({ "zhongw", "zhongwen" }) do
      assert.same({ { { 1, 0 }, { 1, 3 } } }, positions(state(pattern, opts)))
    end
    assert.same({
      { { 1, 7 }, { 1, 7 } },
      { { 1, 11 }, { 1, 14 } },
    }, positions(state("xian", opts)))
    assert.same({}, positions(state("zw", opts)))
  end)

  it("enables initials independently while preserving single-character prefixes", function()
    set("中 最火 中文")
    local opts = { search = { pinyin_options = { initials = true } } }
    assert.same({
      { { 1, 0 }, { 1, 0 } },
      { { 1, 4 }, { 1, 7 } },
      { { 1, 11 }, { 1, 11 } },
    }, positions(state("zh", opts)))
    assert.same({ { { 1, 11 }, { 1, 14 } } }, positions(state("zw", opts)))
    assert.same({}, positions(state("zhongwen", opts)))
  end)

  it("enables mixed input independently and never returns to full spelling after initials", function()
    set("中午好哇")
    local opts = { search = { pinyin_options = { mixed = true } } }
    assert.same({ { { 1, 0 }, { 1, 9 } } }, positions(state("zhongwhw", opts)))
    assert.same({}, positions(state("zhongwhao", opts)))
    assert.same({}, positions(state("zwhw", opts)))
    assert.same({}, positions(state("zhongwuhao", opts)))
    assert.same({}, positions(state("zhongwhw")))
  end)

  it("stops phrases at punctuation, spaces and real newlines but accepts soft wrapping", function()
    set("中 文 中，文 中\n文 中文")
    local opts = { search = { pinyin_options = { cross_character = true, initials = true } } }
    for _, pattern in ipairs({ "zhongwen", "zw" }) do
      assert.same({ { { 2, 4 }, { 2, 7 } } }, positions(state(pattern, opts)))
    end
    vim.cmd("vsplit")
    extra_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(extra_win, 12)
    vim.wo.wrap = true
    set(string.rep(" ", 10) .. "中文")
    assert.same({ { { 1, 10 }, { 1, 13 } } }, positions(state("zhongwen", opts)))
  end)

  it("reserves actual phrase continuations and recomputes them after backspace", function()
    set(" 中午好哇")
    local jumps = {}
    local s = state("zhong", {
      labels = "whq",
      search = { pinyin_options = { mixed = true } },
      action = function(match)
        jumps[#jumps + 1] = match
      end,
    })
    for _, pattern in ipairs({ "zhongw", "zhongwh", "zhongwhw" }) do
      assert.is_nil(s:update({ pattern = pattern }))
      assert.equals(pattern, s.pattern())
    end
    assert.same({}, jumps)
    s:update({ pattern = s.pattern:extend(Util.BS) })
    assert.equals("zhongwh", s.pattern())
    assert.same({ { { 1, 1 }, { 1, 7 } } }, positions(s))
    s:update({ pattern = "zhongwhw" })
    local target = s.results[1]
    assert.is_not_nil(target.label)
    assert.is_true(s:update({ pattern = s.pattern() .. target.label }))
    assert.same({ target }, jumps)
  end)

  it("reserves unfinished full syllables before the initials in mixed-only input", function()
    set(" 中午好")
    local jumps = {}
    local s = state("zhongw", {
      labels = "uhq",
      search = { pinyin_options = { mixed = true } },
      action = function(match)
        jumps[#jumps + 1] = match
      end,
    })
    for _, pattern in ipairs({ "zhongwu", "zhongwuh" }) do
      assert.is_nil(s:update({ pattern = pattern }))
      assert.equals(pattern, s.pattern())
    end
    assert.same({}, jumps)
    assert.same({ { { 1, 1 }, { 1, 7 } } }, positions(s))
  end)

  it("keeps the real input loop active through unfinished mixed syllables", function()
    set(" 中午好")
    local s = state("", { search = { pinyin_options = { mixed = true } } })
    for char in ("zhongwuh"):gmatch(".") do
      s.get_char = function()
        return char
      end
      assert.is_true(s:step())
      if s.pattern() == "zhongwu" then
        assert.same({}, s.results)
      end
    end
    assert.same({ { { 1, 1 }, { 1, 7 } } }, positions(s))
    s.get_char = function()
      return Util.BS
    end
    assert.is_true(s:step())
    assert.equals("zhongwu", s.pattern())
    s.get_char = function()
      return "x"
    end
    assert.is_nil(s:step())
    assert.equals("zhongwux", s.pattern())
  end)

  it("does not keep an unfinished mixed syllable without a following character", function()
    set(" 中午")
    local s = state("zhongw", {
      labels = "q",
      search = { pinyin_options = { mixed = true } },
    })
    s.get_char = function()
      return "u"
    end
    assert.is_nil(s:step())
  end)

  it("collects the same continuations as matching each extension in every mode", function()
    local text = "中午好哇 中文 西安 先 最火 好浩号 你好 女 角 中，文 中😀文"
    set(text)
    local pinyin = require("flash.pinyin")
    local Pattern = require("flash.search.pattern")
    local labels = vim.split("abcdefghijklmnopqrstuvwxyz", "")
    for flags = 0, 7 do
      local opts = {
        cross_character = flags % 2 == 1,
        initials = math.floor(flags / 2) % 2 == 1,
        mixed = math.floor(flags / 4) % 2 == 1,
      }
      for _, value in ipairs({
        "h",
        "ha",
        "hao",
        "n",
        "nv",
        "z",
        "zh",
        "zhong",
        "zhongw",
        "zhongwu",
        "zhongwh",
        "x",
        "xi",
        "xia",
        "xian",
        "j",
        "ju",
        "q",
      }) do
        local expected = {}
        for _, label in ipairs(labels) do
          local pattern = Pattern.new(value .. label, "exact")
          local found = vim.regex(pinyin.pattern(buf, pattern, opts)):match_str(text) ~= nil
          if opts.mixed then
            local pending = pinyin.pattern(buf, pattern, { cross_character = true })
              .. "[中午好哇文西安先最火浩号你女角]"
            found = found or vim.regex(pending):match_str(text) ~= nil
          end
          if not found then
            expected[#expected + 1] = label
          end
        end
        assert.same(expected, pinyin.skip(0, Pattern.new(value, "exact"), labels, opts))
      end
    end
  end)

  it("updates runs and character counts across insertion, deletion and replacement", function()
    set("好\n好\n中文\n中，文\n中😀文")
    local pinyin = require("flash.pinyin")
    local Pattern = require("flash.search.pattern")
    local function matches(value, text)
      return vim.regex(pinyin.pattern(buf, Pattern.new(value, "exact"))):match_str(text) ~= nil
    end
    local function skip()
      return pinyin.skip(0, Pattern.new("zhong", "exact"), { "w" }, { cross_character = true })
    end
    assert.is_true(matches("hao", "好"))
    assert.same({}, skip())
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
    assert.is_true(matches("hao", "好"))
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "你", "女" })
    assert.is_false(matches("hao", "好"))
    assert.is_true(matches("nv", "女"))
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "中 文" })
    assert.same({ "w" }, skip())
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "中文" })
    assert.same({}, skip())
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "ASCII only" })
    assert.is_false(matches("zhong", "中"))
    assert.same({ "w" }, skip())
  end)

  it("refreshes the index after undo and redo", function()
    set("好")
    local pinyin = require("flash.pinyin")
    local Pattern = require("flash.search.pattern")
    local function matches(value, text)
      return vim.regex(pinyin.pattern(buf, Pattern.new(value, "exact"))):match_str(text) ~= nil
    end
    assert.is_true(matches("hao", "好"))
    vim.cmd("let &undolevels = &undolevels")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "女" })
    assert.is_true(matches("nv", "女"))
    assert.is_false(matches("hao", "好"))
    vim.cmd("undo")
    assert.is_true(matches("hao", "好"))
    assert.is_false(matches("nv", "女"))
    vim.cmd("redo")
    assert.is_false(matches("hao", "好"))
    assert.is_true(matches("nv", "女"))
  end)

  it("refreshes the index when a file is reloaded", function()
    local path = vim.fn.tempname()
    local ok, err = pcall(function()
      vim.fn.writefile({ "中文" }, path)
      extra_buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_set_current_buf(extra_buf)
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      local pinyin = require("flash.pinyin")
      local Pattern = require("flash.search.pattern")
      local function skip()
        return pinyin.skip(0, Pattern.new("zhong", "exact"), { "w" }, { cross_character = true })
      end
      assert.same({}, skip())
      vim.fn.writefile({ "好" }, path)
      vim.cmd("edit!")
      assert.same({ "w" }, skip())
      assert.is_not_nil(vim.regex(pinyin.pattern(extra_buf, Pattern.new("hao", "exact"))):match_str("好"))
    end)
    vim.fn.delete(path)
    assert.is_true(ok, err)
  end)

  it("reads only changed lines after warming the buffer index", function()
    local lines = {}
    for i = 1, 1000 do
      lines[i] = "中文"
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local pinyin = require("flash.pinyin")
    local Pattern = require("flash.search.pattern")
    pinyin.pattern(buf, Pattern.new("zhong", "exact"))
    local original, reads = vim.api.nvim_buf_get_lines, {}
    vim.api.nvim_buf_get_lines = function(buffer, first, last, strict)
      reads[#reads + 1] = { first, last }
      return original(buffer, first, last, strict)
    end
    local ok, err = pcall(function()
      vim.api.nvim_buf_set_lines(buf, 500, 501, false, { "好" })
      local expression = pinyin.pattern(0, Pattern.new("hao", "exact"))
      assert.is_not_nil(vim.regex(expression):match_str("好"))
      pinyin.skip(0, Pattern.new("h", "exact"), { "a", "q" })
    end)
    vim.api.nvim_buf_get_lines = original
    assert.is_true(ok, err)
    assert.same({ { 500, 501 } }, reads)
  end)

  it("falls back to literal search with a warning for excessively ambiguous queries", function()
    local warnings = {}
    vim.notify_once = function(message, level)
      warnings[#warnings + 1] = { message = message, level = level }
    end
    local pattern = require("flash.search.pattern").new(string.rep("xian", 16), "exact")
    local opts = { cross_character = true }
    local pinyin = require("flash.pinyin")
    assert.equals(pattern.search, pinyin.full_pattern(pattern, opts))
    assert.equals(pattern.search, pinyin.full_pattern(pattern, opts))
    vim.wait(100, function()
      return #warnings > 0
    end)
    assert.equals(1, #warnings)
    assert.equals(vim.log.levels.WARN, warnings[1].level)
    assert.is_truthy(warnings[1].message:find("ambiguous", 1, true))
    assert.is_truthy(vim.regex(pattern.search):match_str(pattern()))
  end)

  it("retains a complete dictionary search for native repeats across edits and buffers", function()
    set("中")
    local s = state("zhong", {
      search = { pinyin_options = { retain_search = true } },
      jump = { register = false },
    })
    vim.o.hlsearch = true
    vim.fn.setreg("/", "中")
    vim.v.hlsearch = 1
    require("flash.jump").on_jump(s)
    local retained = vim.fn.getreg("/")
    assert.is_truthy(vim.regex(retained):match_str("钟"))
    assert.is_truthy(vim.regex(retained):match_str("zhong"))
    assert.is_true(vim.o.hlsearch)
    assert.equals(0, vim.v.hlsearch)
    set("中 钟")
    vim.v.searchforward = 1
    vim.cmd("normal! n")
    assert.same({ 1, 4 }, vim.api.nvim_win_get_cursor(0))
    vim.cmd("normal! N")
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
    extra_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(extra_buf)
    vim.api.nvim_buf_set_lines(extra_buf, 0, -1, false, { " 钟" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! n")
    assert.same({ 1, 1 }, vim.api.nvim_win_get_cursor(0))
    assert.equals(retained, vim.fn.getreg("/"))
  end)

  it("does not retain searches without both the feature switch and eligible pinyin mode", function()
    set("中")
    for _, opts in ipairs({
      {},
      { search = { pinyin = false, pinyin_options = { retain_search = true } } },
      { mode = "char", search = { mode = "exact", pinyin_options = { retain_search = true } } },
    }) do
      vim.fn.setreg("/", "previous")
      local s = state("zhong", vim.tbl_deep_extend("force", { jump = { register = false } }, opts))
      require("flash.jump").on_jump(s)
      assert.equals("previous", vim.fn.getreg("/"))
    end
  end)

  it("allows continued pinyin input and backspace before jumping with a label", function()
    set(" 好 hala 浩")
    local jumps = {}
    local s = state("h", {
      labels = "aoz",
      action = function(match)
        jumps[#jumps + 1] = match
      end,
    })
    assert.is_nil(s:update({ pattern = "ha" }))
    assert.equals("ha", s.pattern())
    assert.equals(3, #s.results)
    assert.is_nil(s:update({ pattern = "hao" }))
    assert.equals("hao", s.pattern())
    assert.equals(2, #s.results)
    assert.same({}, jumps)
    s:update({ pattern = s.pattern:extend(Util.BS) })
    assert.equals("ha", s.pattern())
    assert.equals(3, #s.results)
    s:update({ pattern = "hao" })
    local target
    for _, match in ipairs(s.results) do
      if match.label then
        target = match
        break
      end
    end
    assert.is_not_nil(target)
    assert.is_true(s:update({ pattern = "hao" .. target.label }))
    assert.same({ target }, jumps)
  end)

  it("honors ignorecase and smartcase for uppercase pinyin", function()
    set("好 HAO hao")
    assert.equals(1, #positions(state("HAO")))
    vim.go.smartcase = false
    assert.equals(3, #positions(state("HAO")))
    vim.go.ignorecase = false
    assert.equals(1, #positions(state("HAO")))
    assert.equals(2, #positions(state("hao")))
  end)

  it("leaves disabled, nonexact and custom matching unchanged", function()
    set("好 hao")
    local literal = { { { 1, 4 }, { 1, 6 } } }
    assert.same(literal, positions(state("hao", { search = { pinyin = false } })))
    for _, mode in ipairs({ "search", "fuzzy" }) do
      assert.same(literal, positions(state("hao", { search = { mode = mode } })))
    end
    for _, mode in ipairs({ "search", "char", "treesitter", "treesitter_search", "remote" }) do
      local excluded = state("hao", { mode = mode, search = { mode = "exact" } })
      assert.is_false(excluded.pinyin)
      assert.same(literal, positions(excluded))
    end
    local s = state("hao", {
      matcher = function()
        return {}
      end,
    })
    assert.same({}, s.results)
    assert.is_false(s.pinyin)
  end)

  it("refreshes edited characters without mixing up buffers in different windows", function()
    set("好")
    local first_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    extra_win = vim.api.nvim_get_current_win()
    extra_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(extra_win, extra_buf)
    vim.api.nvim_buf_set_lines(extra_buf, 0, -1, false, { "号" })
    vim.api.nvim_set_current_win(first_win)
    local s = state("hao", { search = { multi_window = true } })
    assert.equals(2, #s.results)
    assert.equals(1, #s:get_matcher(extra_win):get())
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { " 浩" })
    s:update()
    assert.equals(2, #s.results)
    assert.same({ { { 1, 1 }, { 1, 1 } } }, positions(s))
    assert.same({ 1, 0 }, s:get_matcher(extra_win):get()[1].pos)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "你" })
    s:update()
    assert.same({}, positions(s))
    assert.equals(1, #s.results)
    assert.equals(extra_win, s.results[1].win)
  end)

  it("preserves search bounds, direction and wrapping", function()
    set("好\nhao\n好")
    local s = state("hao")
    local matcher = s:get_matcher(s.win)
    assert.same({ { { 2, 0 }, { 2, 2 } } }, positions(s, { from = { 2, 0 }, to = { 2, 0 } }))
    assert.same({ 2, 0 }, matcher:find({ pos = { 1, 0 }, wrap = false }).pos)
    assert.same({ 1, 0 }, matcher:find({ pos = { 2, 0 }, forward = false, wrap = false }).pos)
    assert.is_nil(matcher:find({ pos = { 3, 0 }, wrap = false }))
    assert.same({ 1, 0 }, matcher:find({ pos = { 3, 0 }, wrap = true }).pos)
  end)
end)
