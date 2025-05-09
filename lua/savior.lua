local M = {}

---@alias Savior.Condition fun(bufnr: integer): boolean
---@alias Savior.Callback fun(bufnr: integer)

---@class Savior.Callbacks
---Run when a save of any kind is started
---@field on_save? fun(bufnr: integer)
---Run when a save of any kind is completed
---@field on_save_done? fun(bufnr: integer)
---Run when an immediate save is started
---@field on_immediate? fun(bufnr: integer)
---Run when an immediate save is completed
---@field on_immediate_done? fun(bufnr: integer)
---Run when the timeout for a deferred save is started
---@field on_deferred? fun(bufnr: integer)
---Run when a deferred save is completed
---@field on_deferred_done? fun(bufnr: integer)
---Run when a save is cancelled
---@field on_cancel? fun(bufnr: integer)

---@class Savior.Events
---Events that will trigger an immediate save
---@field immediate string[]
---Events that will schedule a save
---@field deferred string[]
---Events that will cancel a scheduled save
---@field cancel string[]

---@class Savior.Options
---Events that trigger saving
---@field events? Savior.Events
---Condition stack determining when it's safe to save
---@field conditions? Savior.Condition[]
---Callback to execute for specific events
---@field callbacks? Savior.Callbacks
---Throttle time for all save types
---@field throttle_ms? number
---Wait time for deferred saving
---@field defer_ms? number
---Auto-save interval
---@field interval_ms? number
---Whether to use fidget.nvim to provide notifications.
---@field notify? boolean

---@type table<integer, uv_timer_t>
local timers = {}

---@type table<integer, table>
local progress = {}

---@param bufnr integer
local function progress_start(bufnr)
  if progress[bufnr] or not M.config.notify then
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

---@param bufnr integer
local function progress_finish(bufnr)
  if progress[bufnr] == nil or not M.config.notify then
    return
  end
  progress[bufnr]:report({
    title = "done",
  })
  progress[bufnr]:finish()
  progress[bufnr] = nil
end

---@param bufnr integer
local function progress_cancel(bufnr)
  if progress[bufnr] == nil or not M.config.notify then
    return
  end
  progress[bufnr]:report({
    title = "cancelled",
  })
  progress[bufnr]:cancel()
  progress[bufnr] = nil
end

---@type Savior.Callbacks
local callbacks = {
  on_save = function(bufnr)
    progress_start(bufnr)
  end,
  on_save_done = function(bufnr)
    progress_finish(bufnr)
  end,
  on_immediate = function(bufnr)
    progress_start(bufnr)
  end,
  on_immediate_done = function(bufnr)
    progress_finish(bufnr)
  end,
  on_deferred = function(bufnr)
    progress_start(bufnr)
  end,
  on_deferred_done = function(bufnr)
    progress_finish(bufnr)
  end,
  on_cancel = function(bufnr)
    progress_cancel(bufnr)
  end,
}

---@type table<string, Savior.Condition | fun(...:any): Savior.Condition>
local conditions = {}

---@type Savior.Condition
function conditions.is_file_buf(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr)
    and vim.bo[bufnr].buftype == ""
    and vim.bo[bufnr].modifiable == true
    and vim.bo[bufnr].readonly == false
end

---@type Savior.Condition
function conditions.is_modified(bufnr)
  return vim.api.nvim_get_option_value("modified", {
    buf = bufnr,
  })
end

---@type Savior.Condition
function conditions.is_listed(bufnr)
  return vim.api.nvim_get_option_value("buflisted", {
    buf = bufnr,
  })
end

---@type Savior.Condition
function conditions.is_named(bufnr)
  return vim.api.nvim_buf_get_name(bufnr) ~= ""
end

---@type Savior.Condition
function conditions.has_no_errors(bufnr)
  return vim.diagnostic.get(
    bufnr,
    { severity = vim.diagnostic.severity.ERROR }
  )[1] == nil
end

---@type Savior.Condition
function conditions.file_exists(bufnr)
  local uv = vim.uv or vim.loop -- support older nvim versions
  return uv.fs_stat(vim.api.nvim_buf_get_name(bufnr)) ~= nil
end

