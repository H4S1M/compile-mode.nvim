local a = require("plenary.async")

local M = {}

local compile_mode_ns = vim.api.nvim_create_namespace("compile-mode.nvim")

---@param bufnr integer
---@param hlname string
---@param linenum integer
---@param range CompileModeRange
function M.add_highlight(bufnr, hlname, linenum, range)
	vim.api.nvim_buf_add_highlight(bufnr, compile_mode_ns, hlname, linenum - 1, range.start - 1, range.end_)
end

---@param input string
---@param pattern string
---@return (CompileModeRange|nil)[]
function M.matchlistpos(input, pattern)
	local list = vim.fn.matchlist(input, pattern) --[[@as string[] ]]

	---@type (CompileModeIntByInt|nil)[]
	local result = {}

	local latest_index = vim.fn.match(input, pattern)
	for i, capture in ipairs(list) do
		if capture == "" then
			result[i] = nil
		else
			local start, end_ = string.find(input, capture, latest_index, true)
			assert(start and end_)
			if i ~= 1 then
				latest_index = end_ + 1
			end
			result[i] = {
				start = start,
				end_ = end_,
			}
		end
	end

	return result
end

---@type fun(opts: table): string
M.input = a.wrap(vim.ui.input, 2)

---@type fun()
M.wait = a.wrap(vim.schedule, 1)

---@type fun(ms: number)
M.delay = a.wrap(function(timeout, callback)
	vim.defer_fn(callback, timeout)
end, 2)

---@param bufnr integer
---@param opt string
---@param value any
function M.buf_set_opt(bufnr, opt, value)
	vim.api.nvim_set_option_value(opt, value, { buf = bufnr })
end

---If `fname` has a window open, do nothing.
---Otherwise, split a new window (and possibly buffer) open for that file, respecting `config.split_vertically`.
---
---@param fname string
---@param smods SMods
---@param count integer
---@return integer bufnr the identifier of the buffer for `fname`
function M.split_unless_open(fname, smods, count)
	local bufnr = vim.fn.bufadd(fname)

	if smods.hide then
		return bufnr
	end

	local winnrs = vim.fn.win_findbuf(bufnr)

	if #winnrs == 0 then
		local cmd = "sbuffer " .. bufnr
		if smods.vertical then
			cmd = "vert " .. cmd
		end

		if smods.split and smods.split ~= "" then
			cmd = smods.split .. " " .. cmd
		end

		if smods.tab and smods.tab ~= -1 then
			cmd = tostring(smods.tab) .. "tab " .. cmd
		end

		vim.cmd(cmd)

		if count ~= 0 and count ~= nil then
			vim.cmd("resize" .. count)
		end
	end

	return bufnr
end

---@param filename string
---@param error CompileModeError
---@param smods SMods
local function jump_to_file(filename, error, smods)
	local config = require("compile-mode.config.internal")

	local compilation_bufnr = -1
	if config.use_diagnostics then
		compilation_bufnr = vim.fn.bufadd(config.buffer_name)
		vim.iter(vim.fn.win_findbuf(compilation_bufnr)):each(function(winnr)
			vim.api.nvim_win_call(winnr, function()
				vim.cmd("wincmd q")
			end)
		end)
	else
		compilation_bufnr = M.split_unless_open(config.buffer_name, smods, 0)
		local compilation_winnr = vim.fn.win_findbuf(compilation_bufnr)[1]

		vim.api.nvim_win_set_cursor(compilation_winnr, { error.linenum, 0 })
	end

	local row = error.row and error.row.value or 1
	local end_row = error.end_row and error.end_row.value

	local col = (error.col and error.col.value or 1) - 1
	if col < 0 then
		col = 0
	end
	local end_col = error.end_col and error.end_col.value - 1
	if end_col and end_col < 0 then
		end_col = 0
	end

	if vim.api.nvim_get_current_buf() ~= compilation_bufnr then
		vim.cmd.e(filename)
	elseif #vim.api.nvim_list_wins() > 1 then
		vim.cmd("wincmd p")
		vim.cmd.e(filename)
	else
		M.split_unless_open(filename, smods, 0)
	end

	local target_bufnr = vim.fn.bufadd(filename)
	local target_winnr = vim.fn.win_findbuf(target_bufnr)[1]

	local last_row = vim.api.nvim_buf_line_count(target_bufnr)
	if row > last_row then
		row = last_row
	end
	vim.api.nvim_win_set_cursor(target_winnr, { row, col })

	if end_row or end_col then
		local cmd = ""
		if not error.col and not error.end_col then
			cmd = cmd .. "V"
		else
			cmd = cmd .. "v"
		end

		if end_row then
			cmd = cmd .. tostring(end_row - row) .. "j"
		end

		if end_col then
			cmd = cmd .. tostring(end_col - col) .. "l"
		end

		vim.api.nvim_buf_call(target_bufnr, function()
			vim.cmd.normal(cmd)
		end)
	end

	if config.use_diagnostics then
		local errors = require("compile-mode.errors")
		local diagnostics = errors.todiagnostic(target_bufnr, errors.error_list)
		vim.diagnostic.set(compile_mode_ns, target_bufnr, diagnostics, {})
		M.delay(100)
		vim.diagnostic.open_float()
	end
