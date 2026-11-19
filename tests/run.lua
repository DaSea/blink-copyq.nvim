vim.opt.runtimepath:prepend(vim.fn.getcwd())
local source = require('blink-copyq')
local real_system, real_executable = vim.system, vim.fn.executable
local failures, total = 0, 0
local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), 'expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual))
end
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  vim.system, vim.fn.executable = real_system, real_executable
  if ok then print('PASS ' .. name) else failures = failures + 1; print('FAIL ' .. name .. ': ' .. err) end
end
local function mock()
  local requests = {}
  vim.fn.executable = function() return 1 end
  vim.system = function(argv, opts, cb)
    local request = { argv = argv, opts = opts, callback = cb, kills = 0 }
    requests[#requests + 1] = request
    return { kill = function() request.kills = request.kills + 1 end }
  end
  return requests
end
local function context(line, col) return { line = line, cursor = { 1, col or #line } } end
local function request(src, ctx)
  local state = { calls = 0 }
  state.cancel = src:get_completions(ctx, function(result)
    state.calls = state.calls + 1
    state.result = result
  end)
  return state
end
local function finish(req, texts, result)
  req.callback(result or { code = 0, stdout = vim.json.encode(texts), stderr = '' })
  vim.wait(50, function() return false end, 5)
end

test('T01 replaces trigger query using byte columns and preserves text', function()
  local requests = mock()
  local state = request(source.new(), context('前文 !abc尾', #'前文 !abc'))
  assert(requests[1], 'CopyQ request was not started')
  local text = '  中文\n  body\n'
  finish(requests[1], { text })
  eq(1, state.calls)
  eq({ start = { line = 0, character = #'前文 ' }, ['end'] = { line = 0, character = #'前文 !abc' } }, state.result.items[1].textEdit.range)
  eq(text, state.result.items[1].textEdit.newText)
  eq(1, state.result.items[1].insertTextFormat)
end)

test('T02 literal triggers and whitespace boundaries', function()
  for _, char in ipairs({ '%', ']', '-', '^', '!' }) do
    local requests = mock()
    local src = source.new({ trigger = char, manual_trigger = false })
    eq({ char }, src:get_trigger_characters())
    local state = request(src, context('x' .. char .. 'a' .. char .. 'q'))
    finish(requests[1], { 'query' })
    eq(3, state.result.items[1].textEdit.range.start.character)
    local blocked = request(src, context(char .. 'has space'))
    eq({}, blocked.result.items)
    eq(1, #requests)
  end
end)

test('T03 only explicit manual requests bypass trigger', function()
  local requests = mock()
  local src = source.new()
  local blocked = request(src, context('word'))
  eq({}, blocked.result.items)
  eq(0, #requests)
  for _, trigger in ipairs({ { kind = 'manual' }, { kind = 'keyword', initial_kind = 'manual' } }) do
    local ctx = context('word')
    ctx.trigger = trigger
    local state = request(src, ctx)
    finish(requests[#requests], { 'text' })
    eq(4, state.result.items[1].textEdit.range.start.character)
    eq(4, state.result.items[1].textEdit.range['end'].character)
  end
  local ctx = context('word')
  ctx.trigger = { kind = 'manual' }
  eq({}, request(source.new({ manual_trigger = false }), ctx).result.items)
  eq(2, #requests)
end)

test('T03 special buffers never query CopyQ', function()
  local requests = mock()
  for _, buftype in ipairs({ 'prompt', 'nofile', 'terminal' }) do
    local old = vim.api.nvim_get_current_buf()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    if buftype == 'terminal' then vim.api.nvim_open_term(buf, {}) else vim.bo.buftype = buftype end
    local src = source.new()
    local enabled = src:enabled()
    local state = request(src, context('!'))
    vim.api.nvim_set_current_buf(old)
    vim.api.nvim_buf_delete(buf, { force = true })
    eq(false, enabled)
    eq({}, state.result.items)
  end
  eq(0, #requests)
end)

test('T04 exact deduplication, Unicode labels, plaintext docs, CRLF', function()
  local requests = mock()
  local src = source.new()
  local state = request(src, context('!'))
  local long = string.rep('中😀', 30)
  finish(requests[1], { '', ' \t\r\n', 'hello', 'hello', ' hello ', 'a\r\nb\n', long, '```\n${1:literal}\n```' })
  eq(5, #state.result.items)
  eq('hello', state.result.items[1].insertText)
  eq(' hello ', state.result.items[2].insertText)
  eq('a\r\nb\n', state.result.items[3].insertText)
  eq('a b ', state.result.items[3].label)
  eq(string.rep('中😀', 20) .. '…', state.result.items[4].label)
  for i, item in ipairs(state.result.items) do
    eq(string.format('%08d', i), item.sortText)
    eq(item.textEdit.newText, item.filterText)
    eq({ kind = 'plaintext', value = item.insertText }, item.documentation)
    eq(1, item.insertTextFormat)
  end
  eq(false, state.result.is_incomplete_forward)
  eq(false, state.result.is_incomplete_backward)
end)

test('T05 argv isolates script and tab; limits history rows', function()
  local requests = mock()
  local tab = 'quotes";\\tab\n中文'
  local state = request(source.new({ copyq_path = '/a path/copyq', tab = tab, max_items = 2, timeout_ms = 123 }), context('!'))
  eq({ '/a path/copyq', 'eval', '--', require('blink-copyq.copyq').script, tab, '2' }, requests[1].argv)
  eq(123, requests[1].opts.timeout)
  assert(not requests[1].opts.text, 'text mode would normalize CRLF')
  finish(requests[1], { 'one', 'two', 'three' })
  eq(2, #state.result.items)
end)

test('T06 failures complete once without leaking stderr', function()
  for _, result in ipairs({
    { code = 1, stdout = '["secret"]', stderr = 'secret failure' },
    { code = 124, stdout = '' },
    { code = 0, stdout = '{' },
    { code = 0, stdout = '{}' },
    { code = 0, stdout = '{"x":"y"}' },
    { code = 0, stdout = 'null' },
    { code = 0, stdout = '42' },
    { code = 0, stdout = '["ok",null]' },
    { code = 0, stdout = '["ok",1]' },
    { code = 0, stdout = '[]' },
  }) do
    local requests = mock()
    local state = request(source.new(), context('!'))
    finish(requests[1], nil, result)
    finish(requests[1], { 'late' })
    eq(1, state.calls)
    eq({}, state.result.items)
  end
  mock()
  vim.fn.executable = function() return 0 end
  local state = request(source.new(), context('!'))
  assert(vim.wait(200, function() return state.calls == 1 end))
  eq({}, state.result.items)
  vim.fn.executable = function() return 1 end
  vim.system = function() error('spawn failure') end
  state = request(source.new(), context('!'))
  assert(vim.wait(200, function() return state.calls == 1 end))
  eq({}, state.result.items)
end)

test('T07 cancellation is idempotent and suppresses queued callbacks', function()
  local requests = mock()
  local src = source.new()
  local state = request(src, context('!'))
  state.cancel(); state.cancel()
  eq(1, requests[1].kills)
  finish(requests[1], { 'late' })
  eq(0, state.calls)
  state = request(src, context('!'))
  requests[2].callback({ code = 0, stdout = '["queued"]' })
  state.cancel()
  vim.wait(50, function() return false end, 5)
  eq(0, state.calls)
  eq(0, requests[2].kills)
  state = request(src, context('!'))
  finish(requests[3], { 'done' })
  state.cancel()
  eq(1, state.calls)
  eq(0, requests[3].kills)
end)

test('T08 invalid configuration fails early; kinds register once', function()
  for _, opts in ipairs({
    { trigger = '' }, { trigger = 'ab' }, { trigger = '中' }, { trigger = ' ' },
    { trigger = '\n' }, { manual_trigger = 'yes' }, { kind_name = '' },
    { kind_icon = false }, { copyq_path = '' }, { tab = '' }, { tab = 1 },
    { max_items = 0 }, { max_items = 1.5 }, { max_items = math.huge },
    { timeout_ms = -1 }, { timeout_ms = '100' },
  }) do
    local ok = pcall(source.new, opts)
    eq(false, ok)
  end
  local old_types, old_config = package.loaded['blink.cmp.types'], package.loaded['blink.cmp.config']
  local kinds = { 'Text', Text = 1 }
  local config = { appearance = { kind_icons = {} } }
  package.loaded['blink.cmp.types'] = { CompletionItemKind = kinds }
  package.loaded['blink.cmp.config'] = config
  local a, b = source.new(), source.new()
  package.loaded['blink.cmp.types'], package.loaded['blink.cmp.config'] = old_types, old_config
  eq(2, #kinds)
  eq(2, a.kind)
  eq(a.kind, b.kind)
  eq('󰅍', config.appearance.kind_icons.CopyQ)
end)

test('T09 independent requests and fresh snapshots; main pos API', function()
  local requests = mock()
  local src = source.new()
  local first = request(src, context('!'))
  local second = request(src, { line = '😀!abc', pos = { row = 2, col = #'😀!abc' } })
  finish(requests[2], { 'new' })
  finish(requests[1], { 'old' })
  eq('old', first.result.items[1].insertText)
  eq('new', second.result.items[1].insertText)
  eq({ line = 2, character = #'😀' }, second.result.items[1].textEdit.range.start)
  eq(0, requests[1].kills)
  eq(0, requests[2].kills)
end)

test('T10 real subprocess pipe, failure, timeout and cancellation', function()
  local path = vim.fn.getcwd() .. '/tests/fixtures/copyq'
  local src = source.new({ copyq_path = path })
  local state = request(src, context('!'))
  assert(vim.wait(2000, function() return state.calls == 1 end), 'real subprocess callback timed out')
  eq('  中文\r\nbody\n', state.result.items[1].insertText)
  for _, tab in ipairs({ 'failure', 'slow' }) do
    state = request(source.new({ copyq_path = path, tab = tab, timeout_ms = 50 }), context('!'))
    local ticked = false
    vim.schedule(function() ticked = true end)
    assert(vim.wait(2000, function() return state.calls == 1 end))
    eq(true, ticked)
    eq({}, state.result.items)
  end
  state = request(source.new({ copyq_path = path, tab = 'slow', timeout_ms = 200 }), context('!'))
  state.cancel(); state.cancel()
  vim.wait(300, function() return false end, 5)
  eq(0, state.calls)
end)

if vim.env.COPYQ_SMOKE == '1' then
  test('T11 real CopyQ script with synthetic history and zero clipboard access', function()
    local script = require('blink-copyq.copyq').script
    local prelude = [[
var selected = null;
var tab = function(name) {
  if (arguments.length === 0) return ['first', 'quoted"tab\\name'];
  if (name !== 'first' && name !== 'quoted"tab\\name') throw new Error('Would create tab');
  selected = name;
};
var size = function() { return 4; };
var read = function(mime, row) {
  if (mime !== 'text/plain' || row < 0 || selected === null) throw new Error('Bad read');
  return ['  中文\r\nbody\n', 'quote"slash\\', '', 'last'][row];
};
]]
    for _, tab in ipairs({ '', 'quoted"tab\\name' }) do
      local result = real_system({ 'copyq', 'eval', '--', prelude .. script, tab, '2' }, { timeout = 3000 }):wait()
      eq(0, result.code)
      eq({ '  中文\r\nbody\n', 'quote"slash\\' }, vim.json.decode(result.stdout))
    end
    local missing = real_system({ 'copyq', 'eval', '--', prelude .. script, 'missing', '2' }, { timeout = 3000 }):wait()
    assert(missing.code ~= 0, 'missing tab must fail')
    local empty = real_system({ 'copyq', 'eval', '--', prelude .. 'tab = function() { return []; };' .. script, '', '2' }, { timeout = 3000 }):wait()
    eq(0, empty.code)
    eq({}, vim.json.decode(empty.stdout))
  end)
end

if failures > 0 then vim.cmd('cquit 1') else print(string.format('%d tests passed', total)); vim.cmd('qa!') end
