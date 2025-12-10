local M = {}
local api = vim.api
local fn = vim.fn

-- Config
M.opts = {
	sign_name = "GlobalMarkSign",
	sign_text = "●",
	persist_file = fn.stdpath("data") .. "/global_marks.json",
}

-- Internal state: maps mark (single-letter string) -> {bufnr=, row=, col=, sign_id=}
M.marks = {}
M.next_sign_id = 1000

-- Utility: normalize mark name (single char)
local function norm_mark(mark)
	if not mark or #mark == 0 then
		return nil
	end
	return tostring(mark):sub(1, 1)
end

-- Save marks to disk (simple JSON)
function M.save()
	local ok, json = pcall(vim.fn.json_encode, M.marks)
	if not ok then
		return
	end
	local fd = io.open(M.opts.persist_file, "w")
	if not fd then
		return
	end
	fd:write(json)
	fd:close()
end

-- Load marks from disk
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
	-- restore signs (sign ids need to be unique within this session)
	for _, info in pairs(M.marks) do
		-- sign_id may be nil in older files
		if not info.sign_id then
			M.next_sign_id = M.next_sign_id + 1
			info.sign_id = M.next_sign_id
		end
		-- only place sign if buffer is loaded
		if api.nvim_buf_is_loaded(info.bufnr) then
			pcall(fn.sign_place, info.sign_id, "global_marks", M.opts.sign_name, info.bufnr, { lnum = info.row })
		end
	end
end

-- Define sign
function M.define_sign()
	pcall(fn.sign_define, M.opts.sign_name, { text = M.opts.sign_text, texthl = "Comment" })
end

-- Place sign for a mark
function M.place_sign(mark, bufnr, row)
	local id
	if M.marks[mark] and M.marks[mark].sign_id then
		id = M.marks[mark].sign_id
	else
		M.next_sign_id = M.next_sign_id + 1
		id = M.next_sign_id
	end
	M.marks[mark] = { bufnr = bufnr, row = row, col = 0, sign_id = id }
	pcall(fn.sign_place, id, "global_marks", M.opts.sign_name, bufnr, { lnum = row })
end

-- Remove sign
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

-- Update internal record for a mark when set via MarkSet autocmd
function M.on_mark_set(mark)
	mark = norm_mark(mark)
	if not mark then
		return
	end
	-- get position using getpos("'x") where x is the mark
	local pos = fn.getpos("'" .. mark) -- returns [bufnum,row,col,offset]? In neovim this returns list
	-- pos[1] is buffer number in some versions; if not available, fall back
	local bufnr = tonumber(pos[1]) or api.nvim_get_current_buf()
	local row = tonumber(pos[2]) or 0
	-- Only consider non-zero positions: if row==0 then mark cleared
	if row == 0 then
		-- mark cleared -> remove
		M.remove_sign(mark)
		return
	end
	-- If mark is lowercase, it's buffer-local; only register if bufnr matches current buffer
	local is_lower = mark:match("%l")
	if is_lower then
		-- buffer-local: ensure stored bufnr matches current buffer
		bufnr = api.nvim_get_current_buf()
	end
	-- Place sign and store
	M.place_sign(mark, bufnr, row)
end

-- Jump to a mark across open windows/splits. If buffer exists in an open window, jump to that window. Otherwise, notify.
function M.jump(mark)
	mark = norm_mark(mark)
	if not mark then
		return
	end
	local info = M.marks[mark]
	if not info then
		print("Mark '" .. mark .. "' not registered by global_marks or not set.")
		return
	end
	local target_buf = info.bufnr
	if not target_buf or not api.nvim_buf_is_valid(target_buf) then
		print("Target buffer for mark '" .. mark .. "' is not valid or not loaded.")
		return
	end
	-- Find a window showing that buffer
	for _, win in ipairs(api.nvim_list_wins()) do
		if api.nvim_win_get_buf(win) == target_buf then
			-- jump to that window and set cursor
			api.nvim_set_current_win(win)
			api.nvim_win_set_cursor(win, { info.row, info.col })
			return
		end
	end
	-- Not found in any open window. Don't open new window because user requested across open splits.
	print("Buffer for mark '" .. mark .. "' is not open in any split. Open the buffer first.")
