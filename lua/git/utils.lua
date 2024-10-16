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

-- History Navigation ---------------------------------------------------------
-- Assuming buffer contains unified combined diff (with "commit" header),
-- compute path, line number, and commit of both "before" and "after" files.
-- Allow cursor to be between "--- a/xxx" line and last line of a hunk.
function U.diff_pos_to_source()
	local lines, lnum = vim.api.nvim_buf_get_lines(0, 0, -1, false), vim.fn.line(".")

	local res = { init_prefix = lines[lnum]:sub(1, 1) }
	local paths_lnum = U.diff_parse_paths(res, lines, lnum)
	local hunk_lnum = U.diff_parse_hunk(res, lines, lnum)
	local commit_lnum = U.diff_parse_commits(res, lines, lnum)

	-- Try fall back to inferring target commits from 'git.nvim' buffer name
	if res.commit_before == nil or res.commit_after == nil then
		U.diff_parse_bufname(res)
	end

	local all_present = res.lnum_after and res.path_after and res.commit_after
	local is_in_order = commit_lnum <= paths_lnum and paths_lnum <= hunk_lnum
	if not (all_present and is_in_order) then
		return nil
	end

	return res
end

function U.diff_parse_paths(out, lines, lnum)
	local pattern_before, pattern_after = "^%-%-%- a/(.*)$", "^%+%+%+ b/(.*)$"

	-- Allow placing cursor directly on path defining lines
	local cur_line = lines[lnum]
	local path_before, path_after = string.match(cur_line, pattern_before), string.match(cur_line, pattern_after)
	if path_before ~= nil or path_after ~= nil then
		out.path_before = path_before or string.match(lines[lnum - 1] or "", pattern_before)
		out.path_after = path_after or string.match(lines[lnum + 1] or "", pattern_after)
		out.lnum_before, out.lnum_after = 1, 1
	else
		-- Iterate lines upward to find path patterns
		while out.path_after == nil and lnum > 0 do
			out.path_after = string.match(lines[lnum] or "", pattern_after)
			lnum = lnum - 1
		end
		out.path_before = string.match(lines[lnum] or "", pattern_before)
	end

	return lnum
end

function U.diff_parse_hunk(out, lines, lnum)
	if out.lnum_after ~= nil then
		return lnum
	end

	local offsets = { [" "] = 0, ["-"] = 0, ["+"] = 0 }
	while lnum > 0 do
		local prefix = lines[lnum]:sub(1, 1)
		if not (prefix == " " or prefix == "-" or prefix == "+") then
			break
		end
		offsets[prefix] = offsets[prefix] + 1
		lnum = lnum - 1
	end

	local hunk_start_before, hunk_start_after = string.match(lines[lnum] or "", "^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
	if hunk_start_before ~= nil then
		out.lnum_before = math.max(1, tonumber(hunk_start_before) + offsets[" "] + offsets["-"] - 1)
		out.lnum_after = math.max(1, tonumber(hunk_start_after) + offsets[" "] + offsets["+"] - 1)
	end
	return lnum
end

function U.diff_parse_commits(out, lines, lnum)
	while out.commit_after == nil and lnum > 0 do
		out.commit_after = string.match(lines[lnum], "^commit (%x+)$")
		lnum = lnum - 1
	end
	if out.commit_after ~= nil then
		out.commit_before = out.commit_after .. "~"
	end
	return lnum + 1
end

function U.diff_parse_bufname(out)
	local buf_name = vim.api.nvim_buf_get_name(0)
	local diff_command = string.match(buf_name, "^neovimgit://%d+/.* diff ?(.*)$")
	if diff_command == nil then
		return
	end

	-- Work with output of common `:Git diff` commands
	diff_command = vim.trim(diff_command)
	-- `Git diff` - compares index and work tree
	if diff_command == "" then
		out.commit_before, out.commit_after = ":0", true
	end
	-- `Git diff --cached` - compares HEAD and index
	if diff_command == "--cached" then
		out.commit_before, out.commit_after = "HEAD", ":0"
	end
	-- `Git diff HEAD` - compares commit and work tree
	if diff_command:find("^[^-]%S*$") ~= nil then
		out.commit_before, out.commit_after = diff_command, true
	end
end

function U.parse_diff_source_buf_name(buf_name)
	return string.match(buf_name, "^neovimgit://%d+/.*show (%x+~?):(.*)$")
end

function U.deps_pos_to_source()
	local lines = vim.api.nvim_buf_get_lines(0, 0, vim.fn.line("."), false)
	-- Do nothing if on the title (otherwise it operates on previous plugin info)
	if lines[#lines]:find("^[%+%-!]") ~= nil then
		return
	end

	-- Locate lines with commit and repo path data
	local commit, commit_lnum = nil, #lines
	while commit == nil and commit_lnum >= 1 do
		local l = lines[commit_lnum]
		commit = l:match("^[><] (%x%x%x%x%x%x%x%x*) |") or l:match("^State[^:]*: %s*(%x+)")
		commit_lnum = commit_lnum - 1
	end

	local cwd, cwd_lnum = nil, #lines
	while cwd == nil and cwd_lnum >= 1 do
		cwd, cwd_lnum = lines[cwd_lnum]:match("^Path: %s*(%S+)$"), cwd_lnum - 1
	end

	-- Do nothing if something is not found or path corresponds to next repo
	if commit == nil or cwd == nil or commit_lnum <= cwd_lnum then
		return
	end
	return commit, cwd
end

-- Window -----------------------------------------------------------------
function U.define_neovimgit_window(cleanup)
	local buf_id, win_id = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
	vim.bo.swapfile, vim.bo.buflisted = false, false

	-- Define action to finish editing Git related file
	local finish_au_id
	local finish = function(data)
		local should_close = data.buf == buf_id or (data.event == "WinClosed" and tonumber(data.match) == win_id)
		if not should_close then
			return
		end

		pcall(vim.api.nvim_del_autocmd, finish_au_id)
		pcall(vim.api.nvim_win_close, win_id, true)
		vim.schedule(function()
			pcall(vim.api.nvim_buf_delete, buf_id, { force = true })
		end)

		if vim.is_callable(cleanup) then
			vim.schedule(cleanup)
		end
	end
	-- - Use `nested` to allow other events (`WinEnter` for 'statusline.nvim')
	local events = { "WinClosed", "BufDelete", "BufWipeout", "VimLeave" }
	local opts = { nested = true, callback = finish, desc = "Cleanup window and buffer" }
	finish_au_id = vim.api.nvim_create_autocmd(events, opts)
end

-- Modifiers -----------------------------------------------------
-- NOTE: `mods` is already expanded, so this also covers abbreviated mods
function U.mods_is_split(mods)
	return mods:find("vertical") or mods:find("horizontal") or mods:find("tab")
end

return U
