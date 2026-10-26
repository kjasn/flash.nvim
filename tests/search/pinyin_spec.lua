local State = require("flash.state")
local Util = require("flash.util")
local assert = require("luassert")

describe("pinyin search", function()
  local states, buf, previous_buf, ignorecase, smartcase, extra_win, extra_buf

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
