# Global Marks

Marks are nice but I haven't found a nice plugin for jumping to marks across open splits. This is an attempt to see if I
can fill that gap. (WIP)

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
		-- <leader>md → Delete mark on the *current line* (no args)
		----------------------------------------------------------------------
		vim.keymap.set("n", "<leader>md", function()
			local gm_mod = require("global_marks")
			local bufnr = vim.api.nvim_get_current_buf()
			local row = vim.api.nvim_win_get_cursor(0)[1] -- 1-indexed line number

			-- Find matching mark(s)
			local to_delete = {}
			for mark, info in pairs(gm_mod.marks) do
				if info.bufnr == bufnr and info.row == row then
					table.insert(to_delete, mark)
				end
			end

			if #to_delete == 0 then
				vim.notify("No mark on this line", vim.log.levels.INFO)
				return
			end

			-- Delete all marks on this line
			for _, mark in ipairs(to_delete) do
				pcall(vim.cmd, "GMarkDel " .. mark)
			end
		end, {
			noremap = true,
			silent = true,
			desc = "Delete global mark on the current line",
		})
	end,
}
```
