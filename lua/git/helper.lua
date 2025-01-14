local H = {}
local U = require("git.utils")
local C = require("git.config")

-- Cache per enabled buffer. Values are tables with fields:
-- - <augroup> - identifier of augroup defining buffer behavior.
-- - <repo> - path to buffer's repo ('.git' directory).
-- - <root> - path to worktree root.
-- - <head> - full commit of `HEAD`.
-- - <head_name> - short name of `HEAD` (`'HEAD'` for detached head).
-- - <status> - current file status.
-- - <in_progress> - string name of action in progress (bisect, merge, etc.)
H.cache = {}

-- Cache per repo (git directory) path. Values are tables with fields:
-- - <fs_event> - `vim.loop` event for watching repo dir.
-- - <timer> - timer to debounce repo changes.
-- - <buffers> - map of buffers which should are part of repo.
H.repos = {}

-- Termporary file used as config for `GIT_EDITOR`
H.git_editor_config = nil

-- Data about supported Git subcommands. Initialized lazily. Fields:
-- - <supported> - array of supported one word commands.
-- - <complete> - array of commands to complete directly after `:Git`.
-- - <info> - map with fields as commands which show something to user.
-- - <options> - map of cached options per command; initialized lazily.
-- - <alias> - map of alias command name to command it implements.
H.git_subcommands = nil

-- Whether to temporarily skip some checks (like when inside `GIT_EDITOR`)
H.skip_timeout = false
H.skip_sync = false

-- Helper functionality =======================================================

function H.create_autocommands()
	local gr = vim.api.nvim_create_augroup("NeoVimGit", {})

	local au = function(event, pattern, callback, desc)
		vim.api.nvim_create_autocmd(event, { group = gr, pattern = pattern, callback = callback, desc = desc })
	end

	-- NOTE: Try auto enabling buffer on every `BufEnter` to not have `:edit`
	-- disabling buffer, as it calls `on_detach()` from buffer watcher
	au("BufEnter", "*", H.auto_enable, "Enable Git tracking")
end

function H.is_disabled(buf_id)
	return vim.g.neovimgit_disable == true or vim.b[buf_id or 0].neovimgit_disable == true
end

function H.create_user_commands()
	local opts = { bang = true, nargs = "+", complete = H.command_complete, desc = "Execute Git command" }
	vim.api.nvim_create_user_command("Git", H.command_impl, opts)
end

