# Global Marks

Marks are nice but I haven't found a nice plugin for jumping to marks across open splits. This is an attempt to see if I
can fill that gap. (WIP)

## TL;DR

- Copy and paste the code below into `~/.config/nvim/<path-to-your-plugins>` to install the plugin.
- Set a mark as usual with `m{char}` (uppercase and lowercase are both allowed. uppercase retain the original
  functionality of being global across buffers)
- Jump to a mark with `M{char}` (note the uppercase M)

* Delete the mark on the current line with `<leader>md`

- List all marks with `<leader>ml`
- Clear all marks with `<leader>mc`

## Installation (lazy.nvim)

```lua
return {
	"nd70/global_marks.nvim",
	event = "VeryLazy",
	keys = {
		{ "<leader>mc", "<cmd>:GMarkClear<cr>", desc = "Clear all marks" },
		{ "<leader>ml", "<cmd>:GMarksList<cr>", desc = "Show all marks" },
	},
	config = function()
		local gm = require("global_marks")
		gm.setup()

		----------------------------------------------------------------------
		-- M{char} → Jump to mark
		----------------------------------------------------------------------
		for _, mp in ipairs(vim.api.nvim_get_keymap("n")) do
			if mp.lhs == "M" then
				vim.notify("global_marks: 'M' is already mapped; not replacing it", vim.log.levels.INFO)
				goto skip_m_mapping
			end
		end

		vim.keymap.set("n", "M", function()
			local ok, ch = pcall(vim.fn.getcharstr)
			if not ok or not ch or ch == "" then
				return
			end
			local mark = ch:sub(1, 1)

			local loaded, gm_mod = pcall(require, "global_marks")
			if loaded and gm_mod and type(gm_mod.jump) == "function" then
				pcall(gm_mod.jump, mark)
			else
				pcall(vim.cmd, "GMarkJump " .. mark)
			end
		end, {
			noremap = true,
			silent = true,
			desc = "Jump to global mark (M{char})",
		})

		::skip_m_mapping::

		----------------------------------------------------------------------
		-- <leader>md → Delete mark(s) on the *current line* (no args)
		-- Handles lowercase (per-buffer) and uppercase (global) mark shapes.
		----------------------------------------------------------------------
		vim.keymap.set("n", "<leader>md", function()
			local ok, gm_mod = pcall(require, "global_marks")
			if not ok or not gm_mod or type(gm_mod.marks) ~= "table" then
				vim.notify("global_marks not loaded", vim.log.levels.WARN)
				return
			end

			local bufnr = vim.api.nvim_get_current_buf()
			local row = vim.api.nvim_win_get_cursor(0)[1] -- 1-indexed line number

			-- Collect any matching marks on this line
			local to_delete = {}
			for mark, info in pairs(gm_mod.marks) do
				if mark:match("%l") then
					-- lowercase: per-buffer table keyed by tostring(bufnr)
					local tbl = info
					if tbl and tbl[tostring(bufnr)] then
						local ent = tbl[tostring(bufnr)]
						if ent and ent.row == row then
							table.insert(to_delete, mark)
						end
					end
				else
					-- uppercase: single global entry
					local ent = info
					if ent and ent.bufnr == bufnr and ent.row == row then
						table.insert(to_delete, mark)
					end
				end
			end

			if #to_delete == 0 then
				vim.notify("No mark on this line", vim.log.levels.INFO)
				return
			end

			-- Delete all found marks (prefer Lua API delete, fallback to command)
			local deleted = 0
			for _, mark in ipairs(to_delete) do
				local ok2, gm2 = pcall(require, "global_marks")
				if ok2 and gm2 and type(gm2.delete) == "function" then
					pcall(gm2.delete, mark)
					deleted = deleted + 1
				else
					local suc = pcall(vim.cmd, "GMarkDel " .. mark)
					if suc then
						deleted = deleted + 1
					end
				end
			end

			vim.notify(("Deleted mark"):format(deleted), vim.log.levels.INFO)
		end, {
			noremap = true,
			silent = true,
			desc = "Delete global mark(s) on the current line",
		})
	end,
}
```
