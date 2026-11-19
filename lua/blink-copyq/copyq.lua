local M = {}

-- Keep user data out of the script; CopyQ's -- disables CLI escape decoding.
M.script = [[
var requested = str(arguments[1]);
var limit = Number(str(arguments[2]));
var names = tab();
var target = requested || names[0];
if (target === undefined) {
    print('[]');
} else {
    if (names.indexOf(target) === -1) throw new Error('Unknown CopyQ tab');
    tab(target);
    var result = [];
    var n = Math.min(size(), limit);
    for (var i = 0; i < n; ++i) result.push(str(read('text/plain', i)));
    print(JSON.stringify(result));
}
]]

function M.read(opts, callback)
  local cancelled, delivered, exited = false, false, false
  local process
  local function deliver(texts)
    vim.schedule(function()
      if cancelled or delivered then return end
      delivered = true
      callback(texts)
    end)
  end
  local function complete(result)
    exited = true
    local texts = {}
    if result.code == 0 then
      local ok, decoded = pcall(vim.json.decode, result.stdout or '')
      -- Reject objects, including {}, even on versions decoding it as an empty table.
      if ok and (result.stdout or ''):match('^%s*%[') and type(decoded) == 'table' and vim.islist(decoded) then
        local valid = true
        for _, text in ipairs(decoded) do
          if type(text) ~= 'string' then valid = false; break end
        end
        if valid then texts = decoded end
      end
    end
    deliver(texts)
  end
  if vim.fn.executable(opts.copyq_path) ~= 1 then
    deliver({})
  else
    local ok, handle = pcall(vim.system,
      { opts.copyq_path, 'eval', '--', M.script, opts.tab or '', tostring(opts.max_items) },
      { timeout = opts.timeout_ms }, complete)
    if ok then process = handle else deliver({}) end
  end
  return function()
    if cancelled or delivered then return end
    cancelled = true
    if process and not exited then pcall(process.kill, process, 15) end
  end
end

return M
