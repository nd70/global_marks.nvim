local M = {}
local api = vim.api
local fn = vim.fn

-- -----------------------
-- Defaults & state
-- -----------------------
M.opts = {
	sign_prefix = "GlobalMarkSign",
	persist_file = fn.stdpath("data") .. "/global_marks.json",
	sign_priority = 10,
	use_theme_color = true,
}

-- M.marks structure:
--  Uppercase marks: M.marks['A'] = { bufnr=..., row=..., col=..., sign_id=..., sign_name=... }
--  Lowercase marks: M.marks['a'] = { [tostring(bufnr)] = { bufnr=..., row=..., col=..., sign_id=..., sign_name=... }, ... }
M.marks = {}
M.next_sign_id = 1000
M.defined_signs = {} -- mark -> true (sign/hl defined)
M._fallback_installed = false
M._palette = nil

-- -----------------------
-- Small helpers
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

local function is_lower_mark(mark)
	return mark:match("%l") ~= nil
end

local function sign_name_for_mark(mark)
	return (M.opts.sign_prefix or "GlobalMarkSign") .. "_" .. mark
end

-- -----------------------
-- Color sampling & palette logic (theme-aware)
-- -----------------------
local sample_hl_groups = {
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
	"Label",
	"Title",
	"Todo",
	"Comment",
	"Conditional",
	"Repeat",
	"Operator",
	"Exception",
	"PreProc",
	"Include",
	"Macro",
	"Delimiter",
	"Tag",
}
local fallback_palette = {
	"#4FD6BE",
	"#6EE7B7",
	"#7AD3D0",
	"#C099FF",
	"#D6B3FF",
	"#9AE6B4",
	"#64D3C8",
	"#B49DFF",
	"#6CD3D6",
	"#5BD0C8",
	"#8FD1B3",
	"#D0A7FF",
}

local function collect_theme_colors()
	local colors = {}
	local seen = {}
	for _, name in ipairs(sample_hl_groups) do
		local ok, hl = pcall(vim.api.nvim_get_hl_by_name, name, true)
		if ok and hl and hl.foreground then
			local hex = string.format("#%06x", hl.foreground)
			if not seen[hex] then
				table.insert(colors, hex)
				seen[hex] = true
			end
		end
	end
	local extras = { "@function", "@keyword", "@variable", "@parameter", "@method", "@property", "@constant" }
	for _, name in ipairs(extras) do
		local ok, hl = pcall(vim.api.nvim_get_hl_by_name, name, true)
		if ok and hl and hl.foreground then
			local hex = string.format("#%06x", hl.foreground)
			if not seen[hex] then
				table.insert(colors, hex)
				seen[hex] = true
			end
		end
	end
	if #colors == 0 then
		for _, c in ipairs(fallback_palette) do
			table.insert(colors, c)
		end
	end
	return colors
end

local function ensure_palette()
	if M._palette and #M._palette > 0 then
		return M._palette
	end
	local pal = {}
	if M.opts.use_theme_color ~= false then
		local ok, colors = pcall(collect_theme_colors)
		if ok and colors and #colors > 0 then
			pal = colors
		end
	end
	-- pad with fallback colors so we always have many choices
	local i = 1
	while #pal < #fallback_palette do
		table.insert(pal, fallback_palette[i])
		i = i + 1
		if i > #fallback_palette then
			i = 1
		end
	end
	M._palette = pal
	return pal
end

