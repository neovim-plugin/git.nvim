vim.loop = vim.uv or vim.loop

local U = {}

function U.validate_buf_id(x)
	if x == nil or x == 0 then
		return vim.api.nvim_get_current_buf()
	end
	if not (type(x) == "number" and vim.api.nvim_buf_is_valid(x)) then
		U.error("`buf_id` should be `nil` or valid buffer id.")
	end
	return x
end

function U.normalize_split_opt(x, x_name)
	if x == "auto" then
		-- Show in same tabpage if only neovimgit buffers visible. Otherwise in new.
		for _, win_id in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			local win_buf_id = vim.api.nvim_win_get_buf(win_id)
			local win_buf_name = vim.api.nvim_buf_get_name(win_buf_id)
			local is_neovimgit_win = win_buf_name:find("^neovimgit://%d+/") ~= nil
			local is_normal_win = vim.api.nvim_win_get_config(win_id).relative == ""
			if not is_neovimgit_win and is_normal_win then
				return "tab"
			end
		end
		return "vertical"
	end
	if x == "horizontal" or x == "vertical" or x == "tab" then
		return x
	end
	U.error("`" .. x_name .. '` should be one of "auto", "horizontal", "vertical", "tab"')
end

function U.normalize_range_lines(line_start, line_end)
	if line_start == nil and line_end == nil then
		line_start = vim.fn.line(".")
		local is_visual = vim.tbl_contains({ "v", "V", "\22" }, vim.fn.mode())
		line_end = is_visual and vim.fn.line("v") or vim.fn.line(".")
		line_start, line_end = math.min(line_start, line_end), math.max(line_start, line_end)
	end

	if not (type(line_start) == "number" and type(line_end) == "number" and line_start <= line_end) then
		U.error("`line_start` and `line_end` should be non-decreasing numbers.")
	end
	return line_start, line_end
end

function U.error(msg)
	error(string.format("(git.nvim) %s", msg), 0)
end

function U.notify(msg, level_name)
	vim.notify("(git.nvim) " .. msg, vim.log.levels[level_name])
end

function U.trigger_event(event_name, data)
	vim.api.nvim_exec_autocmds("User", { pattern = event_name, data = data })
end

function U.is_fs_present(path)
	return vim.loop.fs_stat(path) ~= nil
end

function U.expandcmd(x)
	if x == "<cwd>" then
		return vim.fn.getcwd()
	end
	local ok, res = pcall(vim.fn.expandcmd, x)
	return ok and res or x
end

-- TODO: Remove after compatibility with Neovim=0.9 is dropped
U.islist = vim.fn.has("nvim-0.10") == 1 and vim.islist or vim.tbl_islist

function U.redrawstatus()
  if vim.api.nvim__redraw ~= nil then
    vim.api.nvim__redraw({ statusline = true })
  else
    vim.cmd("redrawstatus")
  end
end

function U.cli_read_stream(stream, feed)
	local callback = function(err, data)
		if err then
			return table.insert(feed, 1, "ERROR: " .. err)
		end
		if data ~= nil then
			return table.insert(feed, data)
		end
		stream:close()
	end
	stream:read_start(callback)
end

function U.cli_stream_tostring(stream)
	return (table.concat(stream):gsub("\n+$", ""))
end

function U.cli_err_notify(code, out, err)
	local should_stop = code ~= 0
	if should_stop then
		U.notify(err .. (out == "" and "" or ("\n" .. out)), "ERROR")
	end
	if not should_stop and err ~= "" then
		U.notify(err, "WARN")
	end
	return should_stop
end

function U.cli_escape(x)
	return (string.gsub(x, "([ \\])", "\\%1"))
end

function U.make_spawn_env(env_vars)
	-- Setup all environment variables (`vim.loop.spawn()` by default has none)
	local environ = vim.tbl_deep_extend("force", vim.loop.os_environ(), env_vars)
	local res = {}
	for k, v in pairs(environ) do
		table.insert(res, string.format("%s=%s", k, tostring(v)))
	end
	return res
end

-- Folding --------------------------------------------------------------------
function U.is_hunk_header(lnum)
	return vim.fn.getline(lnum):find("^@@.*@@") ~= nil
end

function U.is_log_entry_header(lnum)
	return vim.fn.getline(lnum):find("^commit ") ~= nil
end

function U.is_file_entry_header(lnum)
	return vim.fn.getline(lnum):find("^diff %-%-git") ~= nil
end

return U