end

function M.clear_diagnostics()
	vim.diagnostic.reset(compile_mode_ns)
end

---@type fun(error: CompileModeError, current_dir: string, smods: SMods)
M.jump_to_error = a.void(function(error, current_dir, smods)
	current_dir = string.gsub(current_dir or "", "/$", "")

	local filename = error.filename.value
	if not M.is_absolute(filename) then
		filename = current_dir .. "/" .. filename
	end

	local file_exists = vim.fn.filereadable(filename) ~= 0

	if file_exists then
		jump_to_file(filename, error, smods)
		return
	end

	local dir = M.input({
		prompt = "Find this error in: ",
		completion = "file",
	})
	if not dir then
		return
	end
	dir = string.gsub(dir, "/$", "")

	M.wait()

	if vim.fn.isdirectory(dir) == 0 then
		if vim.fn.filereadable(dir) == 0 then
			vim.notify(dir .. " is not readable", vim.log.levels.ERROR)
			return
		end

		jump_to_file(dir, error, smods)
		return
	end

	local nested_filename = vim.fs.normalize(dir .. "/" .. error.filename.value)
	if vim.fn.filereadable(nested_filename) == 0 then
		vim.notify(error.filename.value .. " does not exist in " .. dir, vim.log.levels.ERROR)
		return
	end

	jump_to_file(nested_filename, error, smods)
end)

function M.match_command_ouput(line, linenum)
	local highlights = {}

	local result = M.matchlistpos(line, "^\\([[:alnum:]_/.+-]\\+\\)\\%(\\[\\([0-9]\\+\\)\\]\\)\\?[ \t]*:")
	if result then
		local entire = result[1]
		if entire then
			table.insert(highlights, { "CompileModeCommandOutput", linenum, entire })
		end

		local num = result[3]
		if num then
			table.insert(highlights, { "CompileModeMessageRow", linenum, num })
		end
	end

	return highlights
end

function M.highlight_command_outputs(bufnr, command_output_highlights)
	for _, highlight in ipairs(command_output_highlights) do
		M.add_highlight(bufnr, unpack(highlight))
	end
end

---Ask user whether to save each modified buffer, and save them as requested.
---@param smods SMods
---@return boolean quit whether to quit or not
function M.ask_to_save(smods)
	local buffers = vim.api.nvim_list_bufs()
	local buffers_with_changes = vim.tbl_filter(function(bufnr)
		return vim.api.nvim_get_option_value("modified", { buf = bufnr })
	end, buffers)

	for _, bufnr in ipairs(buffers_with_changes) do
		local bufname = vim.api.nvim_buf_get_name(bufnr)
		local result = vim.fn.confirm("Save changes to " .. bufname .. "?", "&Yes\n&No\nSkip &All\n&Quit")

		if result == 1 then
			vim.cmd(tostring(bufnr) .. "bufdo w")
		end

		if result == 3 then
			break
		end

		if result == 4 and not smods.silent then
			vim.notify("Quit")
			return true
		end
	end

	return false
end

function M.is_windows()
	return vim.uv.os_uname().sysname == "Windows_NT"
end

---@param path string
---@return boolean is_absolute whether `path` is absolute or relative.
function M.is_absolute(path)
	if M.is_windows() then
		return path:match("^%a:[/\\]") or path:match("^//") or path:match("^\\\\")
	else
		return path:sub(1, 1) == "/"
	end
end

return M