---@param filetypes string | string[]
---@return Savior.Condition
function conditions.not_of_filetype(filetypes)
  if type(filetypes) ~= "table" then
    filetypes = { filetypes }
  end
  local ft_set = {}
  for _, ft in ipairs(filetypes) do
    ft_set[ft] = true
  end
  return function(bufnr)
    return not ft_set[vim.bo[bufnr].filetype]
  end
end

---@param fn fun(...:any): ...:any
---@param timeout integer
function M.throttle(fn, timeout)
  -- reuse an old timer if we have one
  local t
  if timers[fn] ~= nil then
    t = timers[fn]
    if not t:is_closing() then
      t:stop()
    end
  else
    t = vim.loop.new_timer() --[[@as uv_timer_t]]
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

---@param bufnr integer
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

---@param event string
---@param bufnr integer
function M.callback(event, bufnr)
  local user_cb, cb = M.config.callbacks[event], callbacks[event]
  if user_cb then
    user_cb(bufnr)
  end
  if cb then
    cb(bufnr)
  end
end

---@param bufnr integer
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

---@param bufnr integer?
function M.immediate(bufnr)
  vim.schedule(function()
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    M.cancel(bufnr)
    if M.should_save(bufnr) then
      M.callback("on_immediate", bufnr)
      M.save(bufnr)
      M.callback("on_immediate_done", bufnr)
    end
  end)
end

---@param bufnr integer?
function M.deferred(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  M.cancel(bufnr)
  if M.should_save(bufnr) == true then
    timers[bufnr] = vim.defer_fn(function()
      M.save(bufnr)
      M.callback("on_deferred_done", bufnr)
    end, M.config.defer_ms)
    M.callback("on_deferred", bufnr)
    progress_start(bufnr)
  end
end

---@param bufnr integer?
function M.cancel(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if timers[bufnr] ~= nil then
    local t = timers[bufnr]
    if not t:is_closing() then
      t:close()
    end
    timers[bufnr] = nil
    M.callback("on_cancel", bufnr)
  end
end

---@param opts Savior.Options
function M.setup(opts)
  opts = opts or {}

  opts = vim.tbl_deep_extend("keep", opts, {
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
      conditions.is_file_buf,
      conditions.not_of_filetype({
        "gitcommit",
        "gitrebase",
      }),
      conditions.is_named,
      conditions.file_exists,
      conditions.has_no_errors,
    },
    throttle_ms = 3000,
    interval_ms = 30000,
    defer_ms = 1000,
    notify = true,
  })

  local spec = {
    ["notify"] = { opts.notify, "boolean", true, "notify should be a boolean" },
    ["throttle_ms"] = { opts.throttle_ms, "number", true },
    ["interval_ms"] = { opts.interval_ms, "number", true },
    ["defer_ms"] = { opts.defer_ms, "number", true },
    ["events.immediate"] = { opts.events.immediate, { "table", "string" } },
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
  }

  for k, v in pairs(spec) do
    vim.validate(k, unpack(v))
  end

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
    callback = M.throttle(function(ev)
      M.immediate(ev.buf)
    end, M.config.throttle_ms),
  })

  vim.api.nvim_create_autocmd(M.config.events.deferred, {
    group = M.augroup,
    callback = M.throttle(function(ev)
      M.deferred(ev.buf)
    end, M.config.throttle_ms),
  })

  vim.api.nvim_create_autocmd(M.config.events.cancel, {
    group = M.augroup,
    callback = function(ev)
      M.cancel(ev.buf)
    end,
  })

  local save_interval = M.config.interval_ms --[[@as number]]

  if save_interval > 0 then
    local interval
    if timers["interval"] then
      interval = timers["interval"]
    else
      interval = vim.loop.new_timer()
      timers["interval"] = interval
    end
    if interval then
      interval:start(
        save_interval,
        save_interval,
        vim.schedule_wrap(function()
          for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            M.deferred(buf)
          end
        end)
      )
    else
      vim.notify(
        "Failed to start auto-save interval timer",
        vim.log.levels.WARN,
        {
          title = "savior",
        }
      )
    end
  end

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
  for i, timer in pairs(timers) do
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    timers[i] = nil
  end

  if timers["interval"] then
    if not timers["interval"]:is_closing() then
      timers["interval"]:stop()
      timers["interval"]:close()
    end
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
  conditions = conditions,
}
