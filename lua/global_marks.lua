local M = {}
local api = vim.api
local fn = vim.fn

-- Defaults
M.opts = {
	sign_prefix = "GlobalMarkSign", -- base sign name; actual sign will be sign_prefix .. "_" .. mark
	persist_file = fn.stdpath("data") .. "/global_marks.json",
	sign_priority = 10,
	use_theme_color = true, -- try to reuse colors from colorscheme
}

-- State
M.marks = {} -- map mark -> { bufnr=, row=, col=, sign_id=, sign_name= }
M.next_sign_id = 1000
M.defined_signs = {} -- mark -> true when sign/hil exists
M._fallback_installed = false

-- -----------------------
-- Helpers: mark normalization
-- -----------------------
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

-- -----------------------
-- Color utilities
-- -----------------------
-- Try to get a foreground color (hex) from common highlight groups in the current colorscheme.
local function get_theme_fg_hex()
	local candidates = {
		"Identifier",
		"Function",
		"Constant",
		"String",
		"Type",
		"Keyword",
		"Statement",
		"Number",
		"Special",
		"Boolean",
	}
	for _, name in ipairs(candidates) do
		local ok, hl = pcall(vim.api.nvim_get_hl_by_name, name, true)
		if ok and hl and hl.foreground then
			return string.format("#%06x", hl.foreground)
		end
	end
	return nil
end

-- fallback palette (nice for dark backgrounds)
local fallback_palette = {
	"#4FD6BE", -- teal
	"#6EE7B7",
	"#7AD3D0",
	"#C099FF", -- mauve
	"#D6B3FF",
	"#9AE6B4",
	"#64D3C8",
	"#B49DFF",
}

