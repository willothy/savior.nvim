local M = {}

---@type uv_timer_t[]
M.timers = {}

M.progress = {}

M.conditions = {}

function M.conditions.is_file_buf(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr)
    and vim.bo[bufnr].buftype == ""
    and vim.bo[bufnr].modifiable == true
    and vim.bo[bufnr].readonly == false
end

function M.conditions.is_modified(bufnr)
  return vim.bo[bufnr].modified
end

function M.conditions.is_listed(bufnr)
  return vim.bo[bufnr].buflisted
end

function M.conditions.is_named(bufnr)
  return vim.api.nvim_buf_get_name(bufnr) ~= ""
end

function M.conditions.has_no_errors(bufnr)
  return vim.diagnostic.get(bufnr, { severity = 1 })[1] == nil
end

function M.conditions.file_exists(bufnr)
  return vim.uv.fs_stat(vim.api.nvim_buf_get_name(bufnr)) ~= nil
end

function M.conditions.not_of_filetype(filetypes)
  if type(filetypes) ~= "table" then
    filetypes = { filetypes }
  end
  vim.tbl_add_reverse_lookup(filetypes)
  return function(bufnr)
    local ft = vim.bo[bufnr].filetype
    return filetypes[ft] == nil
  end
end

function M.throttle(fn, timeout)
  -- reuse an old timer if we have one
  local t
  if M.timers[fn] ~= nil then
    t = M.timers[fn]
    if not t:is_closing() then
      t:stop()
    end
  else
    t = vim.loop.new_timer()
  end
  local running = false
  return vim.schedule_wrap(function(...)
    if not running then
      fn(...)
      running = true
      t:start(timeout, 0, function()
        running = false
        t:stop()
      end)
    end
  end)
end

function M.save(bufnr)
  if M.should_save(bufnr) == false or vim.api.nvim_get_mode().mode == "i" then
    M.cancel(bufnr)
    return
  end

  M.callback("on_save", bufnr)

  vim.api.nvim_buf_call(bufnr, function()
    vim.api.nvim_exec2("silent! noautocmd write!", {})
  end)
  M.callback("on_save_done", bufnr)
  M.progress_stop("done")
end

function M.callback(id, bufnr)
  local f = M.config.callbacks[id]
  if f then
    return f(bufnr)
  end
end

function M.progress_start(title, message)
  M.send_progress({
    kind = "begin",
    title = title,
    message = message,
  })
end

function M.progress_report(message)
  M.send_progress({
    kind = "report",
    message = message,
  })
end

function M.progress_stop(title, message)
  M.send_progress({
    kind = "end",
    title = title,
    message = message,
  })
end

function M.should_save(bufnr)
  for _, cond in ipairs(M.config.conditions) do
    if cond(bufnr) == false then
      return false
    end
  end
  return vim.api.nvim_buf_get_option(bufnr, "modified") == true
end

function M.immediate(bufnr)
  vim.schedule(function()
    if type(bufnr) ~= "number" then
      bufnr = vim.api.nvim_get_current_buf()
    end
    M.cancel(bufnr)
    if M.should_save(bufnr) then
      M.callback("on_immediate", bufnr)
      M.save(bufnr)
      M.callback("on_immediate_done", bufnr)
    end
  end)
end

function M.deferred(bufnr)
  if type(bufnr) ~= "number" then
    bufnr = vim.api.nvim_get_current_buf()
  end
  M.cancel(bufnr)
  if M.should_save(bufnr) == true then
    if not M.progress[bufnr] then
      M.progress_start("saving")
      M.progress[bufnr] = true
    end
    M.timers[bufnr] = vim.defer_fn(function()
      M.save(bufnr)
      M.callback("on_deferred_done", bufnr)
    end, M.config.defer_ms or 1000)
    M.callback("on_deferred", bufnr)
  end
end

function M.cancel(bufnr)
  if type(bufnr) ~= "number" then
    if type(bufnr) == "table" then
      bufnr = bufnr.bufnr or bufnr.buf
    else
      bufnr = vim.api.nvim_get_current_buf()
    end
  end
  if M.timers[bufnr] ~= nil then
    local t = M.timers[bufnr]
    if not t:is_closing() then
      t:close()
    end
    M.timers[bufnr] = nil
    M.callback("on_cancel", bufnr)
  end
  if M.progress[bufnr] then
    M.progress_stop("cancelled")
    M.progress[bufnr] = nil
  end
