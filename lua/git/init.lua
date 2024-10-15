---@alias __git_buf_id number Target buffer identifier. Default: 0 for current buffer.
---@alias __git_split_field <split> `(string)` - split direction. One of "horizontal", "vertical",
---     "tab", or "auto" (default). Value "auto" uses |:vertical| if only 'git.nvim'
---     buffers are shown in the tabpage and |:tab| otherwise.

---@diagnostic disable:undefined-field
---@diagnostic disable:discard-returns
---@diagnostic disable:unused-local
---@diagnostic disable:cast-local-type
---@diagnostic disable:undefined-doc-name
---@diagnostic disable:luadoc-miss-type-name

-- Module definition ==========================================================
local NeoVimGit = {}
local H = require("git.helper")
local C = require("git.config")

--- Module setup
---
--- Besides general side effects (see |mini.nvim|), it also:
--- - Sets up auto enabling in every normal buffer for an actual file on disk.
--- - Creates |:Git| command.
---
---@param opts table|nil Module config table. See |NeoVimGit.config|.
---
---@usage >lua
---   require('git.nvim').setup() -- use default config
---   -- OR
---   require('git.nvim').setup({}) -- replace {} with your config table
--- <
NeoVimGit.setup = function(opts)
	-- Export module
	_G.NeoVimGit = NeoVimGit

	-- Setup config
  C.merge(opts)

	-- Ensure proper Git executable
	local exec = C.job.git_executable
	H.has_git = vim.fn.executable(exec) == 1
	if not H.has_git then
		H.notify("There is no `" .. exec .. "` executable", "WARN")
	end

	-- Define behavior
	H.create_autocommands()
	for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
		H.auto_enable({ buf = buf_id })
	end

	-- Create user commands
	H.create_user_commands()
end

--stylua: ignore
--- Module config
---
--- Default values:
---@text # Job ~
---
--- `config.job` contains options for customizing CLI executions.
---
--- `job.git_executable` defines a full path to Git executable. Default: "git".
---
--- `job.timeout` is a duration (in ms) from job start until it is forced to stop.
--- Default: 30000.
---
--- # Command ~
---
--- `config.command` contains options for customizing |:Git| command.
---
--- `command.split` defines default split direction for |:Git| command output. Can be
--- one of "horizontal", "vertical", "tab", or "auto". Value "auto" uses |:vertical|
--- if only 'git.nvim' buffers are shown in the tabpage and |:tab| otherwise.
--- Default: "auto".
NeoVimGit.config = {
  -- General CLI execution
  job = {
    -- Path to Git executable
    git_executable = 'git',

    -- Timeout (in ms) for each job before force quit
    timeout = 30000,
  },

  -- Options for `:Git` command
  command = {
    -- Default split direction
    split = 'auto',
  },
}
--minidoc_afterlines_end

--- Show Git related data at cursor
---
--- - If inside |mini.deps| confirmation buffer, show in split relevant commit data.
--- - If there is a commit-like |<cword>|, show it in split.
--- - If possible, show diff source via |NeoVimGit.show_diff_source()|.
--- - If possible, show range history via |NeoVimGit.show_range_history()|.
--- - Otherwise throw an error.
---
---@param opts table|nil Options. Possible values:
---   - __git_split_field
---   - Fields appropriate for forwarding to other functions.
NeoVimGit.show_at_cursor = function(opts)
	local cword = vim.fn.expand("<cword>")
	local is_commit = string.find(cword, "^%x%x%x%x%x%x%x+$") ~= nil and string.lower(cword) == cword
	local commit = is_commit and cword or nil
	local cwd = is_commit and H.get_git_cwd() or nil

	if commit ~= nil and cwd ~= nil then
		local split = H.normalize_split_opt((opts or {}).split or "auto", "opts.split")
		local args = { "show", "--stat", "--patch", commit }
		local lines = H.git_cli_output(args, cwd)
		if #lines == 0 then
			return H.notify("Can not show commit " .. commit .. " in repo " .. cwd, "WARN")
		end
		H.show_in_split(split, lines, "show", table.concat(args, " "))
		vim.bo.filetype = "git"
		return
	end

	-- Try showing diff source
	if H.diff_pos_to_source() ~= nil then
		return NeoVimGit.show_diff_source(opts)
	end

	-- Try showing range history if possible: either in Git repo (tracked or not)
	-- or diff source output.
	local buf_id, path = vim.api.nvim_get_current_buf(), vim.api.nvim_buf_get_name(0)
	local is_in_git = H.is_buf_enabled(buf_id)
		or #H.git_cli_output({ "rev-parse", "--show-toplevel" }, vim.fn.fnamemodify(path, ":h")) > 0
	local is_diff_source_output = H.parse_diff_source_buf_name(path) ~= nil
	if is_in_git or is_diff_source_output then
		return NeoVimGit.show_range_history(opts)
	end

	H.notify("Nothing Git-related to show at cursor", "WARN")