-- Autocommands ---------------------------------------------------------------
H.auto_enable = vim.schedule_wrap(function(data)
	local buf = data.buf
	if not (vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" and vim.bo[buf].buflisted) then
		return
	end
	NeoVimGit.enable(data.buf)
end)

-- Command --------------------------------------------------------------------
function H.command_impl(input)
	if not H.has_git then
		return H.notify("There is no `" .. C.job.git_executable .. "` executable", "ERROR")
	end

	H.ensure_git_subcommands()

	-- Define Git editor to be used if needed. The way it works is: execute
	-- command, wait for it to exit, use content of edited file. So to properly
	-- wait for user to finish edit, start fresh headless process which opens
	-- file in current session/process. It exits after the user is done editing
	-- (deletes the buffer or closes the window).
	H.ensure_git_editor(input.mods)
	-- NOTE: use `vim.v.progpath` to have same runtime
	local editor = H.cli_escape(vim.v.progpath) .. " --clean --headless -u " .. H.cli_escape(H.git_editor_config)

	-- Setup custom environment variables for better reproducibility
	local env_vars = {}
	-- - Use Git related variables to use instance for editing
	env_vars.GIT_EDITOR, env_vars.GIT_SEQUENCE_EDITOR, env_vars.GIT_PAGER = editor, editor, ""
	-- - Make output as much machine readable as possible
	env_vars.NO_COLOR, env_vars.TERM = 1, "dumb"
	local env = H.make_spawn_env(env_vars)

	-- Setup spawn arguments
	local args = vim.tbl_map(H.expandcmd, input.fargs)
	local command = { C.job.git_executable, unpack(args) }
	local cwd = H.get_git_cwd()

	local cmd_data = { cmd_input = input, git_command = command, cwd = cwd }
	local is_done_track = { done = false }
	local on_done = H.command_make_on_done(cmd_data, is_done_track)

	H.cli_run(command, cwd, on_done, { env = env })

	-- If needed, synchronously wait for job to finish
	local sync_check = function()
		return H.skip_sync or is_done_track.done
	end
	if not input.bang then
		vim.wait(C.job.timeout + 10, sync_check, 1)
	end
end

--stylua: ignore
function H.ensure_git_subcommands()
  if H.git_subcommands ~= nil then return end
  local git_subcommands = {}

  -- Compute all supported commands. All 'list-' are taken from Git source
  -- 'command-list.txt' file. Be so granular and not just `main,nohelpers` in
  -- order to not include purely man-page worthy items (like "remote-ext").
  local lists_all = {
    'list-mainporcelain',
    'list-ancillarymanipulators', 'list-ancillaryinterrogators',
    'list-foreignscminterface',
    'list-plumbingmanipulators', 'list-plumbinginterrogators',
    'others', 'alias',
  }
  local supported = H.git_cli_output({ '--list-cmds=' .. table.concat(lists_all, ',') })
  if #supported == 0 then
    -- Fall back only on basics if previous one failed for some reason
    supported = {
      'add', 'bisect', 'branch', 'clone', 'commit', 'diff', 'fetch', 'grep', 'init', 'log', 'merge',
      'mv', 'pull', 'push', 'rebase', 'reset', 'restore', 'rm', 'show', 'status', 'switch', 'tag',
    }
  end
  table.sort(supported)
  git_subcommands.supported = supported

  -- Compute complete list for commands by enhancing with two word commands.
  -- Keep those lists manual as there is no good way to compute lazily.
  local complete = vim.deepcopy(supported)
  local add_twoword = function(prefix, suffixes)
    if not vim.tbl_contains(supported, prefix) then return end
    for _, suf in ipairs(suffixes) do table.insert(complete, prefix .. ' ' .. suf) end
  end
  add_twoword('bundle',           { 'create', 'list-heads', 'unbundle', 'verify' })
  add_twoword('bisect',           { 'bad', 'good', 'log', 'replay', 'reset', 'run', 'skip', 'start', 'terms', 'view', 'visualize' })
  add_twoword('commit-graph',     { 'verify', 'write' })
  add_twoword('maintenance',      { 'run', 'start', 'stop', 'register', 'unregister' })
  add_twoword('multi-pack-index', { 'expire', 'repack', 'verify', 'write' })
  add_twoword('notes',            { 'add', 'append', 'copy', 'edit', 'get-ref', 'list', 'merge', 'prune', 'remove', 'show' })
  add_twoword('p4',               { 'clone', 'rebase', 'submit', 'sync' })
  add_twoword('reflog',           { 'delete', 'exists', 'expire', 'show' })
  add_twoword('remote',           { 'add', 'get-url', 'prune', 'remove', 'rename', 'rm', 'set-branches', 'set-head', 'set-url', 'show', 'update' })
  add_twoword('rerere',           { 'clear', 'diff', 'forget', 'gc', 'remaining', 'status' })
  add_twoword('sparse-checkout',  { 'add', 'check-rules', 'disable', 'init', 'list', 'reapply', 'set' })
  add_twoword('stash',            { 'apply', 'branch', 'clear', 'create', 'drop', 'list', 'pop', 'save', 'show', 'store' })
  add_twoword('submodule',        { 'absorbgitdirs', 'add', 'deinit', 'foreach', 'init', 'set-branch', 'set-url', 'status', 'summary', 'sync', 'update' })
  add_twoword('subtree',          { 'add', 'merge', 'pull', 'push', 'split' })
  add_twoword('worktree',         { 'add', 'list', 'lock', 'move', 'prune', 'remove', 'repair', 'unlock' })
  git_subcommands.complete = complete

  -- Compute commands which are meant to show information. These will show CLI
  -- output in separate buffer opposed to `vim.notify`.
  local info_args = { '--list-cmds=list-info,list-ancillaryinterrogators,list-plumbinginterrogators' }
  local info_commands = H.git_cli_output(info_args)
  if #info_commands == 0 then info_commands = { 'bisect', 'diff', 'grep', 'log', 'show', 'status' } end
  local info = {}
  for _, cmd in ipairs(info_commands) do
    info[cmd] = true
  end
  git_subcommands.info = info

  -- Compute commands which aliases rely on
  local alias_data = H.git_cli_output({ 'config', '--get-regexp', 'alias.*' })
  local alias = {}
  for _, l in ipairs(alias_data) do
    -- Assume simple alias of the form `alias.xxx subcommand ...`
    local alias_cmd, cmd = string.match(l, '^alias%.(%S+) (%S+)')
    if vim.tbl_contains(supported, cmd) then alias[alias_cmd] = cmd end
  end
  git_subcommands.alias = alias

  -- Initialize cache for command options. Initialize with `false` so that
  -- actual values are computed lazily when needed for a command.
  local options = { git = false }
  for _, command in ipairs(supported) do
    options[command] = false
  end
  git_subcommands.options = options

  -- Cache results
  H.git_subcommands = git_subcommands
end

function H.ensure_git_editor(mods)
	if H.git_editor_config == nil or not vim.fn.filereadable(H.git_editor_config) == 0 then
		H.git_editor_config = vim.fn.tempname()
	end

	-- Create a private function responsible for editing Git file
	NeoVimGit._edit = function(path, servername)
		-- Define editor state before and after editing path
		H.skip_timeout, H.skip_sync = true, true
		local cleanup = function()
			local _, channel = pcall(vim.fn.sockconnect, "pipe", servername, { rpc = true })
			local has_exec2 = vim.fn.has("nvim-0.9") == 1
			local method, opts = has_exec2 and "nvim_exec2" or "nvim_exec", has_exec2 and {} or false
			pcall(vim.rpcnotify, channel, method, "quitall!", opts)
			H.skip_timeout, H.skip_sync = false, false
		end

		-- Start file edit with proper modifiers in a special window
		mods = H.ensure_mods_is_split(mods)
		vim.cmd(mods .. " split " .. vim.fn.fnameescape(path))
		H.define_neovimgit_window(cleanup)
	end

	-- Start editing file from first argument (as how `GIT_EDITOR` works) in
	-- current instance and don't close until explicitly closed later from this
	-- instance as set up in `NeoVimGit._edit()`
	local lines = {
		"lua << EOF",
		string.format('local channel = vim.fn.sockconnect("pipe", %s, { rpc = true })', vim.inspect(vim.v.servername)),
		"local ins = vim.inspect",
		'local lua_cmd = string.format("NeoVimGit._edit(%s, %s)", ins(vim.fn.argv(0)), ins(vim.v.servername))',
		'vim.rpcrequest(channel, "nvim_exec_lua", lua_cmd, {})',
		"EOF",
	}
	vim.fn.writefile(lines, H.git_editor_config)
end

function H.get_git_cwd()
	local buf_cache = H.cache[vim.api.nvim_get_current_buf()] or {}
	return buf_cache.root or vim.fn.getcwd()
end

function H.command_make_on_done(cmd_data, is_done_track)
	return vim.schedule_wrap(function(code, out, err)
		-- Register that command is done executing (to enable sync execution)
		is_done_track.done = true

		-- Trigger "done" event
		cmd_data.git_subcommand = H.command_parse_subcommand(cmd_data.git_command)
		cmd_data.exit_code, cmd_data.stdout, cmd_data.stderr = code, out, err
		H.trigger_event("NeoVimGitCommandDone", cmd_data)

		-- Show stderr and stdout
		if H.cli_err_notify(code, out, err) then
			return
		end
		H.command_show_stdout(cmd_data)

		-- Ensure that all buffers are up to date (avoids "The file has been
		-- changed since reading it" warning)
		vim.tbl_map(function(buf_id)
			vim.cmd("checktime " .. buf_id)
		end, vim.api.nvim_list_bufs())
	end)
end

function H.command_show_stdout(cmd_data)
	local stdout, mods, subcommand = cmd_data.stdout, cmd_data.cmd_input.mods, cmd_data.git_subcommand
	if stdout == "" or (mods:find("silent") ~= nil and mods:find("unsilent") == nil) then
		return
	end

	-- Show in split if explicitly forced or the command shows info.
	-- Use `vim.notify` otherwise.
	local should_split = H.mods_is_split(mods) or H.git_subcommands.info[subcommand]
	if not should_split then
		return H.notify(stdout, "INFO")
	end

	local lines = vim.split(stdout, "\n")
	local name = table.concat(cmd_data.git_command, " ")
	cmd_data.win_source, cmd_data.win_stdout = H.show_in_split(mods, lines, subcommand, name)

	-- Trigger "split" event
	H.trigger_event("NeoVimGitCommandSplit", cmd_data)
end

function H.command_parse_subcommand(command)
	local res
	for _, cmd in ipairs(command) do
		if res == nil and vim.tbl_contains(H.git_subcommands.supported, cmd) then
			res = cmd
		end
	end
	return H.git_subcommands.alias[res] or res
end

function H.command_complete(_, line, col)
	-- Compute completion base manually to be "at cursor" and respect `\ `
	local base = H.get_complete_base(line:sub(1, col))
	local candidates, compl_type = H.command_get_complete_candidates(line, col, base)
	-- Allow several "//" at the end for path completion for easier "chaining"
	if compl_type == "path" then
		base = base:gsub("/+$", "/")
	end
	return vim.tbl_filter(function(x)
		return vim.startswith(x, base)
	end, candidates)
end

function H.get_complete_base(line)
	local from, _, res = line:find("(%S*)$")
	while from ~= nil do
		local cur_from, _, cur_res = line:sub(1, from - 1):find("(%S*\\ )$")
		if cur_res ~= nil then
			res = cur_res .. res
		end
		from = cur_from
	end
	return (res:gsub([[\ ]], " "))
end

function H.command_get_complete_candidates(line, col, base)
	H.ensure_git_subcommands()

	-- Determine current Git subcommand as the earliest present supported one
	local subcmd, subcmd_end = nil, math.huge
	for _, cmd in pairs(H.git_subcommands.supported) do
		local _, ind = line:find(" " .. cmd .. " ", 1, true)
		if ind ~= nil and ind < subcmd_end then
			subcmd, subcmd_end = cmd, ind
		end
	end

	subcmd = subcmd or "git"
	local cwd = H.get_git_cwd()

	-- Determine command candidates:
	-- - Commannd options if complete base starts with "-".
	-- - Paths if after explicit "--".
	-- - Git commands if there is none fully formed yet or cursor is at the end
	--   of the command (to also suggest subcommands).
	-- - Command targets specific for each command (if present).
	if vim.startswith(base, "-") then
		return H.command_complete_option(subcmd)
	end
	if line:sub(1, col):find(" -- ") ~= nil then
		return H.command_complete_path(cwd, base)
	end
	if subcmd_end == math.huge or (subcmd_end - 1) == col then
		return H.git_subcommands.complete, "subcommand"
	end

	subcmd = H.git_subcommands.alias[subcmd] or subcmd
	local complete_targets = H.command_complete_subcommand_targets[subcmd]
	if complete_targets == nil then
		return {}, nil
	end
	return complete_targets(cwd, base, line)
end

function H.command_complete_option(command)
	local cached_candidates = H.git_subcommands.options[command]
	if cached_candidates == nil then
		return {}
	end
	if type(cached_candidates) == "table" then
		return cached_candidates
	end

	-- Use alias's command to compute the options but store cache for alias
	local orig_command = command
	command = H.git_subcommands.alias[command] or command

	-- Find command's flag options by parsing its help page. Needs a bit
	-- heuristic approach and ensuring proper `git help` output (as it is done
	-- through `man`), but seems to work good enough.
	-- Alternative is to call command with `--git-completion-helper-all` flag (as
	-- is done in bash and vim-fugitive completion). This has both pros and cons:
	-- - Pros: faster; more targeted suggestions (like for two word subcommands);
	--         presumably more reliable.
	-- - Cons: works on smaller number of commands (for example, `rev-parse` or
	--         pure `git` do not work); does not provide single dash suggestions;
	--         does not work when not inside Git repo; needs recognizing two word
	--         commands before asking for completion.
	local env = H.make_spawn_env({ MANPAGER = "cat", NO_COLOR = 1, PAGER = "cat" })
	local lines = H.git_cli_output({ "help", "--man", command }, nil, env)
	-- - Exit early before caching to try again later
	if #lines == 0 then
		return {}
	end
	-- - On some systems (like Mac), output still might contain formatting
	--   sequences, like "a\ba" and "_\ba" meaning bold and italic.
	--   See https://github.com/echasnovski/mini.nvim/issues/918
	lines = vim.tbl_map(function(l)
		return l:gsub(".\b", "")
	end, lines)

	-- Construct non-duplicating candidates by parsing lines of help page
	local candidates_map = {}

	-- Options are assumed to be listed inside "OPTIONS" or "XXX OPTIONS" (like
	-- "MODE OPTIONS" of `git rebase`) section on dedicated lines. Whether a line
	-- contains only options is determined heuristically: it is assumed to start
	-- exactly with "       -" indicating proper indent for subsection start.
	-- Known not parsable options:
	-- - `git reset <mode>` (--soft, --hard, etc.): not listed in "OPTIONS".
	-- - All -<number> options, as they are not really completeable.
	local is_in_options_section = false
	for _, l in ipairs(lines) do
		if is_in_options_section and l:find("^%u[%u ]+$") ~= nil then
			is_in_options_section = false
		end
		if not is_in_options_section and l:find("^%u?[%u ]*OPTIONS$") ~= nil then
			is_in_options_section = true
		end
		if is_in_options_section and l:find("^       %-") ~= nil then
			H.parse_options(candidates_map, l)
		end
	end

	-- Finalize candidates. Should not contain "almost duplicates".
	-- Should also be sorted by relevance: short flags before regular flags.
	-- Inside groups sort alphabetically ignoring case.
	candidates_map["--"] = nil
	for cmd, _ in pairs(candidates_map) do
		-- There can be two explicitly documented options "--xxx" and "--xxx=".
		-- Use only one of them (without "=").
		if cmd:sub(-1, -1) == "=" and candidates_map[cmd:sub(1, -2)] ~= nil then
			candidates_map[cmd] = nil
		end
	end

	local res = vim.tbl_keys(candidates_map)
	table.sort(res, function(a, b)
		local a2, b2 = a:sub(2, 2) == "-", b:sub(2, 2) == "-"
		if a2 and not b2 then
			return false
		end
		if not a2 and b2 then
			return true
		end
		local a_low, b_low = a:lower(), b:lower()
		return a_low < b_low or (a_low == b_low and a < b)
	end)

	-- Cache and return
	H.git_subcommands.options[orig_command] = res
	return res, "option"
end

function H.parse_options(map, line)
	-- Options are standalone words starting as "-xxx" or "--xxx"
	-- Include possible "=" at the end indicating mandatory value
	line:gsub("%s(%-[-%w][-%w]*=?)", function(match)
		map[match] = true
	end)

	-- Make exceptions for commonly documented "--[no-]xxx" two options
	line:gsub("%s%-%-%[no%-%]([-%w]+=?)", function(match)
		map["--" .. match], map["--no-" .. match] = true, true
	end)
end

function H.command_complete_path(cwd, base)
	-- Treat base only as path relative to the command's cwd
	cwd = cwd:gsub("/+$", "") .. "/"
	local cwd_len = cwd:len()

	-- List elements from (absolute) target directory
	local target_dir = vim.fn.fnamemodify(base, ":h")
	target_dir = (cwd .. target_dir:gsub("^%.$", "")):gsub("/+$", "") .. "/"
	local ok, fs_entries = pcall(vim.fn.readdir, target_dir)
	if not ok then
		return {}
	end

	-- List directories and files separately
	local dirs, files = {}, {}
	for _, entry in ipairs(fs_entries) do
		local entry_abs = target_dir .. entry
		local arr = vim.fn.isdirectory(entry_abs) == 1 and dirs or files
		table.insert(arr, entry_abs)
	end
	dirs = vim.tbl_map(function(x)
		return x .. "/"
	end, dirs)

	-- List ordered directories first followed by ordered files
	local order_ignore_case = function(a, b)
		return a:lower() < b:lower()
	end
	table.sort(dirs, order_ignore_case)
	table.sort(files, order_ignore_case)

	-- Return candidates relative to command's cwd
	local all = dirs
	vim.list_extend(all, files)
	local res = vim.tbl_map(function(x)
		return x:sub(cwd_len + 1)
	end, all)
	return res, "path"
end

function H.command_complete_pullpush(cwd, _, line)
	-- Suggest remotes at `Git push |` and `Git push or|`, otherwise - references
	-- Ignore options when deciding which suggestion to compute
	local _, n_words = line:gsub(" (%-%S+)", ""):gsub("%S+ ", "")
	if n_words <= 2 then
		return H.git_cli_output({ "remote" }, cwd), "remote"
	end
	return H.git_cli_output({ "rev-parse", "--symbolic", "--branches", "--tags" }, cwd), "ref"
end

function H.make_git_cli_complete(args, complete_type)
	return function(cwd, _)
		return H.git_cli_output(args, cwd), complete_type
	end
end

-- Cover at least all subcommands listed in `git help`
--stylua: ignore
H.command_complete_subcommand_targets = {
  -- clone - no targets
  -- init  - no targets

  -- Worktree
  add     = H.command_complete_path,
  mv      = H.command_complete_path,
  restore = H.command_complete_path,
  rm      = H.command_complete_path,

  -- Examine history
  -- bisect - no targets
  diff = H.command_complete_path,
  grep = H.command_complete_path,
  log  = H.make_git_cli_complete({ 'rev-parse', '--symbolic', '--branches', '--tags' }, 'ref'),
  show = H.make_git_cli_complete({ 'rev-parse', '--symbolic', '--branches', '--tags' }, 'ref'),
  -- status - no targets

  -- Modify history
  branch = H.make_git_cli_complete({ 'rev-parse', '--symbolic', '--branches' },           'branch'),
  commit = H.command_complete_path,
  merge  = H.make_git_cli_complete({ 'rev-parse', '--symbolic', '--branches' },           'branch'),
  rebase = H.make_git_cli_complete({ 'rev-parse', '--symbolic', '--branches' },           'branch'),
  reset  = H.make_git_cli_complete({ 'rev-parse', '--symbolic', '--branches', '--tags' }, 'ref'),
  switch = H.make_git_cli_complete({ 'rev-parse', '--symbolic', '--branches' },           'branch'),
  tag    = H.make_git_cli_complete({ 'rev-parse', '--symbolic', '--tags' },               'tag'),

  -- Collaborate
  fetch = H.make_git_cli_complete({ 'remote' }, 'remote'),
  push = H.command_complete_pullpush,
  pull = H.command_complete_pullpush,

  -- Miscellaneous
  checkout = H.make_git_cli_complete({ 'rev-parse', '--symbolic', '--branches', '--tags', '--remotes' }, 'checkout'),
  config = H.make_git_cli_complete({ 'help', '--config-for-completion' }, 'config'),
  help = function()
    local res = { 'git', 'everyday' }
    vim.list_extend(res, H.git_subcommands.supported)
    return res, 'help'
  end,
}

function H.ensure_mods_is_split(mods)
	if not H.mods_is_split(mods) then
		local split_val = H.normalize_split_opt(C.command.split, "`config.command.split`")
		mods = split_val .. " " .. mods
	end
	return mods
end

H.mods_is_split = U.mods_is_split

-- Show stdout ----------------------------------------------------------------
function H.show_in_split(mods, lines, subcmd, name)
	-- Create a target window split
	mods = H.ensure_mods_is_split(mods)
	local win_source = vim.api.nvim_get_current_win()
	vim.cmd(mods .. " split")
	local win_stdout = vim.api.nvim_get_current_win()

	-- Prepare buffer
	local buf_id = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf_id, "neovimgit://" .. buf_id .. "/" .. name)
	vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)

	vim.api.nvim_set_current_buf(buf_id)
	H.define_neovimgit_window()

	-- NOTE: set filetype when buffer is in window to allow setting window-local
	-- options in autocommands for `FileType` events
	local filetype
	if subcmd == "diff" then
		filetype = "diff"
	end
	if subcmd == "log" or subcmd == "blame" then
		filetype = "git"
	end
	if subcmd == "show" then
		-- Try detecting 'git' filetype by content first, as filetype detection can
		-- rely on the buffer name (i.e. command) having proper extension. It isn't
		-- good for cases like `:Git show HEAD file.lua` (which should be 'git').
		local l = lines[1]
		local is_diff = l:find(string.rep("%x", 40)) or l:find("ref:")
		filetype = is_diff and "git" or vim.filetype.match({ buf = buf_id })
	end

	local has_filetype = not (filetype == nil or filetype == "")
	if has_filetype then
		vim.bo[buf_id].filetype = filetype
	end

	-- Completely unfold for no filetype output (like `:Git help`)
	if not has_filetype then
		vim.wo[win_stdout].foldlevel = 999
	end

	return win_source, win_stdout