end

function M.send_progress(data)
  if M.config.fancy_status then
    local handler = vim.lsp.handlers["$/progress"]
    if handler then
      handler(nil, {
        token = M.client,
        value = data,
      }, { client_id = M.client })
    end
  end
end

function M.notify(msg)
  if M.config.fancy_status then
    local handler = vim.lsp.handlers["$/progress"]
    if handler then
      handler(nil, {
        token = M.client,
        value = {
          kind = "message",
          title = msg,
        },
      }, { client_id = M.client })
    end
    return function(done_msg)
      handler(nil, {
        token = M.client,
        value = {
          kind = "end",
          title = done_msg or msg,
        },
      }, { client_id = M.client })
    end
  end
end

function M.rename_client(name)
  local client = vim.lsp.get_client_by_id(M.client)
  if client then
    client.name = name
  end
end

---@class AutoSave.Options
---@field conditions (fun(bufnr: buffer): boolean)[]
---@field events { immediate: string[], deferred: string[], cancel: string[] }
---@field callbacks table<string, fun(bufnr: buffer)>
---@field fancy_status boolean
---@field throttle_ms number
---@field defer_ms number
---@field interval_ms number

---@param opts AutoSave.Options
function M.setup(opts)
  opts = opts or {}

  opts = vim.tbl_deep_extend("keep", opts, {
    fancy_status = true,
    events = {
      immediate = {
        "FocusLost",
        "BufLeave",
      },
      deferred = {
        "InsertLeave",
        "TextChanged",
      },
      cancel = {
        "InsertEnter",
        "BufWritePost",
        "TextChanged",
      },
    },
    callbacks = {},
    conditions = {
      M.conditions.is_file_buf,
      M.conditions.not_of_filetype({
        "gitcommit",
        "gitrebase",
      }),
      M.conditions.is_named,
      M.conditions.file_exists,
      M.conditions.has_no_errors,
    },
  })

  vim.validate({
    ["fancy_status"] = { opts.fancy_status, "boolean", true },
    ["events.immediate"] = {
      opts.events.immediate,
      { "table", "string" },
      true,
    },
    ["events.deferred"] = { opts.events.deferred, { "table", "string" } },
    ["events.cancel"] = { opts.events.cancel, { "table", "string" } },
    ["callbacks"] = { opts.callbacks, "table" },
    ["callbacks.on_immediate"] = {
      opts.callbacks.on_immediate,
      "function",
      true,
    },
    ["callbacks.on_immediate_done"] = {
      opts.callbacks.on_immediate_done,
      "function",
      true,
    },
    ["callbacks.on_deferred"] = {
      opts.callbacks.on_deferred,
      "function",
      true,
    },
    ["callbacks.on_deferred_done"] = {
      opts.callbacks.on_deferred_done,
      "function",
      true,
    },
    ["callbacks.on_cancel"] = { opts.callbacks.on_cancel, "function", true },
    ["callbacks.on_save"] = { opts.callbacks.on_save, "function", true },
    ["callbacks.on_save_done"] = {
      opts.callbacks.on_save_done,
      "function",
      true,
    },
    ["conditions"] = {
      opts.conditions,
      function(c)
        if type(c) ~= "table" then
          return false, ("expected table, found %s"):format(type(c))
        end

        for _, cond in ipairs(c) do
          if type(cond) ~= "function" then
            return false, ("invalid callback: %s"):format(cond)
          end
        end
        return true
      end,
      "table",
    },
  })

  M.config = opts

  if M.config.fancy_status then
    M.start_client()
  end

  M.send_progress({
    kind = "begin",
    title = "initializing",
  })

  M.enable(true)
end

