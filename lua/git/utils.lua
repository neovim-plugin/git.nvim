vim.loop = vim.uv or vim.loop

local U = {}

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

return U
