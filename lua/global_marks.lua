local M = {}
local api = vim.api
local fn = vim.fn

-- config defaults
M.opts = {
	sign_name = "GlobalMarkSign",
	sign_text = "●",
	persist_file = fn.stdpath("data") .. "/global_marks.json",
	sign_priority = 10,
}

-- state
M.marks = {} -- map mark -> {bufnr=, row=, col=, sign_id=}
M.next_sign_id = 1000
M._fallback_installed = false
M._fallback_source = "module_load" -- reason we installed fallback

-- helpers
local function norm_mark(mark)
	if not mark then
		return nil
	end
	local s = tostring(mark)
	if s == "" then
		return nil
	end
	return s:sub(1, 1)
end

function M.define_sign()
	pcall(fn.sign_define, M.opts.sign_name, { text = M.opts.sign_text, texthl = "Comment" })
end

local function place_sign_id(id, bufnr, row)
	pcall(fn.sign_place, id, "global_marks", M.opts.sign_name, bufnr, { lnum = row, priority = M.opts.sign_priority })
end

function M.place_sign(mark, bufnr, row, col)
	if not mark or not bufnr or not row then
		return
	end
	local id = nil
	if M.marks[mark] and M.marks[mark].sign_id then
		id = M.marks[mark].sign_id
	else
		M.next_sign_id = M.next_sign_id + 1
		id = M.next_sign_id
	end
	M.marks[mark] = { bufnr = bufnr, row = row, col = col or 0, sign_id = id }
	place_sign_id(id, bufnr, row)
end

function M.remove_sign(mark)
	local info = M.marks[mark]
	if not info then
		return
	end
	if info.sign_id and info.bufnr then
		pcall(fn.sign_unplace, "global_marks", { id = info.sign_id, buffer = info.bufnr })
	end
	M.marks[mark] = nil
end

-- persistence
function M.save()
	local ok, json = pcall(fn.json_encode, M.marks)
	if not ok or not json then
		return
	end
	local fd, err = io.open(M.opts.persist_file, "w")
	if not fd then
		vim.notify("global_marks: cannot open persist file: " .. tostring(err or "<err>"), vim.log.levels.WARN)
		return
	end
	fd:write(json)
	fd:close()
end

function M.load()
	local fd = io.open(M.opts.persist_file, "r")
	if not fd then
		return
	end
	local content = fd:read("*a")
	fd:close()
	local ok, dec = pcall(fn.json_decode, content)
	if not ok or type(dec) ~= "table" then
		return
	end
	M.marks = dec
	-- ensure sign ids
	for mark, info in pairs(M.marks) do
		if not info.sign_id then
			M.next_sign_id = M.next_sign_id + 1
			info.sign_id = M.next_sign_id
		end
		if info.bufnr and api.nvim_buf_is_loaded(info.bufnr) and info.row and info.row > 0 then
			place_sign_id(info.sign_id, info.bufnr, info.row)
		end
	end
end

-- mark handling: called by MarkSet autocmd or fallback mapping
function M.on_mark_set(mark)
	mark = norm_mark(mark)
	if not mark then
		return
	end

	-- getpos("'x") -> {bufnum, lnum, col, off}
	local ok, pos = pcall(fn.getpos, "'" .. mark)
	if not ok or type(pos) ~= "table" then
		-- if getpos fails, abort quietly
		return
	end

	local bufnr = tonumber(pos[1]) or api.nvim_get_current_buf()
	local row = tonumber(pos[2]) or 0
	local col = tonumber(pos[3]) or 0

	-- treat row==0 as a deletion/unset
	if row == 0 then
		M.remove_sign(mark)
		return
	end

	-- buffer-local semantics for lowercase
	if mark:match("%l") then
		bufnr = api.nvim_get_current_buf()
	end

	M.place_sign(mark, bufnr, row, col)
end