end

--- Show diff source
---
--- When buffer contains text formatted as unified patch (like after
--- `:Git log --patch`, `:Git diff`, or |NeoVimGit.show_range_history()|),
--- show state of the file at the particular state. Target commit/state, path,
--- and line number are deduced from cursor position.
---
--- Notes:
--- - Needs |current-directory| to be the Git root for relative paths to work.
--- - Needs cursor to be inside hunk lines or on "---" / "+++" lines with paths.
--- - Only basic forms of `:Git diff` output is supported: `:Git diff`,
---   `:Git diff --cached`, and `:Git diff <commit>`.
---
---@param opts table|nil Options. Possible values:
---   - __git_split_field
---   - <target> `(string)` - which file state to show. One of "before", "after",
---     "both" (both states in vertical split), "auto" (default). Value "auto"
---     shows "before" state if cursor line starts with "-", otherwise - "after".
NeoVimGit.show_diff_source = function(opts)
	opts = vim.tbl_deep_extend("force", { split = "auto", target = "auto" }, opts or {})
	local split = H.normalize_split_opt(opts.split, "opts.split")
	local target = opts.target
	if not (target == "auto" or target == "before" or target == "after" or target == "both") then
		H.error('`opts.target` should be one of "auto", "before", "after", "both".')
	end

	local src = H.diff_pos_to_source()
	if src == nil then
		return H.notify(
			"Could not find diff source. Ensure that cursor is inside a valid diff lines of git log.",
			"WARN"
		)
	end
	if target == "auto" then
		target = src.init_prefix == "-" and "before" or "after"
	end

	local cwd = H.get_git_cwd()
	local show = function(commit, path, mods)
		local is_worktree, args, lines = commit == true, nil, nil
		if is_worktree then
			args, lines = { "edit", vim.fn.fnameescape(path) }, vim.fn.readfile(path)
		else
			args = { "show", commit .. ":" .. path }
			lines = H.git_cli_output(args, cwd)
		end
		if #lines == 0 and not is_worktree then
			return H.notify("Can not show " .. path .. "at commit " .. commit, "WARN")
		end
		H.show_in_split(mods, lines, "show", table.concat(args, " "))
	end

	local has_before_shown = false
	if target ~= "after" then
		-- "Before" file can be absend if hunk is from newly added file
		if src.path_before == nil then
			H.notify('Could not find "before" file', "WARN")
		else
			show(src.commit_before, src.path_before, split)
			vim.api.nvim_win_set_cursor(0, { src.lnum_before, 0 })
			has_before_shown = true
		end
	end

	if target ~= "before" then
		local mods_after = has_before_shown and "belowright vertical" or split
		show(src.commit_after, src.path_after, mods_after)
		vim.api.nvim_win_set_cursor(0, { src.lnum_after, 0 })
	end
end