end

H.define_neovimgit_window = U.define_neovimgit_window

function H.git_cli_output(args, cwd, env)
	if cwd ~= nil and vim.fn.isdirectory(cwd) ~= 1 then
		return {}
	end
	local command = { C.job.git_executable, "--no-pager", unpack(args) }
	local res = H.cli_run(command, cwd, nil, { env = env }).out
	if res == "" then
		return {}
	end
	return vim.split(res, "\n")
end

-- Validators -----------------------------------------------------------------
H.validate_buf_id = U.validate_buf_id
H.normalize_split_opt = U.normalize_split_opt
H.normalize_range_lines = U.normalize_range_lines

-- Enabling -------------------------------------------------------------------
function H.is_buf_enabled(buf_id)
	return H.cache[buf_id] ~= nil and vim.api.nvim_buf_is_valid(buf_id)
end

function H.setup_buf_behavior(buf_id)
	local augroup = vim.api.nvim_create_augroup("NeoVimGitBuffer" .. buf_id, { clear = true })
	H.cache[buf_id].augroup = augroup

	vim.api.nvim_buf_attach(buf_id, false, {
		-- Called when buffer content is changed outside of current session
		-- Needed as otherwise `on_detach()` is called without later auto enabling
		on_reload = function()
			local buf_cache = H.cache[buf_id]
			if buf_cache == nil or buf_cache.root == nil then
				return
			end
			-- Don't upate repo/root as it is tracked in 'BufFilePost' autocommand
			H.update_git_head(buf_cache.root, { buf_id })
			H.update_git_in_progress(buf_cache.repo, { buf_id })
			-- Don't upate status as it is tracked in file watcher
		end,

		-- Called when buffer is unloaded from memory (`:h nvim_buf_detach_event`),
		-- **including** `:edit` command. Together with auto enabling it makes
		-- `:edit` command serve as "restart".
		on_detach = function()
			NeoVimGit.disable(buf_id)
		end,
	})

	local reset_if_enabled = vim.schedule_wrap(function(data)
		if not H.is_buf_enabled(data.buf) then
			return
		end
		NeoVimGit.disable(data.buf)
		NeoVimGit.enable(data.buf)
	end)
	local bufrename_opts = { group = augroup, buffer = buf_id, callback = reset_if_enabled, desc = "Reset on rename" }
	-- NOTE: `BufFilePost` does not look like a proper event, but it (yet) works
	vim.api.nvim_create_autocmd("BufFilePost", bufrename_opts)

	local buf_disable = function()
		NeoVimGit.disable(buf_id)
	end
	local bufdelete_opts = { group = augroup, buffer = buf_id, callback = buf_disable, desc = "Disable on delete" }
	vim.api.nvim_create_autocmd("BufDelete", bufdelete_opts)