end

-- Delete mark (both sign + unset actual vim mark)
function M.delete(mark)
	mark = norm_mark(mark)
	if not mark then
		return
	end
	-- remove sign/internal record
	M.remove_sign(mark)
end

-- List marks: returns table of {mark, bufnr, row}
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

-- UI: simple telescope-style picker fallback
function M.show_list()
	local marks = M.list()
	if vim.tbl_isempty(marks) then
		print("No global marks registered.")
		return
	end
	local choices = {}
	for _, v in ipairs(marks) do
		local name = api.nvim_buf_get_name(v.bufnr)
		table.insert(choices, string.format("%s — %s:%d", v.mark, name ~= "" and name or "[No Name]", v.row))
	end
	-- if telescope is available, use it
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
	-- fallback: simple quickfix list
	vim.fn.setqflist({})
	for _, v in ipairs(marks) do
		local name = api.nvim_buf_get_name(v.bufnr)
		table.insert(vim.fn.getqflist(), { filename = name, lnum = v.row, text = "Mark " .. v.mark })
	end
	print("Marks: ")
	for i, c in ipairs(choices) do
		print(i .. ": " .. c)
	end
end

-- Autocmds: capture MarkSet and VimLeave/VimEnter
-- Replace your existing setup_autocmds() with this version
-- Robust setup_autocmds with a VimEnter retry
function M.setup_autocmds()
	M.define_sign()

	local aug = api.nvim_create_augroup("GlobalMarks", { clear = true })

	-- helper to create the MarkSet autocmd, returns true on success
	local function try_create_markset()
		local ok, err = pcall(function()
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

	-- Attempt immediately
	local created = try_create_markset()

	if not created then
		-- Schedule a retry on VimEnter (covers lazy/timing issues)
		api.nvim_create_autocmd("VimEnter", {
			group = aug,
			once = true,
			callback = function()
				local ok = try_create_markset()
				if not ok then
					-- Final fallback: install `m` remap so plugin still works
					vim.notify(
						"global_marks.nvim: 'MarkSet' unavailable after retry, using fallback mapping for `m`",
						vim.log.levels.WARN
					)
					-- Avoid remapping if it's already mapped to something else; use a flag
					if not M._fallback_installed then
						vim.keymap.set("n", "m", function()
							local okc, char = pcall(vim.fn.getcharstr)
							if not okc or not char or char == "" then
								return
							end
							vim.cmd("normal! m" .. char)
							pcall(M.on_mark_set, char)
						end, { noremap = true, silent = true })
						M._fallback_installed = true
					end
				end
			end,
		})
	end

	-- Save marks on exit
	vim.api.nvim_create_autocmd({ "VimLeavePre", "QuitPre" }, {
		group = aug,
		callback = function()
			M.save()
		end,
	})

	-- When buffers are wiped/unloaded, remove signs for marks whose buffer is gone
	vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
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
end

-- Public setup
function M.setup(opts)
	if opts then
		M.opts = vim.tbl_extend("force", M.opts, opts)
	end
	M.define_sign()
	M.load()
	M.setup_autocmds()
	-- user commands
	api.nvim_create_user_command("GMarksList", function()
		M.show_list()
	end, {})
	api.nvim_create_user_command("GMarkJump", function(opts)
		local m = opts.args:sub(1, 1)
		M.jump(m)
	end, { nargs = 1 })
	api.nvim_create_user_command("GMarkDel", function(opts)
		local m = opts.args:sub(1, 1)
		M.delete(m)
	end, { nargs = 1 })
end

return M