function M.start_client()
  if M.client then
    return
  end
  M.client = vim.lsp.start({
    name = "savior",
    root_dir = vim.fn.getcwd(),
    -- capabilities = vim.lsp.protocol.make_client_capabilities(),
    settings = {},
    cmd = function(dispatchers)
      -- vim.print("dispatchers: ", dispatchers)
      local stopped = false
      return {
        request = function(m, params, cb)
          vim.print("request: " .. m)
          if m == "initialize" then
            cb(nil, {
              serverInfo = {
                name = "savior",
              },
              ---@type lsp.ServerCapabilities
              capabilities = {
                textDocumentSync = {
                  openClose = true,
                  change = 2,
                },
              },
            })
          end
        end,
        notify = function(m, params)
          vim.print("notify: " .. m)
          if m == "textDocument/didChange" then
            M.i = (M.i or 0) + 1
            vim.print(M.i)
            -- M.deferred(bufnr)
          end
        end,
        is_closing = function()
          return stopped
        end,
        terminate = function()
          stopped = true
          local f = M.notify("stopping")
          vim.schedule(function()
            f("stopped")
          end)
        end,
      }
    end,
    filetypes = {},
    before_init = function()
      vim.print("before init")
    end,
    on_init = function()
      vim.print("init")
    end,
    on_attach = function(client, bufnr)
      vim.print("attached: " .. bufnr)
    end,
  }, {
    bufnr = 0,
    reuse_client = function()
      return true
    end,
  })

  vim.lsp.buf_attach_client(0, M.client)
end

function M.stop_client()
  if not M.client then
    return
  end
  vim.lsp.stop_client(M.client.id)
  M.client = nil
end

function M.enable(init)
  if not M.client then
    M.start_client()
  end
  if not init then
    M.send_progress({
      kind = "begin",
      title = "setting up",
    })
  end

  if M.augroup then
    vim.api.nvim_del_augroup_by_id(M.augroup)
  end
  M.augroup = vim.api.nvim_create_augroup("savior", { clear = true })
  vim.api.nvim_create_autocmd(M.config.events.immediate, {
    group = M.augroup,
    callback = M.throttle(M.immediate, M.config.throttle_ms or 3000),
  })

  vim.api.nvim_create_autocmd(M.config.events.deferred, {
    group = M.augroup,
    callback = M.throttle(M.deferred, M.config.throttle_ms or 3000),
  })

  vim.api.nvim_create_autocmd(M.config.events.cancel, {
    group = M.augroup,
    callback = M.cancel,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = M.augroup,
    callback = function(ev)
      M.cancel(ev.buf)
      M.progress[ev.buf] = nil
      if M.timers[ev.buf] then
        M.timers[ev.buf]:close()
        M.timers[ev.buf] = nil
      end
    end,
  })

  local save_interval = M.config.interval_ms or 30000

  local interval
  if M.timers["interval"] then
    interval = M.timers["interval"]
  else
    interval = vim.loop.new_timer()
    M.timers["interval"] = interval
  end
  interval:start(
    save_interval,
    save_interval,
    vim.schedule_wrap(function()
      vim.iter(vim.api.nvim_list_bufs()):filter(M.should_save):each(M.deferred)
    end)
  )

  M.send_progress({
    kind = "end",
    title = "initialized",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  if M.should_save(bufnr) then
    M.deferred(bufnr)
  end
end

function M.disable()
  -- clear the autocmds
  vim.api.nvim_del_augroup_by_id(M.augroup)
  M.augroup = nil

  -- cancel any remaining deferred saves
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    M.cancel(bufnr)
  end

  -- stop any autocmd-related timers
  -- but we don't need to free these, they can be reused
  -- since the same functions are used for the autocmds
  for i, timer in pairs(M.timers) do
    timer:stop()
    timer:close()
    M.timers[i] = nil
  end

  if M.timers["interval"] then
    M.timers["interval"]:stop()
    M.timers["interval"]:close()
    M.timers["interval"] = nil
  end
end

function M.shutdown()
  M.disable()
  M.stop_client()

  -- free the timers on shutdown to avoid memory leak
  for k, timer in pairs(M.timers) do
    if timer:is_active() then
      timer:stop()
    end
    timer:close()
    rawset(M.timers, k, nil)
  end
end

return {
  setup = M.setup,
  disable = M.disable,
  enable = M.enable,
  shutdown = M.shutdown,
  conditions = M.conditions,
  utils = {
    notify = M.notify,
    progress = {
      start = M.progress_start,
      stop = M.progress_stop,
      report = M.progress_report,
    },
    rename = M.rename_client,
  },
}