end

-- Tracking -------------------------------------------------------------------
function H.start_tracking(buf_id, path)
	local command = H.git_cmd({ "rev-parse", "--path-format=absolute", "--git-dir", "--show-toplevel" })

	-- If path is not in Git, disable buffer but make sure that it will not try
	-- to re-attach until buffer is properly disabled
	local on_not_in_git = function()
		if H.is_buf_enabled(buf_id) then
			NeoVimGit.disable(buf_id)
		end
		H.cache[buf_id] = {}
	end

	local on_done = vim.schedule_wrap(function(code, out, err)
		-- Watch git directory only if there was no error retrieving path to it
		if code ~= 0 then
			return on_not_in_git()
		end
		H.cli_err_notify(code, out, err)

		-- Update buf data
		local repo, root = string.match(out, "^(.-)\n(.*)$")
		if repo == nil or root == nil then
			return H.notify("No initial data for buffer " .. buf_id, "WARN")
		end
		H.update_buf_data(buf_id, { repo = repo, root = root })

		-- Set up repo watching to react to Git index changes
		H.setup_repo_watch(buf_id, repo)

		-- Set up worktree watching to react to file changes
		H.setup_path_watch(buf_id)

		-- Immediately update buffer tracking data
		H.update_git_head(root, { buf_id })
		H.update_git_in_progress(repo, { buf_id })
		H.update_git_status(root, { buf_id })
	end)

	H.cli_run(command, vim.fn.fnamemodify(path, ":h"), on_done)