local function color_for_mark(mark)
	local pal = ensure_palette()
	local code = (type(mark) == "string" and string.byte(mark) or 0) or 0
	local idx = (code % #pal) + 1
	return pal[idx]
end

-- expose rebuild function for calling externally
function M.rebuild_palette_and_hls()
	M._palette = nil
	ensure_palette()
	for mark, _ in pairs(M.defined_signs) do
		local hl = "GlobalMarkHL_" .. mark
		local fg = color_for_mark(mark)
		pcall(vim.api.nvim_set_hl, 0, hl, { fg = fg })
		local sign = sign_name_for_mark(mark)
		pcall(fn.sign_define, sign, { text = mark, texthl = hl })
	end
end

-- -----------------------
-- Highlight & sign creation
-- -----------------------
local function ensure_highlight_for_mark(mark)
	local hl_name = "GlobalMarkHL_" .. mark
	local fg = color_for_mark(mark)
	-- set both guifg and ctermfg fallback for broader compatibility
	pcall(vim.api.nvim_set_hl, 0, hl_name, { fg = fg })
	-- cterm fallback heuristic: choose 6(cyan) or 13(magenta) based on rgb
	local function hex_to_rgb(hex)
		hex = hex:gsub("#", "")
		return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
	end
	local function choose_cterm(hex)
		local r, g, b = hex_to_rgb(hex)
		if (g + b) > (r * 1.1) then
			return 6
		else
			return 13
		end
	end
	local ok, _ = pcall(vim.cmd, string.format("highlight %s ctermfg=%d guifg=%s", hl_name, choose_cterm(fg), fg))
	return hl_name
end

local function define_sign_for_mark(mark)
	-- always ensure highlight group exists first
	local sign_name = sign_name_for_mark(mark)
	local hl = ensure_highlight_for_mark(mark)

	-- protect sign_define (re-define idempotently)
	pcall(function()
		-- sign_define will silently overwrite if already defined, that's fine
		vim.fn.sign_define(sign_name, { text = mark, texthl = hl })
	end)

	M.defined_signs[mark] = true
	return sign_name
end

local function place_sign_id(id, sign_name, bufnr, row)
	-- ensure sign is defined before placing (defensive)
	pcall(function()
		if not sign_name then
			return
		end
		if not vim.tbl_isempty(vim.fn.sign_getdefined(sign_name)) then
			-- sign already defined (ok)
		else
			-- try to define a minimal sign if somehow missing
			pcall(vim.fn.sign_define, sign_name, { text = sign_name:sub(-1), texthl = sign_name })
		end
	end)

	-- place sign
	pcall(vim.fn.sign_place, id, "global_marks", sign_name, bufnr, { lnum = row, priority = M.opts.sign_priority })

	-- small, cheap redraw so sign renders immediately
	pcall(vim.cmd, "redraw")
end

-- -----------------------
-- Persistence (save/load)
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

	-- normalize older single-info forms for lowercase marks into per-buf tables
	for mark, info in pairs(M.marks) do
		if is_lower_mark(mark) then
			if info and info.bufnr and info.row then
				-- old single entry -> convert
				local newt = {}
				newt[tostring(info.bufnr)] = info
				info.sign_name = sign_name_for_mark(mark)
				if not info.sign_id then
					M.next_sign_id = M.next_sign_id + 1
					info.sign_id = M.next_sign_id
				end
				M.marks[mark] = newt
			else
				-- ensure nested entries have sign_id and sign_name
				for k, v in pairs(info or {}) do
					if v and not v.sign_id then
						M.next_sign_id = M.next_sign_id + 1
						v.sign_id = M.next_sign_id
					end
					if v then
						v.sign_name = sign_name_for_mark(mark)
					end
				end
			end
		else
			-- uppercase: ensure sign_id and sign_name exist if info present
			if info and info.bufnr then
				if not info.sign_id then
					M.next_sign_id = M.next_sign_id + 1
					info.sign_id = M.next_sign_id
				end
				info.sign_name = sign_name_for_mark(mark)
			end
		end
	end

	-- place signs for currently-loaded buffers
	for mark, info in pairs(M.marks) do
		if is_lower_mark(mark) then
			for bufnr_str, ent in pairs(info) do
				local bufnr = tonumber(bufnr_str) or tonumber(ent and ent.bufnr)
				if ent and ent.sign_id then
					ent.bufnr = bufnr
					ent.sign_name = sign_name_for_mark(mark)
					define_sign_for_mark(mark)
					if api.nvim_buf_is_loaded(bufnr) and ent.row and ent.row > 0 then
						place_sign_id(ent.sign_id, ent.sign_name, bufnr, ent.row)
					end
				end
			end
		else
			if info and info.sign_id then
				define_sign_for_mark(mark)
				if api.nvim_buf_is_loaded(info.bufnr) and info.row and info.row > 0 then
					place_sign_id(info.sign_id, info.sign_name, info.bufnr, info.row)
				end
			end
		end
	end
end

-- -----------------------
-- Mark placement/removal & event handler
-- -----------------------
local function ensure_lower_table(mark)
	if not M.marks[mark] or type(M.marks[mark]) ~= "table" then
		M.marks[mark] = {}
	end
	return M.marks[mark]
end

function M.place_sign(mark, bufnr, row, col)
	if not mark or not bufnr or not row then
		return
	end

	-- ensure sign & hl exist first (important for immediate rendering)
	local sign_name = define_sign_for_mark(mark)

	if is_lower_mark(mark) then
		local tbl = ensure_lower_table(mark)
		local key = tostring(bufnr)
		local ent = tbl[key]
		local id
		if ent and ent.sign_id then
			id = ent.sign_id
		else
			M.next_sign_id = M.next_sign_id + 1
			id = M.next_sign_id
		end
		tbl[key] = { bufnr = bufnr, row = row, col = col or 0, sign_id = id, sign_name = sign_name }
		place_sign_id(id, sign_name, bufnr, row)
	else
		local id = nil
		if M.marks[mark] and M.marks[mark].sign_id then
			id = M.marks[mark].sign_id
		else
			M.next_sign_id = M.next_sign_id + 1
			id = M.next_sign_id
		end
		M.marks[mark] = { bufnr = bufnr, row = row, col = col or 0, sign_id = id, sign_name = sign_name }
		place_sign_id(id, sign_name, bufnr, row)
	end
end

function M.remove_sign(mark, bufnr_opt)
	if not mark then
		return
	end
	if is_lower_mark(mark) then
		local tbl = M.marks[mark]
		if not tbl or type(tbl) ~= "table" then
			return
		end
		local bufnr_key = bufnr_opt and tostring(bufnr_opt) or tostring(api.nvim_get_current_buf())
		local ent = tbl[bufnr_key]
		if not ent then
			return
		end
		if ent.sign_id and ent.bufnr then
			pcall(fn.sign_unplace, "global_marks", { id = ent.sign_id, buffer = ent.bufnr })
		end
		tbl[bufnr_key] = nil
		local empty = true
		for k, _ in pairs(tbl) do
			empty = false
			break
		end
		if empty then
			M.marks[mark] = nil
		end
	else
		local info = M.marks[mark]
		if not info then
			return
		end
		if info.sign_id and info.bufnr then
			pcall(fn.sign_unplace, "global_marks", { id = info.sign_id, buffer = info.bufnr })
		end
		M.marks[mark] = nil
	end
end

function M.on_mark_set(mark)
	mark = norm_mark(mark)
	if not mark then
		return
	end

	local ok, pos = pcall(fn.getpos, "'" .. mark)
	local bufnr = nil
	local row = nil
	local col = nil
	if ok and type(pos) == "table" then
		bufnr = tonumber(pos[1]) or nil
		row = tonumber(pos[2]) or 0
		col = tonumber(pos[3]) or 0
	end

	if is_lower_mark(mark) then
		local cur = api.nvim_get_current_buf()
		if not bufnr or bufnr == 0 then
			bufnr = cur
		end
		if not row or row == 0 then
			-- deletion
			M.remove_sign(mark, bufnr)
			return
		end
		M.place_sign(mark, bufnr, row, col)
		return
	else
		if not bufnr or bufnr == 0 or not row or row == 0 then
			M.remove_sign(mark)
			return
		end
		M.place_sign(mark, bufnr, row, col)
	end
end

-- -----------------------
-- Jump logic (getpos preferred, then fallback to stored info)
-- -----------------------
function M.jump(mark)
	mark = norm_mark(mark)
	if not mark then
		return
	end

	-- try authoritative getpos
	local ok, pos = pcall(fn.getpos, "'" .. mark)
	local bufnr, row, col = nil, nil, nil
	if ok and type(pos) == "table" then
		bufnr = tonumber(pos[1]) or 0
		row = tonumber(pos[2]) or 0
		col = tonumber(pos[3]) or 0
	end

	local used_fallback = false

	-- If getpos invalid, use stored info (for lowercase prefer current buffer's entry)
	if not bufnr or bufnr == 0 or row == 0 then
		if is_lower_mark(mark) then
			local tbl = M.marks[mark]
			local cur = api.nvim_get_current_buf()
			if tbl and tbl[tostring(cur)] then
				local ent = tbl[tostring(cur)]
				bufnr, row, col = ent.bufnr, ent.row, ent.col
				used_fallback = true
			else
				-- find any loaded buffer that has this mark (prefer visible buffer)
				if tbl then
					for k, v in pairs(tbl) do
						local nb = tonumber(k) or (v and v.bufnr)
						if nb and api.nvim_buf_is_valid(nb) then
							bufnr, row, col = v.bufnr, v.row, v.col
							used_fallback = true
							break
						end
					end
				end
			end
		else
			local info = M.marks[mark]
			if info and info.bufnr then
				bufnr, row, col = info.bufnr, info.row, info.col
				used_fallback = true
			end
		end

		if not bufnr or bufnr == 0 or row == 0 then
			print(("Mark '%s' is not set or has no valid position"):format(mark))
			return
		end
	end

	if not api.nvim_buf_is_valid(bufnr) then
		print(("Buffer for mark '%s' is not valid"):format(mark))
		return
	end

	-- locate a window showing the buffer
	for _, win in ipairs(api.nvim_list_wins()) do
		if api.nvim_win_get_buf(win) == bufnr then
			api.nvim_set_current_win(win)
			local rown = tonumber(row) or 1
			if rown < 1 then
				rown = 1
			end

			local line = api.nvim_buf_get_lines(bufnr, rown - 1, rown, true)[1] or ""
			local byte_len = #line

			local col_use = tonumber(col) or 0
			if col_use and col_use >= 1 and col_use <= byte_len then
				local col0 = math.max(col_use - 1, 0)
				api.nvim_win_set_cursor(win, { rown, col0 })
				if used_fallback then
					vim.notify(
						("global_marks: jump to '%s' used stored info (fallback)"):format(mark),
						vim.log.levels.DEBUG
					)
				end
				return
			end

			-- search occurrences on line and pick nearest to col_use
			local occurrences = {}
			local s = 1
			while true do
				local start_pos = string.find(line, mark, s, true)
				if not start_pos then
					break
				end
				table.insert(occurrences, start_pos)
				s = start_pos + 1
			end

			if #occurrences == 0 then
				local col0 = math.min(byte_len, math.max((col_use or 1) - 1, 0))
				api.nvim_win_set_cursor(win, { rown, col0 })
				if used_fallback then
					vim.notify(
						("global_marks: jump to '%s' used stored info but mark char not found"):format(mark),
						vim.log.levels.DEBUG
					)
				end
				return
			end

			local stored_col1 = math.max((col_use or occurrences[1] or 1), 1)
			local best = occurrences[1]
			local best_dist = math.abs(occurrences[1] - stored_col1)
			for _, posv in ipairs(occurrences) do
				local dist = math.abs(posv - stored_col1)
				if (posv <= stored_col1 and dist <= best_dist) or (posv > stored_col1 and dist < best_dist) then
					best = posv
					best_dist = dist
				end
			end

			local col0 = math.max(best - 1, 0)
			api.nvim_win_set_cursor(win, { rown, col0 })
			if used_fallback then
				vim.notify(
					("global_marks: jump to '%s' used stored info (found closest occurrence)"):format(mark),
					vim.log.levels.DEBUG
				)
			end
			return
		end
	end

	print(("Buffer for mark '%s' is not open in any split. Open it to jump."):format(mark))
end

-- -----------------------
-- Delete, clear, list, UI (Telescope)
-- -----------------------
function M.delete(mark)
	mark = norm_mark(mark)
	if not mark then
		return
	end
	if is_lower_mark(mark) then
		local bufnr = api.nvim_get_current_buf()
		pcall(fn.setpos, "'" .. mark, { 0, 0, 0, 0 })
		M.remove_sign(mark, bufnr)
	else
		pcall(fn.setpos, "'" .. mark, { 0, 0, 0, 0 })
		M.remove_sign(mark)
	end
end

function M.clear()
	local to_remove = {}
	for mark, info in pairs(M.marks) do
		if is_lower_mark(mark) then
			for bufnr_str, ent in pairs(info) do
				local bufnr = tonumber(bufnr_str) or (ent and ent.bufnr)
				if bufnr and api.nvim_buf_is_loaded(bufnr) then
					table.insert(to_remove, { mark = mark, bufnr = bufnr })
				end
			end
		else
			if info and info.bufnr and api.nvim_buf_is_loaded(info.bufnr) then
				table.insert(to_remove, { mark = mark, bufnr = info.bufnr })
			end
		end
	end
	for _, item in ipairs(to_remove) do
		pcall(fn.setpos, "'" .. item.mark, { 0, 0, 0, 0 })
		if is_lower_mark(item.mark) then
			M.remove_sign(item.mark, item.bufnr)
		else
			M.remove_sign(item.mark)
		end
	end
end

function M.list()
	local out = {}
	for mark, info in pairs(M.marks) do
		if is_lower_mark(mark) then
			for bufnr_str, ent in pairs(info) do
				local bufnr = tonumber(bufnr_str) or (ent and ent.bufnr)
				table.insert(out, { mark = mark, bufnr = bufnr, row = ent and ent.row })
			end
		else
			if info and info.bufnr then
				table.insert(out, { mark = mark, bufnr = info.bufnr, row = info.row })
			end
		end
	end
	table.sort(out, function(a, b)
		if a.mark == b.mark then
			if a.bufnr == b.bufnr then
				return (a.row or 0) < (b.row or 0)
			end
			return (a.bufnr or 0) < (b.bufnr or 0)
		end
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
					-- capture prompt_bufnr via closure (robust pattern)
					actions.select_default:replace(function()
						local sel = action_state.get_selected_entry()
						if not sel then
							actions.close(prompt_bufnr)
							return
						end
						local idx = sel.index
						local mark = marks[idx].mark
						local bufnr = marks[idx].bufnr
						actions.close(prompt_bufnr)

						-- If lowercase entry was explicitly selected (with bufnr), prefer direct stored jump
						if is_lower_mark(mark) then
							local stored = (M.marks[mark] and M.marks[mark][tostring(bufnr)]) or nil
							if stored and stored.bufnr then
								for _, win in ipairs(api.nvim_list_wins()) do
									if api.nvim_win_get_buf(win) == stored.bufnr then
										api.nvim_set_current_win(win)
										local col0 = math.max((stored.col or 1) - 1, 0)
										api.nvim_win_set_cursor(win, { stored.row, col0 })
										return
									end
								end
							end
						end

						-- fallback to robust jump (getpos() preferred, then stored)
						pcall(M.jump, mark)
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
-- Robust MarkSet creation & fallback mapping for `m`
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
			return false
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

-- module-load detection: try to create MarkSet now; otherwise install fallback mapping so `m{char}` works immediately
do
	local aug_ok, aug = pcall(api.nvim_create_augroup, "GlobalMarksDetect", { clear = true })
	local created = false
	if aug_ok and aug then
		created = try_create_markset_api(aug)
		if not created then
			created = try_create_markset_cmd()
		end
		pcall(vim.cmd, "augroup GlobalMarksDetect")
		pcall(vim.cmd, "autocmd!")
		pcall(vim.cmd, "augroup END")
	end
	if not created then
		install_fallback_mapping()
	end
end

-- -----------------------
-- Setup: create autocmds, commands, and color scheme handle
-- -----------------------
function M.setup(opts)
	if opts then
		M.opts = vim.tbl_extend("force", M.opts, opts)
	end

	M.load()

	local aug = api.nvim_create_augroup("GlobalMarks", { clear = true })
	local created = try_create_markset_api(aug)
	if not created then
		created = try_create_markset_cmd()
	end
	if created then
		remove_fallback_mapping()
	end

	api.nvim_create_autocmd({ "VimLeavePre", "QuitPre" }, {
		group = aug,
		callback = function()
			M.save()
		end,
	})

	api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
		group = aug,
		callback = function(ev)
			local bufnr = tonumber(ev.buf) or tonumber(ev.bufnr) or api.nvim_get_current_buf()
			for m, info in pairs(M.marks) do
				if is_lower_mark(m) then
					if info and info[tostring(bufnr)] then
						M.remove_sign(m, bufnr)
					end
				else
					if info and info.bufnr == bufnr then
						M.remove_sign(m)
					end
				end
			end
		end,
	})

	api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
		group = aug,
		callback = function(ev)
			local bufnr = tonumber(ev.buf) or tonumber(ev.bufnr)
			if not bufnr or bufnr == 0 then
				return
			end

			-- re-place any persisted signs for this buffer
			for m, info in pairs(M.marks) do
				if is_lower_mark(m) then
					for k, ent in pairs(info) do
						local nb = tonumber(k) or (ent and ent.bufnr)
						if nb == bufnr and ent.sign_id and ent.row and ent.row > 0 then
							-- ensure sign exists, then place
							local sign_name = define_sign_for_mark(m)
							place_sign_id(ent.sign_id, sign_name, nb, ent.row)
						end
					end
				else
					if info and info.bufnr == bufnr and info.sign_id and info.row and info.row > 0 then
						local sign_name = define_sign_for_mark(m)
						place_sign_id(info.sign_id, sign_name, bufnr, info.row)
					end
				end
			end

			pcall(vim.cmd, "redraw")
		end,
	})

	-- Rebuild palette & highlight groups on colorscheme changes
	api.nvim_create_autocmd("ColorScheme", {
		group = aug,
		callback = function()
			M.rebuild_palette_and_hls()
		end,
	})

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
	api.nvim_create_user_command("GMarkClear", function()
		M.clear()
	end, {})
end

-- expose API
M.place_sign_id = place_sign_id
M.define_sign_for_mark = define_sign_for_mark
M.ensure_highlight_for_mark = ensure_highlight_for_mark

return M