-- Jump: only if mark's buffer is visible in an open window
function M.jump(mark)
	mark = norm_mark(mark)
	if not mark then
		return
	end
	local info = M.marks[mark]
	if not info then
		print(("Mark '%s' not registered"):format(mark))
		return
	end
	local bufnr = info.bufnr
	if not bufnr or not api.nvim_buf_is_valid(bufnr) then
		print(("Target buffer for mark '%s' is not valid/loaded"):format(mark))
		return
	end
	for _, win in ipairs(api.nvim_list_wins()) do
		if api.nvim_win_get_buf(win) == bufnr then
			api.nvim_set_current_win(win)
			api.nvim_win_set_cursor(win, { info.row, info.col or 0 })
			return
		end
	end
	print(("Buffer for mark '%s' is not open in any split (open it to jump)"):format(mark))
end

function M.delete(mark)
	mark = norm_mark(mark)
	if not mark then
		return
	end
	pcall(fn.setpos, "'" .. mark, { 0, 0, 0, 0 })
	M.remove_sign(mark)
end

function M.list()
	local out = {}
	for m, info in pairs(M.marks) do
		table.insert(out, { mark = m, bufnr = info.bufnr, row = info.row })
	end
	table.sort(out, function(a, b)
		return a.mark < b.mark
	end)
	return out
end

function M.show_list()
	local marks = M.list()
	if vim.tbl_isempty(marks) then
		print("No global marks registered.")
		return
	end
	local choices = {}
	for _, v in ipairs(marks) do
		local name = api.nvim_buf_get_name(v.bufnr) or ""
		if name == "" then
			name = "[No Name]"
		end
		table.insert(choices, string.format("%s — %s:%d", v.mark, name, v.row or 0))
	end

	local ok, _ = pcall(require, "telescope")
	if ok then
		local pickers = require("telescope.pickers")
		local finders = require("telescope.finders")
		local conf = require("telescope.config").values
		local actions = require("telescope.actions")
		local action_state = require("telescope.actions.state")
		pickers
			.new({}, {
				prompt_title = "Global Marks",
				finder = finders.new_table({ results = choices }),
				sorter = conf.generic_sorter({}),
				attach_mappings = function(prompt_bufnr, map)
					actions.select_default:replace(function()
						local sel = action_state.get_selected_entry()
						local idx = sel.index
						local mark = marks[idx].mark
						M.jump(mark)
						actions.close(prompt_bufnr)
					end)
					return true
				end,
			})
			:find()
		return
	end

	for i, v in ipairs(choices) do
		print(i .. ": " .. v)
	end
end

-- Try to create MarkSet autocmd via API, or via vimscript cmd
local function try_create_markset_api(aug)
	local ok = pcall(function()
		api.nvim_create_autocmd("MarkSet", {
			group = aug,
			pattern = "*",
			callback = function(ev)
				local mark = ev and ev.mark or (vim.v and vim.v.event and vim.v.event.mark)
				if not mark then
					return
				end
				M.on_mark_set(mark)
			end,
		})
	end)
	return ok
end

local function try_create_markset_cmd()
	-- safer vimscript-style autocmd
	local ok1 = pcall(vim.cmd, "augroup GlobalMarks")
	local ok2 = pcall(vim.cmd, "autocmd! GlobalMarks")
	local ok3 = pcall(
		vim.cmd,
		"autocmd MarkSet * lua require('global_marks').on_mark_set(vim.v.event and vim.v.event.mark or '')"
	)
	local ok4 = pcall(vim.cmd, "augroup END")
	return ok1 and ok2 and ok3 and ok4
end

-- fallback mapping management
local function install_fallback_mapping(reason)
	-- don't override if user already mapped 'm'
	local maps = api.nvim_get_keymap("n")
	for _, mp in ipairs(maps) do
		if mp.lhs == "m" then
			-- Do not install fallback; user mapping exists
			return false
		end
	end
	-- remove any previous mapping we may have left
	pcall(api.nvim_del_keymap, "n", "m")
	api.nvim_set_keymap("n", "m", "", {
		callback = function()
			local ok, ch = pcall(fn.getcharstr)
			if not ok or not ch or ch == "" then
				return
			end
			pcall(fn.execute, "normal! m" .. ch) -- use execute to be safe
			local loaded, gm = pcall(require, "global_marks")
			if loaded and gm and type(gm.on_mark_set) == "function" then
				pcall(gm.on_mark_set, ch)
			end
		end,
		noremap = true,
		silent = true,
	})
	M._fallback_installed = true
	M._fallback_source = reason or "module_load"
	return true