end

function H.setup_repo_watch(buf_id, repo)
	local repo_cache = H.repos[repo] or {}

	-- Ensure repo is watched
	local is_set_up = repo_cache.fs_event ~= nil and repo_cache.fs_event:is_active()
	if not is_set_up then
		H.teardown_repo_watch(repo)
		local fs_event, timer = vim.loop.new_fs_event(), vim.loop.new_timer()

		local on_change = vim.schedule_wrap(function()
			H.on_repo_change(repo)
		end)
		local watch = function(_, filename, _)
			-- Ignore temporary changes
			if vim.endswith(filename, "lock") then
				return
			end

			-- Debounce to not overload during incremental staging (like in script)
			timer:stop()
			timer:start(50, 0, on_change)
		end
		-- Watch only '.git' dir (non-recursively), as this seems to be both enough
		-- and not supported by libuv (`recursive` flag does nothing,
		-- see https://github.com/libuv/libuv/issues/1778)
		fs_event:start(repo, {}, watch)

		repo_cache.fs_event, repo_cache.timer = fs_event, timer
		H.repos[repo] = repo_cache
	end

	-- Register buffer to be updated on repo change
	local repo_buffers = repo_cache.buffers or {}
	repo_buffers[buf_id] = true
	repo_cache.buffers = repo_buffers
end

function H.teardown_repo_watch(repo)
	if H.repos[repo] == nil then
		return
	end
	pcall(vim.loop.fs_event_stop, H.repos[repo].fs_event)
	pcall(vim.loop.timer_stop, H.repos[repo].timer)
end

function H.setup_path_watch(buf_id, repo)
	if not H.is_buf_enabled(buf_id) then
		return
	end

	local on_file_change = function(data)
		H.update_git_status(H.cache[buf_id].root, { buf_id })
	end
	local opts =
		{ desc = "Update Git status", group = H.cache[buf_id].augroup, buffer = buf_id, callback = on_file_change }
	vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, opts)
