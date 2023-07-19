local M = {}

---@type uv_timer_t[]
M.timers = setmetatable({}, {
	__newindex = function()
		error("use M.new_timer")
	end,
	__metatable = 0,
})

function M.timer(k)
	return rawget(M.timers, k)
end

---@return uv_timer_t
function M.new_timer(k, deferred)
	if M.timer(k) then
		return M.timer(k)
	end
	local t = deferred or vim.loop.new_timer()
	rawset(M.timers, k, t)
	return t
end

---@param fn fun(t: uv_timer_t): any
---@param alt fun(): any
function M.if_timer(k, fn, alt)
	local t = M.timer(k)
	if t then
		return fn(t)
	elseif alt then
		return alt()
	end
end

function M.throttle(fn, timeout)
	-- reuse an old timer if we have one
	local t = M.if_timer(fn, function(maybe_t)
		if maybe_t:is_active() then
			maybe_t:stop()
		end
		return maybe_t
	end, function()
		return M.new_timer(fn)
	end)
	local running = false
	return vim.schedule_wrap(function(...)
		if not running then
			fn(...)
			running = true
			t:start(timeout, 0, function()
				running = false
			end)
		end
	end)
end

function M.save(bufnr)
	M.progress_start("saving")
	if M.should_save(bufnr) == false then
		M.cancel(bufnr)
		M.progress_stop()
		return
	end

	M.callback("on_save", bufnr)
	vim.api.nvim_buf_call(bufnr, function()
		vim.api.nvim_exec2("silent! write", {})
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

function M.progress_start(title)
	M.send_progress({
		kind = "begin",
		title = title,
	})
end

function M.progress_stop(message)
	M.send_progress({
		kind = "end",
		title = message,
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
			M.progress_start("saving")
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
		vim.defer_fn(function()
			M.save(bufnr)
			M.callback("on_deferred_done", bufnr)
		end, M.config.defer_ms or 2000)
		M.callback("on_deferred", bufnr)
	end
end

function M.cancel(bufnr)
	vim.schedule(function()
		if type(bufnr) ~= "number" then
			if type(bufnr) == "table" then
				bufnr = bufnr.bufnr or bufnr.buf
			else
				bufnr = vim.api.nvim_get_current_buf()
			end
		end
		M.if_timer(bufnr, function(t)
			t:stop()
			t:close()
			rawset(M.timers, bufnr, nil)
			M.callback("on_cancel", bufnr)
		end)
	end)
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
---@field condition (fun(bufnr: buffer, winnr: window): boolean)[]
---@field update { immediate: string[], deferred: string[], cancel: string[] }
---@field callbacks table<string, fun(bufnr: buffer)>

---@param opts AutoSave.Options
function M.setup(opts)
	opts = opts or {}

	opts = vim.tbl_deep_extend("keep", opts, {
		fancy_status = true,
		disable_format = true,
		events = {
			immediate = {
				"FocusLost",
				"BufLeave",
			},
			deferred = {
				"InsertLeave",
				"TextChanged",
			},
			cancel = { "InsertEnter", "BufWritePost" },
		},
		callbacks = {},
		conditions = {
			function(bufnr)
				return vim.api.nvim_buf_is_valid(bufnr)
					and vim.bo[bufnr].buftype == ""
					and vim.bo[bufnr].buflisted == true
					and vim.bo[bufnr].modifiable == true
					and vim.bo[bufnr].readonly == false
			end,
			function(bufnr)
				local ft = vim.bo[bufnr].filetype
				local ignore = {
					help = true,
					qf = true,
					gitcommit = true,
					gitrebase = true,
				}
				return ignore[ft] == nil
			end,
			function(bufnr)
				return vim.api.nvim_buf_get_name(bufnr) ~= ""
			end,
			function(bufnr)
				return vim.diagnostic.get(bufnr, { severity = 1 })[1] == nil
			end,
		},
	})

	vim.validate({
		["fancy_status"] = { opts.fancy_status, "boolean", true },
		["disable_format"] = { opts.disable_format, "boolean", true },
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
		["callbacks.on_deferred"] = { opts.callbacks.on_deferred, "function", true },
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

	if M.config.disable_format then
		local prev_save
		if M.config.callbacks.on_save then
			prev_save = M.config.callbacks.on_save
		end
		M.config.callbacks.on_save = function(bufnr)
			require("lsp-format").disable({ args = "" })
			if prev_save then
				prev_save(bufnr)
			end
		end
		local prev_save_done
		if M.on_save_done then
			prev_save_done = M.config.callbacks.on_save_done
		end
		M.config.callbacks.on_save_done = function(bufnr)
			require("lsp-format").enable({ args = "" })
			if prev_save_done then
				prev_save_done(bufnr)
			end
		end
	end
	M.enable(true)
end

function M.start_client()
	if M.client then
		return
	end
	M.client = vim.lsp.start({
		name = "savior",
		root_dir = vim.fn.getcwd(),
		cmd = function()
			return {
				request = function() end,
				stop = function()
					local f = M.notify("stopping")
					vim.schedule(function()
						f("stopped")
					end)
				end,
			}
		end,
		filetypes = {},
	})
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
		callback = M.throttle(M.immediate, M.config.throttle_ms or 1000),
	})

	vim.api.nvim_create_autocmd(M.config.events.deferred, {
		group = M.augroup,
		callback = M.throttle(M.deferred, M.config.throttle_ms or 1000),
	})

	vim.api.nvim_create_autocmd(M.config.events.cancel, {
		group = M.augroup,
		callback = M.cancel,
	})

	local save_interval = M.config.interval_ms or 30000
	local t = M.new_timer("interval")
	t:start(
		save_interval,
		save_interval,
		vim.schedule_wrap(function()
			vim.iter(vim.api.nvim_list_bufs()):filter(M.should_save):each(M.deferred)
		end)
	)

	M.send_progress({
		kind = "end",
		title = "ready",
		message = "ready",
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
	for _, timer in pairs(M.timers) do
		timer:stop()
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

return setmetatable({
	setup = M.setup,
	disable = M.disable,
	enable = M.enable,
	shutdown = M.shutdown,
	utils = {
		notify = M.notify,
		rename = M.rename_client,
	},
}, {
	-- give read-only access to the internals to those who want it
	__index = function(_, k)
		if k == "timers" then
			return setmetatable({}, { __metatable = M.timers })
		end
		if M[k] then
			return M[k]
		end
	end,
	-- but seal them so they're hidden from `vim.print` and similar
	__metatable = {},
	-- don't allow new fields to be added
	__newindex = function()
		error("savior: cannot modify module")
	end,
})