local function palette_for_mark(mark)
	local code = (type(mark) == "string" and string.byte(mark) or 0) or 0
	local idx = (code % #fallback_palette) + 1
	return fallback_palette[idx]
end

-- Create or update highlight group for a mark; returns highlight group name
local function ensure_highlight_for_mark(mark)
	local hl_name = "GlobalMarkHL_" .. mark
	local fg = nil
	if M.opts.use_theme_color then
		local ok, res = pcall(get_theme_fg_hex)
		if ok then
			fg = res
		end
	end
	if not fg then
		fg = palette_for_mark(mark)
	end
	-- Use nvim_set_hl (Neovim 0.7+). Wrap in pcall for safety.
	pcall(vim.api.nvim_set_hl, 0, hl_name, { fg = fg })
	return hl_name
end

-- -----------------------
-- Sign management
-- -----------------------
local function sign_name_for_mark(mark)
	return M.opts.sign_prefix .. "_" .. mark
end

local function define_sign_for_mark(mark)
	if M.defined_signs[mark] then
		return sign_name_for_mark(mark)
	end
	local sign_name = sign_name_for_mark(mark)
	local hl = ensure_highlight_for_mark(mark)
	-- define sign with the mark character as text and highlight as texthl
	pcall(fn.sign_define, sign_name, { text = mark, texthl = hl })
	M.defined_signs[mark] = true
	return sign_name
end

local function place_sign_id(id, sign_name, bufnr, row)
	pcall(fn.sign_place, id, "global_marks", sign_name, bufnr, { lnum = row, priority = M.opts.sign_priority })
end

-- Place / record a mark sign
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
	local sign_name = define_sign_for_mark(mark)
	M.marks[mark] = { bufnr = bufnr, row = row, col = col or 0, sign_id = id, sign_name = sign_name }
	place_sign_id(id, sign_name, bufnr, row)
end

-- Remove sign and internal record
function M.remove_sign(mark)
	local info = M.marks[mark]
	if not info then
		return
	end
	if info.sign_id and info.bufnr then
		pcall(fn.sign_unplace, "global_marks", { id = info.sign_id, buffer = info.bufnr })
	end
	M.marks[mark] = nil
	-- keep highlight/sign definition to avoid re-defining; that is cheap
end

-- -----------------------
-- Persistence
-- -----------------------
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
	-- ensure sign ids and place signs for loaded buffers
	for mark, info in pairs(M.marks) do
		if not info.sign_id then
			M.next_sign_id = M.next_sign_id + 1
			info.sign_id = M.next_sign_id
		end
		info.sign_name = sign_name_for_mark(mark)
		define_sign_for_mark(mark)
		if info.bufnr and api.nvim_buf_is_loaded(info.bufnr) and info.row and info.row > 0 then
			place_sign_id(info.sign_id, info.sign_name, info.bufnr, info.row)
		end
	end
end

-- -----------------------
-- Mark events handler
-- -----------------------
function M.on_mark_set(mark)
	mark = norm_mark(mark)
	if not mark then
		return
	end
	local ok, pos = pcall(fn.getpos, "'" .. mark)
	if not ok or type(pos) ~= "table" then
		return
	end
	local bufnr = tonumber(pos[1]) or api.nvim_get_current_buf()
	local row = tonumber(pos[2]) or 0
	local col = tonumber(pos[3]) or 0
	if row == 0 then
		M.remove_sign(mark)
		return
	end
	if mark:match("%l") then
		bufnr = api.nvim_get_current_buf()
	end
	M.place_sign(mark, bufnr, row, col)
end

-- -----------------------
-- Jump / delete / clear / list / UI
-- -----------------------
function M.jump(mark)
	mark = norm_mark(mark)
	if not mark then
		return
	end
	local info = M.marks[mark]
	if not info then
		print(("Mark '%s' not registered."):format(mark))
		return
	end
	local bufnr = info.bufnr
	if not bufnr or not api.nvim_buf_is_valid(bufnr) then
		print(("Target buffer for mark '%s' is not valid/loaded."):format(mark))
		return
	end
	for _, win in ipairs(api.nvim_list_wins()) do
		if api.nvim_win_get_buf(win) == bufnr then
			api.nvim_set_current_win(win)
			local col0 = math.max((info.col or 1) - 1, 0) -- nvim_win_set_cursor expects 0-index col
			api.nvim_win_set_cursor(win, { info.row, col0 })
			return
		end
	end
	print(("Buffer for mark '%s' is not open in any split. Open it to jump."):format(mark))
end

function M.delete(mark)
	mark = norm_mark(mark)
	if not mark then
		return
	end
	pcall(fn.setpos, "'" .. mark, { 0, 0, 0, 0 })
	M.remove_sign(mark)
end

-- Clear marks only in loaded/open buffers (as requested)
function M.clear()
	local to_clear = {}
	for m, info in pairs(M.marks) do
		if info.bufnr and api.nvim_buf_is_loaded(info.bufnr) then
			table.insert(to_clear, m)
		end
	end
	for _, m in ipairs(to_clear) do
		pcall(fn.setpos, "'" .. m, { 0, 0, 0, 0 })
		M.remove_sign(m)
	end
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

-- -----------------------
-- Robust MarkSet creation & fallback mapping
-- -----------------------
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
	local ok1 = pcall(vim.cmd, "augroup GlobalMarks")
	local ok2 = pcall(vim.cmd, "autocmd! GlobalMarks")
	local ok3 = pcall(
		vim.cmd,
		"autocmd MarkSet * lua require('global_marks').on_mark_set(vim.v.event and vim.v.event.mark or '')"
	)
	local ok4 = pcall(vim.cmd, "augroup END")
	return ok1 and ok2 and ok3 and ok4
end

local function install_fallback_mapping()
	local maps = api.nvim_get_keymap("n")
	for _, mp in ipairs(maps) do
		if mp.lhs == "m" then
			return false -- user mapping exists; do not override
		end
	end
	pcall(api.nvim_del_keymap, "n", "m")
	api.nvim_set_keymap("n", "m", "", {
		callback = function()
			local ok, ch = pcall(fn.getcharstr)
			if not ok or not ch or ch == "" then
				return
			end
			pcall(fn.execute, "normal! m" .. ch)
			local loaded, gm = pcall(require, "global_marks")
			if loaded and gm and type(gm.on_mark_set) == "function" then
				pcall(gm.on_mark_set, ch)
			end
		end,
		noremap = true,
		silent = true,
	})
	M._fallback_installed = true
	return true
end

local function remove_fallback_mapping()
	if M._fallback_installed then
		pcall(api.nvim_del_keymap, "n", "m")
		M._fallback_installed = false
	end
end

-- Module-load detection: try to create MarkSet now; if not possible install fallback mapping
do
	local aug_ok, aug = pcall(api.nvim_create_augroup, "GlobalMarksDetect", { clear = true })
	local created = false
	if aug_ok and aug then
		created = try_create_markset_api(aug)
		if not created then
			created = try_create_markset_cmd()
		end
		-- cleanup detection group
		pcall(vim.cmd, "augroup GlobalMarksDetect")
		pcall(vim.cmd, "autocmd!")
		pcall(vim.cmd, "augroup END")
	end
	if not created then
		install_fallback_mapping()
	end
end

-- -----------------------
-- Setup (call in lazy config or manually)
-- -----------------------
function M.setup(opts)
	if opts then
		M.opts = vim.tbl_extend("force", M.opts, opts)
	end

	-- load persisted marks & define signs for those marks
	M.load()

	-- create real autocmd group and try to install MarkSet; if succeed, remove fallback
	local aug = api.nvim_create_augroup("GlobalMarks", { clear = true })
	local created = try_create_markset_api(aug)
	if not created then
		created = try_create_markset_cmd()
	end
	if created then
		remove_fallback_mapping()
	end

	-- Save marks on exit
	api.nvim_create_autocmd({ "VimLeavePre", "QuitPre" }, {
		group = aug,
		callback = function()
			M.save()
		end,
	})

	-- Remove signs when buffers are wiped/deleted
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

	-- Re-place persisted signs when buffer loaded/entered
	api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
		group = aug,
		callback = function(ev)
			local bufnr = tonumber(ev.buf) or tonumber(ev.bufnr)
			if not bufnr or bufnr == 0 then
				return
			end
			for m, info in pairs(M.marks) do
				if info.bufnr == bufnr and info.row and info.row > 0 and info.sign_id then
					place_sign_id(info.sign_id, info.sign_name or sign_name_for_mark(m), bufnr, info.row)
				end
			end
		end,
	})

	-- Recompute per-mark highlights when colorscheme changes
	api.nvim_create_autocmd("ColorScheme", {
		group = aug,
		callback = function()
			for mark, _ in pairs(M.defined_signs) do
				-- recompute highlight and redefine sign to pick up new texthl
				local hl = ensure_highlight_for_mark(mark)
				local sign = sign_name_for_mark(mark)
				pcall(fn.sign_define, sign, { text = mark, texthl = hl })
			end
		end,
	})

	-- Commands
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
	api.nvim_create_user_command("GMarkClear", function()
		M.clear()
	end, {})
end

return M