end

function H.on_repo_change(repo)
	if H.repos[repo] == nil then
		return
	end

	-- Collect repo's worktrees with their buffers while doing cleanup
	local repo_bufs, root_bufs = H.repos[repo].buffers, {}
	for buf_id, _ in pairs(repo_bufs) do
		if H.is_buf_enabled(buf_id) then
			local root = H.cache[buf_id].root
			local bufs = root_bufs[root] or {}
			table.insert(bufs, buf_id)
			root_bufs[root] = bufs
		else
			repo_bufs[buf_id] = nil
			NeoVimGit.disable(buf_id)
		end
	end

	-- Update Git data
	H.update_git_in_progress(repo, vim.tbl_keys(repo_bufs))
	for root, bufs in pairs(root_bufs) do
		H.update_git_head(root, bufs)
		-- Status could have also changed as it depends on the index
		H.update_git_status(root, bufs)
	end
end

function H.update_git_head(root, bufs)
	local command = H.git_cmd({ "rev-parse", "HEAD", "--abbrev-ref", "HEAD" })

	local on_done = vim.schedule_wrap(function(code, out, err)
		-- Ensure proper data
		if code ~= 0 then
			return
		end
		H.cli_err_notify(code, out, err)

		local head, head_name = string.match(out, "^(.-)\n(.*)$")
		if head == nil or head_name == nil then
			return H.notify("Could not parse HEAD data for root " .. root .. "\n" .. out, "WARN")
		end

		-- Update data for all buffers from target `root`
		local new_data = { head = head, head_name = head_name }
		for _, buf_id in ipairs(bufs) do
			H.update_buf_data(buf_id, new_data)
		end

		-- Redraw statusline to have possible statusline component up to date
		H.redrawstatus()
	end)

	H.cli_run(command, root, on_done)
