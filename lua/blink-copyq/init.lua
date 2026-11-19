local Source = {}
Source.__index = Source

local defaults = {
  trigger = '!', manual_trigger = true, kind_name = 'CopyQ', kind_icon = '󰅍',
  copyq_path = 'copyq', max_items = 100, timeout_ms = 1000,
}

local function validate(opts)
  assert(type(opts.trigger) == 'string' and #opts.trigger == 1
    and opts.trigger:byte() >= 33 and opts.trigger:byte() <= 126,
    'blink-copyq: trigger must be one non-whitespace ASCII character')
  assert(type(opts.manual_trigger) == 'boolean', 'blink-copyq: manual_trigger must be boolean')
  for _, key in ipairs({ 'kind_name', 'kind_icon', 'copyq_path' }) do
    assert(type(opts[key]) == 'string' and opts[key] ~= '', 'blink-copyq: ' .. key .. ' must be a non-empty string')
  end
  assert(opts.tab == nil or (type(opts.tab) == 'string' and opts.tab ~= ''),
    'blink-copyq: tab must be nil or a non-empty string')
  for _, key in ipairs({ 'max_items', 'timeout_ms' }) do
    local n = opts[key]
    assert(type(n) == 'number' and n > 0 and n < math.huge and n == math.floor(n),
      'blink-copyq: ' .. key .. ' must be a positive integer')
  end
end

function Source.new(opts)
  local config = vim.tbl_extend('force', defaults, opts or {})
  validate(config)
  local kind = 1 -- Text, when blink types are not yet available.
  local ok, types = pcall(require, 'blink.cmp.types')
  if ok then
    local kinds = types.CompletionItemKind
    if not kinds[config.kind_name] then
      table.insert(kinds, config.kind_name)
      kinds[config.kind_name] = #kinds
    end
    kind = kinds[config.kind_name]
  end
  local ok_config, blink_config = pcall(require, 'blink.cmp.config')
  if ok_config and blink_config.appearance and blink_config.appearance.kind_icons then
    blink_config.appearance.kind_icons[config.kind_name] = config.kind_icon
  end
  return setmetatable({ opts = config, kind = kind }, Source)
end

function Source:get_trigger_characters()
  return { self.opts.trigger }
end

function Source:enabled()
  local buftype = vim.bo.buftype
  return buftype ~= 'prompt' and buftype ~= 'terminal' and buftype ~= 'nofile'
end

local function trigger_start(before, trigger)
  -- Plain comparisons also support Lua pattern metacharacters such as ] and %.
  for i = #before, 1, -1 do
    local char = before:sub(i, i)
    if char == trigger then return i - 1 end
    if char:match('%s') then return nil end
  end
end

local function response(items)
  return { items = items, is_incomplete_forward = false, is_incomplete_backward = false }
end

function Source:get_completions(ctx, callback)
  local row = ctx.pos and ctx.pos.row or ctx.cursor[1] - 1
  local col = ctx.pos and ctx.pos.col or ctx.cursor[2]
  local start = trigger_start((ctx.line or ''):sub(1, col), self.opts.trigger)
  local trigger = ctx.trigger or {}
  local manual = self.opts.manual_trigger and (trigger.kind == 'manual' or trigger.initial_kind == 'manual')
  if not self:enabled() or (start == nil and not manual) then
    callback(response({}))
    return function() end
  end
  local range = {
    start = { line = row, character = start or col },
    ['end'] = { line = row, character = col },
  }
  return require('blink-copyq.copyq').read(self.opts, function(texts)
    local items, seen = {}, {}
    for index, text in ipairs(texts) do
      if index > self.opts.max_items then break end
      if text:find('%S') and not seen[text] then
        seen[text] = true
        local label = text:gsub('%s+', ' ')
        if vim.fn.strchars(label) > 40 then label = vim.fn.strcharpart(label, 0, 40) .. '…' end
        items[#items + 1] = {
          label = label,
          sortText = string.format('%08d', #items + 1),
          filterText = text,
          insertText = text,
          insertTextFormat = 1,
          documentation = { kind = 'plaintext', value = text },
          kind = self.kind,
          textEdit = { newText = text, range = range },
        }
      end
    end
    callback(response(items))
  end)
end

return Source