--- Show range history
---
--- Compute and show in split data about how particular line range in current
--- buffer evolved through Git history. Essentially a `git log` with `-L` flag.
---
--- Notes:
--- - Works well with |NeoVimGit.diff_foldexpr()|.
--- - Does not work if there are uncommited changes, as there is no easy way to
---   compute effective range line numbers.
---
---@param opts table|nil Options. Possible fields:
---   - <line_start> `(number)` - range start line.
---   - <line_end> `(number)` - range end line.
---     If both <line_start> and <line_end> are not supplied, they default to
---     current line in Normal mode and visual selection in Visual mode.
---   - <log_args> `(table)` - array of options to append to `git log` call.
---   - __git_split_field
NeoVimGit.show_range_history = function(opts)
	local default_opts = { line_start = nil, line_end = nil, log_args = nil, split = "auto" }
	opts = vim.tbl_deep_extend("force", default_opts, opts or {})
	local line_start, line_end = H.normalize_range_lines(opts.line_start, opts.line_end)
	local log_args = opts.log_args or {}
	if not H.islist(log_args) then
		H.error("`opts.log_args` should be an array.")
	end
	local split = H.normalize_split_opt(opts.split, "opts.split")

	-- Construct `:Git log` command that works both with regular files and
	-- buffers from `show_diff_source()`
	local buf_name, cwd = vim.api.nvim_buf_get_name(0), H.get_git_cwd()
	local commit, rel_path = H.parse_diff_source_buf_name(buf_name)
	if commit == nil then
		commit = "HEAD"
		local cwd_pattern = "^" .. vim.pesc(cwd:gsub("\\", "/")) .. "/"
		rel_path = buf_name:gsub("\\", "/"):gsub(cwd_pattern, "")
	end

	-- Ensure no uncommitted changes as they might result into improper `-L` arg
	local diff = commit == "HEAD" and H.git_cli_output({ "diff", "-U0", "HEAD", "--", rel_path }, cwd) or {}
	if #diff ~= 0 then
		return H.notify("Current file has uncommitted lines. Commit or stash before exploring history.", "WARN")
	end

	-- Show log in split
	local range_flag = string.format("-L%d,%d:%s", line_start, line_end, rel_path)
	local args = { "log", range_flag, commit, unpack(log_args) }
	local history = H.git_cli_output(args, cwd)
	if #history == 0 then
		return H.notify("Could not get range history", "WARN")
	end
	H.show_in_split(split, history, "log", table.concat(args, " "))
end

--- Fold expression for Git logs
---
--- Folds contents of hunks, file patches, and log entries in unified diff.
--- Useful for filetypes "diff" (like after `:Git diff`) and "git" (like after
--- `:Git log --patch` or `:Git show` for commit).
--- Works well with |NeoVimGit.show_range_history()|.
---
--- General idea of folding levels (use |zr| and |zm| to adjust interactively):
--- - At level 0 there is one line per whole patch or log entry.
--- - At level 1 there is one line per patched file.
--- - At level 2 there is one line per hunk.
--- - At level 3 there is no folds.
---
--- For automated setup, set the following for "git" and "diff" filetypes (either
--- inside |FileType| autocommand or |ftplugin|): >vim
---
---   setlocal foldmethod=expr foldexpr=v:lua.NeoVimGit.diff_foldexpr()
--- <
---@param lnum number|nil Line number for which fold level is computed.
---   Default: |v:lnum|.
---
---@return number|string Line fold level. See |fold-expr|.
NeoVimGit.diff_foldexpr = function(lnum)
	lnum = lnum or vim.v.lnum
	if H.is_log_entry_header(lnum + 1) or H.is_log_entry_header(lnum) then
		return 0
	end
	if H.is_file_entry_header(lnum) then
		return 1
	end
	if H.is_hunk_header(lnum) then
		return 2
	end
	if H.is_hunk_header(lnum - 1) then
		return 3
	end
	return "="
end