end

function H.update_git_in_progress(repo, bufs)
	-- Get data about what process is in progress
	local in_progress = {}
	if H.is_fs_present(repo .. "/BISECT_LOG") then
		table.insert(in_progress, "bisect")
	end
	if H.is_fs_present(repo .. "/CHERRY_PICK_HEAD") then
		table.insert(in_progress, "cherry-pick")
	end
	if H.is_fs_present(repo .. "/MERGE_HEAD") then
		table.insert(in_progress, "merge")
	end
	if H.is_fs_present(repo .. "/REVERT_HEAD") then
		table.insert(in_progress, "revert")
	end
	if H.is_fs_present(repo .. "/rebase-apply") then
		table.insert(in_progress, "apply")
	end
	if H.is_fs_present(repo .. "/rebase-merge") then
		table.insert(in_progress, "rebase")
	end

	-- Update data for all buffers from target `root`
	local new_data = { in_progress = table.concat(in_progress, ",") }
	for _, buf_id in ipairs(bufs) do
		H.update_buf_data(buf_id, new_data)
	end

	-- Redraw statusline to have possible statusline component up to date
	H.redrawstatus()
end

function H.update_git_status(root, bufs)
	local command =
		H.git_cmd({ "status", "--verbose", "--untracked-files=all", "--ignored", "--porcelain", "-z", "--" })
	local root_len, path_data = string.len(root), {}
	for _, buf_id in ipairs(bufs) do
		-- Use paths relative to the root as in `git status --porcelain` output
		local rel_path = vim.api.nvim_buf_get_name(buf_id):sub(root_len + 2)
		table.insert(command, rel_path)
		-- Completely not modified paths should be the only ones missing in the
		-- output. Use this status as default.
		path_data[rel_path] = { status = "  ", buf_id = buf_id }
	end

	local on_done = vim.schedule_wrap(function(code, out, err)
		if code ~= 0 then
			return
		end
		H.cli_err_notify(code, out, err)

		-- Parse CLI output, which is separated by `\0` to not escape "bad" paths
		for _, l in ipairs(vim.split(out, "\0")) do
			local status, rel_path = string.match(l, "^(..) (.*)$")
			if path_data[rel_path] ~= nil then
				path_data[rel_path].status = status
			end
		end

		-- Update data for all buffers
		for _, data in pairs(path_data) do
			local new_data = { status = data.status }
			H.update_buf_data(data.buf_id, new_data)
		end

		-- Redraw statusline to have possible statusline component up to date
		H.redrawstatus()
	end)

	H.cli_run(command, root, on_done)
