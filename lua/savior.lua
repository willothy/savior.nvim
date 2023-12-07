local M = {}

local function get_bufnr(buf)
  if type(buf) == "table" then
    buf = buf.bufnr or buf.buf
  end
  return buf or vim.api.nvim_get_current_buf()
end

M.conditions = {}

---@type table<integer, uv_timer_t>
local timers = {}

---@type table<integer, table>
local progress = {}

local function progress_start(bufnr)
  if progress[bufnr] then
    return
  end
  progress[bufnr] = require("fidget").progress.handle.create({
    message = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t"),
    title = "saving",
    lsp_client = {
      name = "savior",
    },
    cancellable = true,
  })
  vim.api.nvim_buf_attach(bufnr, false, {
    on_detach = function()
      if progress[bufnr] then
        progress[bufnr]:cancel()
        progress[bufnr] = nil
      end
    end,
    on_reload = function() end,
  })
end

local function progress_report(bufnr, opts)
  if not progress[bufnr] then
    return
  end
  progress[bufnr]:report(opts)
end

local function progress_finish(bufnr)
  if not progress[bufnr] then
    return
  end
  progress[bufnr]:finish()
  progress[bufnr] = nil
end

local function progress_cancel(bufnr)
  if not progress[bufnr] then
    return
  end
  progress[bufnr]:cancel()
  progress[bufnr] = nil
end

local callbacks = {}

function callbacks.on_save(bufnr)
  progress_start(bufnr)
end

function callbacks.on_save_done(bufnr)
  progress_finish(bufnr)
end

function callbacks.on_immediate(bufnr)
  progress_start(bufnr)
end

function callbacks.on_immediate_done(bufnr)
  progress_finish(bufnr)
end

function callbacks.on_deferred(bufnr)
  progress_start(bufnr)
end

function callbacks.on_deferred_done(bufnr)
  progress_finish(bufnr)
end

function callbacks.on_cancel(bufnr)
  progress_cancel(bufnr)
end

function M.conditions.is_file_buf(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr)
    and vim.bo[bufnr].buftype == ""
    and vim.bo[bufnr].modifiable == true
    and vim.bo[bufnr].readonly == false
end

function M.conditions.is_modified(bufnr)
  return vim.api.nvim_get_option_value("modified", {
    buf = bufnr,
  })
end

function M.conditions.is_listed(bufnr)
  return vim.api.nvim_get_option_value("buflisted", {
    buf = bufnr,
  })
end

function M.conditions.is_named(bufnr)
  return vim.api.nvim_buf_get_name(bufnr) ~= ""
end

function M.conditions.has_no_errors(bufnr)
  return vim.diagnostic.get(
    bufnr,
    { severity = vim.diagnostic.severity.ERROR }
  )[1] == nil
end

function M.conditions.file_exists(bufnr)
  local uv = vim.uv or vim.loop -- support older nvim versions
  return uv.fs_stat(vim.api.nvim_buf_get_name(bufnr)) ~= nil
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
  if timers[fn] ~= nil then
    t = timers[fn]
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
end

function M.callback(id, bufnr)
  local user_cb, cb = M.config.callbacks[id], callbacks[id]
  if user_cb then
    user_cb(bufnr)
  end
  if cb then
    cb(bufnr)
  end
end

function M.should_save(bufnr)
  for _, cond in ipairs(M.config.conditions) do
    if cond(bufnr) == false then
      return false
    end
  end
  return vim.api.nvim_get_option_value("modified", {
    buf = bufnr,
  })
end

function M.immediate(bufnr)
  vim.schedule(function()
    bufnr = get_bufnr(bufnr)
    M.cancel(bufnr)
    if M.should_save(bufnr) then
      M.callback("on_immediate", bufnr)
      M.save(bufnr)
      M.callback("on_immediate_done", bufnr)
    end
  end)
end

function M.deferred(bufnr)
  bufnr = get_bufnr(bufnr)
  M.cancel(bufnr)
  if M.should_save(bufnr) == true then
    timers[bufnr] = vim.defer_fn(function()
      M.save(bufnr)
      M.callback("on_deferred_done", bufnr)
    end, M.config.defer_ms or 1000)
    M.callback("on_deferred", bufnr)
    progress_start(bufnr)
  end
end

function M.cancel(bufnr)
  bufnr = get_bufnr(bufnr)
  if timers[bufnr] ~= nil then
    local t = timers[bufnr]
    if not t:is_closing() then
      t:close()
    end
    timers[bufnr] = nil
    M.callback("on_cancel", bufnr)
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

  M.enable()
end

function M.enable()
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

  local save_interval = M.config.interval_ms or 30000

  local interval
  if timers["interval"] then
    interval = timers["interval"]
  else
    interval = vim.loop.new_timer()
    timers["interval"] = interval
  end
  interval:start(
    save_interval,
    save_interval,
    vim.schedule_wrap(function()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if M.should_save(buf) then
          M.deferred(buf)
        end
      end
    end)
  )

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
  for i, timer in pairs(timers) do
    timer:stop()
    timer:close()
    timers[i] = nil
  end

  if timers["interval"] then
    timers["interval"]:stop()
    timers["interval"]:close()
    timers["interval"] = nil
  end
end

function M.shutdown()
  M.disable()

  -- free the timers on shutdown to avoid memory leak
  for k, timer in pairs(timers) do
    if timer:is_active() then
      timer:stop()
    end
    timer:close()
    rawset(timers, k, nil)
  end
end

return {
  setup = M.setup,
  disable = M.disable,
  enable = M.enable,
  shutdown = M.shutdown,
  conditions = M.conditions,
}
