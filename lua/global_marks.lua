local M = {}
local api = vim.api
local fn = vim.fn

-- Config defaults
M.opts = {
	sign_name = "GlobalMarkSign",
	sign_text = "●",
	persist_file = fn.stdpath("data") .. "/global_marks.json",
	sign_priority = 10,
}

-- Internal state
-- marks: map from mark char -> {bufnr=, row=, col=, sign_id=}
M.marks = {}
M.next_sign_id = 1000
M._fallback_installed = false

-- Normalize single-character mark
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

-- Persist marks to disk (JSON)
function M.save()
	local ok, json = pcall(vim.fn.json_encode, M.marks)
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

-- Load persisted marks
function M.load()
	local fd = io.open(M.opts.persist_file, "r")
	if not fd then
		return
	end
	local content = fd:read("*a")
	fd:close()
	local ok, tbl = pcall(vim.fn.json_decode, content)
	if not ok or type(tbl) ~= "table" then
		return
	end
	M.marks = tbl
	-- ensure sign_ids exist and place signs for loaded buffers that are currently loaded
	for mark, info in pairs(M.marks) do
		if not info.sign_id then
			M.next_sign_id = M.next_sign_id + 1
			info.sign_id = M.next_sign_id
		end
		if api.nvim_buf_is_loaded(info.bufnr) and api.nvim_buf_is_valid(info.bufnr) and info.row and info.row > 0 then
			pcall(
				fn.sign_place,
				info.sign_id,
				"global_marks",
				M.opts.sign_name,
				info.bufnr,
				{ lnum = info.row, priority = M.opts.sign_priority }
			)
		end
	end
end

-- Define sign used in gutter
function M.define_sign()
	pcall(fn.sign_define, M.opts.sign_name, { text = M.opts.sign_text, texthl = "Comment" })
end

-- Place/record sign for a mark
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
	-- store
	M.marks[mark] = { buf = nil, bufnr = bufnr, row = row, col = col or 0, sign_id = id }
	-- place sign (pcall to avoid crashing)
	pcall(fn.sign_place, id, "global_marks", M.opts.sign_name, bufnr, { lnum = row, priority = M.opts.sign_priority })
end

-- Remove sign and internal record for a mark
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

-- Called when a mark is set (either via MarkSet autocmd or fallback mapping)
function M.on_mark_set(mark)
	mark = norm_mark(mark)
	if not mark then
		return
	end

	-- Try to get position: getpos("'x")
	local ok, pos = pcall(fn.getpos, "'" .. mark)
	if not ok or type(pos) ~= "table" then
		vim.notify("global_marks: getpos failed for mark '" .. tostring(mark) .. "'", vim.log.levels.DEBUG)
		return
	end

	-- pos is typically {bufnum, lnum, col, off}
	local bufnr = tonumber(pos[1]) or api.nvim_get_current_buf()
	local row = tonumber(pos[2]) or 0
	local col = tonumber(pos[3]) or 0

	-- Debug notification (low-verbosity)
	--vim.notify(("global_marks: on_mark_set mark=%s pos=%s buf=%s row=%s col=%s"):format(mark, vim.inspect(pos), tostring(bufnr), tostring(row), tostring(col)), vim.log.levels.DEBUG)

	-- If row==0 -> treat as deletion/invalid
	if row == 0 then
		M.remove_sign(mark)
		return
	end

	-- enforce buffer-local semantics for lowercase marks
	if mark:match("%l") then
		bufnr = api.nvim_get_current_buf()
	end

	-- place sign and record
	M.place_sign(mark, bufnr, row, col)
end

-- Jump to a registered mark (only if its buffer is visible in an open window)
function M.jump(mark)
	mark = norm_mark(mark)
	if not mark then
		return
	end
	local info = M.marks[mark]
	if not info then
		print("Mark '" .. mark .. "' not registered.")
		return
	end
	local target_buf = info.bufnr
	if not target_buf or not api.nvim_buf_is_valid(target_buf) then
		print("Target buffer for mark '" .. mark .. "' is not valid or not loaded.")
		return
	end
	for _, win in ipairs(api.nvim_list_wins()) do
		if api.nvim_win_get_buf(win) == target_buf then
			api.nvim_set_current_win(win)
			api.nvim_win_set_cursor(win, { info.row, info.col or 0 })
			return
		end
	end
	print("Buffer for mark '" .. mark .. "' is not open in any split. Open the buffer first to jump.")
end

-- Delete/unset a mark (remove sign + unset actual vim mark)
function M.delete(mark)
	mark = norm_mark(mark)
	if not mark then
		return
	end
	-- attempt to unset the actual vim mark
	pcall(fn.setpos, "'" .. mark, { 0, 0, 0, 0 })
	-- remove sign/internal
	M.remove_sign(mark)
end

-- Return list of marks as an array
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

-- UI: show marks (Telescope if available, else simple print)
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

	-- fallback: print simple list
	for i, v in ipairs(choices) do
		print(i .. ": " .. v)
	end
end

-- Attempt to create MarkSet via API; fallback to vimscript autocmd if necessary.
-- If both fail, install a safe fallback mapping for 'm' that preserves builtin behavior.
function M.setup_autocmds()
	M.define_sign()

	local aug = api.nvim_create_augroup("GlobalMarks", { clear = true })

	local function try_create_markset_api()
		local ok, _ = pcall(function()
			vim.api.nvim_create_autocmd("MarkSet", {
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
		-- Use a vimscript-style autocmd that calls back into our Lua function.
		local ok, _ = pcall(vim.cmd, "augroup GlobalMarks")
		ok, _ = pcall(vim.cmd, "autocmd! GlobalMarks")
		ok, _ = pcall(
			vim.cmd,
			"autocmd MarkSet * lua require('global_marks').on_mark_set(vim.v.event and vim.v.event.mark or '')"
		)
		ok, _ = pcall(vim.cmd, "augroup END")
		return ok
	end

	local created = try_create_markset_api()
	if not created then
		created = try_create_markset_cmd()
	end

	if not created then
		-- install fallback mapping only if safe to do so
		if not M._fallback_installed then
			vim.notify(
				"global_marks.nvim: 'MarkSet' unavailable, installing fallback mapping for `m`",
				vim.log.levels.WARN
			)
			local maps = vim.api.nvim_get_keymap("n")
			local m_mapped = false
			for _, mp in ipairs(maps) do
				if mp.lhs == "m" then
					m_mapped = true
					break
				end
			end
			if not m_mapped then
				vim.keymap.set("n", "m", function()
					local okc, ch = pcall(vim.fn.getcharstr)
					if not okc or not ch or ch == "" then
						return
					end
					vim.cmd("normal! m" .. ch)
					local loaded, gm = pcall(require, "global_marks")
					if loaded and gm and type(gm.on_mark_set) == "function" then
						pcall(gm.on_mark_set, ch)
					end
				end, { noremap = true, silent = true })
				M._fallback_installed = true
			else
				vim.notify("global_marks.nvim: 'm' already mapped; fallback not installed", vim.log.levels.WARN)
			end
		end
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

	-- When a buffer is read/loaded, re-place any saved signs for that buffer (helps persistence)
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
	M.define_sign()
	M.load()
	M.setup_autocmds()

	-- User commands
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