--- Enable Git tracking in a file buffer
---
--- Tracking is done by reacting to changes in file content or file's repository
--- in the form of keeping buffer data up to date. The data can be used via:
--- - |NeoVimGit.get_buf_data()|. See its help for a list of actually tracked data.
--- - `vim.b.neovimgit_summary` (table) and `vim.b.neovimgit_summary_string` (string)
---   buffer-local variables which are more suitable for statusline.
---   `vim.b.neovimgit_summary_string` contains information about HEAD, file status,
---   and in progress action (see |NeoVimGit.get_buf_data()| for more details).
---   See |NeoVimGit-examples| for how it can be tweaked and used in statusline.
---
--- Note: this function is called automatically for all new normal buffers.
--- Use it explicitly if buffer was disabled.
---
--- `User` event `NeoVimGitUpdated` is triggered whenever tracking data is updated.
--- Note that not all data listed in |NeoVimGit.get_buf_data()| can be present (yet)
--- at the point of event being triggered.
---
---@param buf_id __git_buf_id
NeoVimGit.enable = function(buf_id)
	buf_id = H.validate_buf_id(buf_id)

	-- Don't enable more than once
	if H.is_buf_enabled(buf_id) or H.is_disabled(buf_id) or not H.has_git then
		return
	end

	-- Enable only in buffers which *can* be part of Git repo
	local path = vim.api.nvim_buf_get_name(buf_id)
	if path == "" or vim.fn.filereadable(path) ~= 1 then
		return
	end

	-- Start tracking
	H.cache[buf_id] = {}
	H.setup_buf_behavior(buf_id)
	H.start_tracking(buf_id, path)
end

--- Disable Git tracking in buffer
---
---@param buf_id __git_buf_id
NeoVimGit.disable = function(buf_id)
	buf_id = H.validate_buf_id(buf_id)

	local buf_cache = H.cache[buf_id]
	if buf_cache == nil then
		return
	end
	H.cache[buf_id] = nil

	-- Cleanup
	pcall(vim.api.nvim_del_augroup_by_id, buf_cache.augroup)
	vim.b[buf_id].neovimgit_summary, vim.b[buf_id].neovimgit_summary_string = nil, nil

	-- - Unregister buffer from repo watching with possibly more cleanup
	local repo = buf_cache.repo
	if H.repos[repo] == nil then
		return
	end
	H.repos[repo].buffers[buf_id] = nil
	if vim.tbl_count(H.repos[repo].buffers) == 0 then
		H.teardown_repo_watch(repo)
		H.repos[repo] = nil
	end
end

--- Toggle Git tracking in buffer
---
--- Enable if disabled, disable if enabled.
---
---@param buf_id __git_buf_id
NeoVimGit.toggle = function(buf_id)
	buf_id = H.validate_buf_id(buf_id)
	if H.is_buf_enabled(buf_id) then
		return NeoVimGit.disable(buf_id)
	end
	return NeoVimGit.enable(buf_id)
end

--- Get buffer data
---
---@param buf_id __git_buf_id
---
---@return table|nil Table with buffer Git data or `nil` if buffer is not enabled.
---   If the file is not part of Git repo, table will be empty.
---   Table has the following fields:
---   - <repo> `(string)` - full path to '.git' directory.
---   - <root> `(string)` - full path to worktree root.
---   - <head> `(string)` - full commit of current HEAD.
---   - <head_name> `(string)` - short name of current HEAD (like "master").
---     For detached HEAD it is "HEAD".
---   - <status> `(string)` - two character file status as returned by `git status`.
---   - <in_progress> `(string)` - name of action(s) currently in progress
---     (bisect, merge, etc.). Can be a combination of those separated by ",".
NeoVimGit.get_buf_data = function(buf_id)
	buf_id = H.validate_buf_id(buf_id)
	local buf_cache = H.cache[buf_id]
	if buf_cache == nil then
		return nil
	end
  --stylua: ignore
  return {
    repo   = buf_cache.repo,   root        = buf_cache.root,
    head   = buf_cache.head,   head_name   = buf_cache.head_name,
    status = buf_cache.status, in_progress = buf_cache.in_progress,
  }
end

return NeoVimGit
