local U = require("git.utils")

local M = {}

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
local config = {
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

function M.merge(conf)
  -- General idea: if some table elements are not present in user-supplied
	-- `config`, take them from default config
	vim.validate({ conf = { conf, "table", true } })
	config = vim.tbl_deep_extend("force", config, conf or {})

	vim.validate({
		job = { config.job, "table" },
		command = { config.command, "table" },
	})

	local is_split = function(x)
		return pcall(U.normalize_split_opt, x, "command.split")
	end
	vim.validate({
		["job.git_executable"] = { config.job.git_executable, "string" },
		["job.timeout"] = { config.job.timeout, "number" },
		["command.split"] = { config.command.split, is_split },
	})
end

function M.get()
  return config
end

return setmetatable(M, {
  __index = function(_, key)
    return config[key]
  end
})