end

local function remove_fallback_mapping()
	if M._fallback_installed then
		pcall(api.nvim_del_keymap, "n", "m")
		M._fallback_installed = false
		M._fallback_source = nil
	end
end

-- Attempt to create MarkSet immediately; if not possible, install fallback mapping now.
-- Doing this at module-load time ensures marks work even before lazy loads setup().
do
	M.define_sign()
	-- create a transient augroup for detection
	local aug_ok, aug = pcall(api.nvim_create_augroup, "GlobalMarksDetect", { clear = true })
	if not aug_ok then
		aug = nil
	end

	local created = false
	if aug then
		created = try_create_markset_api(aug)
		if not created then
			created = try_create_markset_cmd()
		end
		-- clean up detection augroup if it exists; real setup will create the final one
		pcall(vim.cmd, "augroup GlobalMarksDetect")
		pcall(vim.cmd, "autocmd!")
		pcall(vim.cmd, "augroup END")
	end

	if not created then
		-- install safe fallback mapping immediately
		install_fallback_mapping("module_load")
	end
end

-- setup autocmds and commands (called in setup)
function M.setup_autocmds()
	M.define_sign()
	local aug = api.nvim_create_augroup("GlobalMarks", { clear = true })

	-- attempt to create real MarkSet autocmd (api then cmd)
	local created = try_create_markset_api(aug)
	if not created then
		created = try_create_markset_cmd()
	end

	-- if we created MarkSet now and had fallback mapping earlier, remove fallback
	if created and M._fallback_installed then
		remove_fallback_mapping()
	end

	-- Save marks on exit
	api.nvim_create_autocmd({ "VimLeavePre", "QuitPre" }, {
		group = aug,
		callback = function()
			M.save()
		end,
	})

	-- When buffers are wiped/unloaded, remove signs for marks whose buffer is gone
	api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
		group = aug,
		callback = function(ev)
			local bufnr = tonumber(ev.buf) or tonumber(ev.bufnr) or api.nvim_get_current_buf()
			for m, info in pairs(M.marks) do
				if info.bufnr == bufnr then
					M.remove_sign(m)
				end
			end
		end,
	})

	-- When buffers are read/entered, re-place persisted signs for that buffer
	api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
		group = aug,
		callback = function(ev)
			local bufnr = tonumber(ev.buf) or tonumber(ev.bufnr)
			if not bufnr or bufnr == 0 then
				return
			end
			for m, info in pairs(M.marks) do
				if info.bufnr == bufnr and info.row and info.row > 0 and info.sign_id then
					pcall(
						fn.sign_place,
						info.sign_id,
						"global_marks",
						M.opts.sign_name,
						bufnr,
						{ lnum = info.row, priority = M.opts.sign_priority }
					)
				end
			end
		end,
	})
end

-- Public setup
function M.setup(opts)
	if opts then
		M.opts = vim.tbl_extend("force", M.opts, opts)
	end
	-- load persisted marks and try to create autocmds; if MarkSet is available we will remove fallback.
	M.load()
	M.setup_autocmds()

	-- user commands
	api.nvim_create_user_command("GMarksList", function()
		M.show_list()
	end, {})
	api.nvim_create_user_command("GMarkJump", function(opts)
		local arg = tostring(opts.args or "")
		local m = arg:sub(1, 1)
		if m == "" then
			print("Usage: GMarkJump {mark}")
			return
		end
		M.jump(m)
	end, { nargs = 1 })
	api.nvim_create_user_command("GMarkDel", function(opts)
		local arg = tostring(opts.args or "")
		local m = arg:sub(1, 1)
		if m == "" then
			print("Usage: GMarkDel {mark}")
			return
		end
		M.delete(m)
	end, { nargs = 1 })
end

return M