end

function H.update_buf_data(buf_id, new_data)
	if not H.is_buf_enabled(buf_id) then
		return
	end

	local summary = vim.b[buf_id].neovimgit_summary or {}
	for key, val in pairs(new_data) do
		H.cache[buf_id][key], summary[key] = val, val
	end
	vim.b[buf_id].neovimgit_summary = summary

	-- Format summary string
	local head = summary.head_name or ""
	head = head == "HEAD" and summary.head:sub(1, 7) or head

	local in_progress = summary.in_progress or ""
	if in_progress ~= "" then
		head = head .. "|" .. in_progress
	end

	local summary_string = head
	local status = summary.status or ""
	if status ~= "  " and status ~= "" then
		summary_string = string.format("%s (%s)", head, status)
	end
	vim.b[buf_id].neovimgit_summary_string = summary_string

	-- Trigger dedicated event with target current buffer (for proper `data.buf`)
	vim.api.nvim_buf_call(buf_id, function()
		H.trigger_event("NeoVimGitUpdated")
	end)
end

-- History navigation ---------------------------------------------------------
H.diff_pos_to_source = U.diff_pos_to_source
H.diff_parse_paths = U.diff_parse_paths
H.diff_parse_hunk = U.diff_parse_hunk
H.diff_parse_commits = U.diff_parse_commits

H.diff_parse_bufname = U.diff_parse_bufname
H.parse_diff_source_buf_name = U.parse_diff_source_buf_name
H.deps_pos_to_source = U.deps_pos_to_source

-- Folding --------------------------------------------------------------------
H.is_hunk_header = U.is_hunk_header
H.is_log_entry_header = U.is_log_entry_header
H.is_file_entry_header = U.is_file_entry_header

-- CLI ------------------------------------------------------------------------
function H.git_cmd(args)
	-- Use '-c gc.auto=0' to disable `stderr` "Auto packing..." messages
	return { C.job.git_executable, "-c", "gc.auto=0", unpack(args) }
end

H.make_spawn_env = U.make_spawn_env

function H.cli_run(command, cwd, on_done, opts)
	local spawn_opts = opts or {}
	local executable, args = command[1], vim.list_slice(command, 2, #command)
	local process, stdout, stderr = nil, vim.loop.new_pipe(), vim.loop.new_pipe()
	spawn_opts.args, spawn_opts.cwd, spawn_opts.stdio = args, cwd or vim.fn.getcwd(), { nil, stdout, stderr }

	-- Allow `on_done = nil` to mean synchronous execution
	local is_sync, res = false, nil
	if on_done == nil then
		is_sync = true
		on_done = function(code, out, err)
			res = { code = code, out = out, err = err }
		end
	end

	local out, err, is_done = {}, {}, false
	local on_exit = function(code)
		-- Ensure calling this only once
		if is_done then
			return
		end
		is_done = true

		if process:is_closing() then
			return
		end
		process:close()

		-- Convert to strings appropriate for notifications
		out = H.cli_stream_tostring(out)
		err = H.cli_stream_tostring(err):gsub("\r+", "\n"):gsub("\n%s+\n", "\n\n")
		on_done(code, out, err)
	end

	process = vim.loop.spawn(executable, spawn_opts, on_exit)
	H.cli_read_stream(stdout, out)
	H.cli_read_stream(stderr, err)
	vim.defer_fn(function()
		if H.skip_timeout or not process:is_active() then
			return
		end
		H.notify("PROCESS REACHED TIMEOUT", "WARN")
		on_exit(1)
	end, C.job.timeout)

	if is_sync then
		vim.wait(C.job.timeout + 10, function()
			return is_done
		end, 1)
	end
	return res
end

H.cli_read_stream = U.cli_read_stream
H.cli_stream_tostring = U.cli_stream_tostring
H.cli_err_notify = U.cli_err_notify
H.cli_escape = U.cli_escape

-- Utilities ------------------------------------------------------------------
H.error = U.error
H.notify = U.notify
H.trigger_event = U.trigger_event
H.is_fs_present = U.is_fs_present
H.expandcmd = U.expandcmd
H.islist = U.islist
H.redrawstatus = U.redrawstatus

return H
