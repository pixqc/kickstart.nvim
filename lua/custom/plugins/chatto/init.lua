local curl = require 'plenary.curl'
local async = require 'plenary.async'
local M = {}

local state = {
  winid = nil,
  bufnr = nil,
}

local function random_chunk(limit)
  local chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  local result = ''
  for _ = 1, limit do
    local random_index = math.random(1, #chars)
    result = result .. string.sub(chars, random_index, random_index)
  end
  return result
end

local function append_buffer(text)
  vim.schedule(function()
    if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
      local line_num = vim.api.nvim_buf_line_count(state.bufnr) - 1
      local line = vim.api.nvim_buf_get_lines(state.bufnr, line_num, line_num + 1, false)[1] or ''
      vim.api.nvim_buf_set_lines(state.bufnr, line_num, line_num + 1, false, { line .. text })
    end
  end)
end

local function create_window()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    state.bufnr = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_buf_set_keymap(state.bufnr, 'n', '<CR>', '', {
      callback = function()
        for _ = 1, 100 do
          append_buffer(random_chunk(3))
        end
      end,
      noremap = true,
      silent = true,
    })
  end
  vim.cmd 'botright vsplit'
  state.winid = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(state.winid, state.bufnr)
  vim.api.nvim_win_set_width(state.winid, math.floor(vim.o.columns * 0.35))
  vim.api.nvim_set_option_value('number', true, { win = state.winid })
  vim.api.nvim_set_option_value('relativenumber', true, { win = state.winid })
  vim.api.nvim_set_option_value('winfixwidth', true, { win = state.winid })
  vim.api.nvim_buf_set_name(state.bufnr, 'chatto')
end

M.setup = function()
  vim.api.nvim_create_user_command('Chatto', function(opts)
    if opts.args == 'open' then
      if not (state.winid and vim.api.nvim_win_is_valid(state.winid)) then
        create_window()
      end
    elseif opts.args == 'close' then
      if state.winid and vim.api.nvim_win_is_valid(state.winid) then
        vim.api.nvim_win_close(state.winid, true)
        state.winid = nil
      end
    elseif opts.args == 'toggle' then
      if state.winid and vim.api.nvim_win_is_valid(state.winid) then
        vim.api.nvim_win_close(state.winid, true)
        state.winid = nil
      else
        create_window()
      end
    end
  end, {
    nargs = 1,
    complete = function(_, _, _)
      return { 'open', 'close', 'toggle' }
    end,
  })
end

return M

--
-- local function append_to_chat(text)
--   vim.schedule(function()
--     if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
--       local lines = vim.split(text, '\n')
--       vim.api.nvim_buf_set_lines(state.bufnr, -1, -1, false, lines)
--     end
--   end)
-- end
--
-- local function get_copilot_token()
--   local config_path = M.config_path()
--   if not config_path then
--     return nil, 'Could not find config directory'
--   end
--
--   local file_paths = {
--     config_path .. '/github-copilot/hosts.json',
--     config_path .. '/github-copilot/apps.json',
--   }
--
--   for _, file_path in ipairs(file_paths) do
--     if vim.fn.filereadable(file_path) == 1 then
--       local ok, content = pcall(vim.fn.readfile, file_path)
--       if ok then
--         local ok2, data = pcall(vim.fn.json_decode, content)
--         if ok2 then
--           for key, value in pairs(data) do
--             if string.find(key, 'github.com') then
--               return value.oauth_token
--             end
--           end
--         end
--       end
--     end
--   end
--
--   return nil, 'No GitHub token found in Copilot config files'
-- end
--
-- local function create_window()
--   local current_window = vim.api.nvim_get_current_win()
--   if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
--     state.bufnr = vim.api.nvim_create_buf(false, true)
--   end
--   vim.cmd 'botright vsplit'
--   state.winid = vim.api.nvim_get_current_win()
--
--   vim.api.nvim_win_set_buf(state.winid, state.bufnr)
--   vim.api.nvim_win_set_width(state.winid, math.floor(vim.o.columns * 0.35))
--   vim.api.nvim_set_option_value('number', true, { win = state.winid })
--   vim.api.nvim_set_option_value('relativenumber', true, { win = state.winid })
--   vim.api.nvim_set_option_value('winfixwidth', true, { win = state.winid })
--   vim.api.nvim_set_option_value('signcolumn', 'no', { win = state.winid })
--   vim.api.nvim_set_option_value('wrap', true, { win = state.winid })
--   vim.api.nvim_set_current_win(current_window)
--   vim.api.nvim_buf_set_name(state.bufnr, 'chatto')
-- end
--
-- local function get_copilot_token_from_api(github_token)
--   local response = curl.get('https://api.github.com/copilot_internal/v2/token', {
--     headers = {
--       Authorization = 'token ' .. github_token,
--       Accept = 'application/json',
--       ['User-Agent'] = 'CopilotChat.nvim/2.0.0',
--     },
--   })
--
--   if response.status ~= 200 then
--     error('Failed to get Copilot token: ' .. vim.inspect(response))
--   end
--
--   -- Decode the response body to get the token
--   local data = vim.fn.json_decode(response.body)
--   if not data or not data.token then
--     error 'Invalid response format for Copilot token'
--   end
--
--   -- Return just the token string
--   return data.token
-- end
--
-- local function send_chat_request(prompt, copilot_token)
--   local json_body = vim.fn.json_encode {
--     model = 'gpt-4o',
--     messages = {
--       { role = 'user', content = prompt },
--     },
--     stream = true,
--     n = 1,
--   }
--
--   local accumulated_response = ''
--
--   curl.post('https://api.githubcopilot.com/chat/completions', {
--     headers = {
--       Authorization = 'Bearer ' .. copilot_token,
--       ['Content-Type'] = 'application/json',
--       ['OpenAI-Intent'] = 'conversation-panel',
--       ['User-Agent'] = 'CopilotChat.nvim/2.0.0',
--       ['Editor-Version'] = 'Neovim/0.10.2',
--       ['Editor-Plugin-Version'] = 'CopilotChat.nvim/2.0.0',
--       ['Copilot-Integration-Id'] = 'vscode-chat',
--       ['OpenAI-Organization'] = 'github-copilot',
--     },
--     body = json_body,
--     stream = function(err, data)
--       if err then
--         append_to_chat('Error: ' .. tostring(err))
--         return
--       end
--
--       -- Skip empty lines
--       if data and #data > 0 then
--         -- Each chunk starts with "data: "
--         local content = data:match '^data: (.+)$'
--         if content then
--           -- Try to decode the JSON content
--           local ok, decoded = pcall(vim.fn.json_decode, content)
--           if ok and decoded.choices and decoded.choices[1].delta.content then
--             local chunk = decoded.choices[1].delta.content
--             if type(chunk) == 'string' then -- Ensure chunk is a string
--               accumulated_response = accumulated_response .. chunk
--               vim.schedule(function()
--                 if chunk ~= '' then -- Only append non-empty chunks
--                   append_to_chat(chunk)
--                 end
--               end)
--             end
--           end
--         end
--       end
--     end,
--   })
-- end
--
-- M.setup = function()
--   state.github_token = get_copilot_token()
--
--   vim.api.nvim_create_user_command('ChattoOpen', function()
--     if not (state.winid and vim.api.nvim_win_is_valid(state.winid)) then
--       create_window()
--     end
--   end, {})
--
--   vim.api.nvim_create_user_command('ChattoClose', function()
--     if state.winid and vim.api.nvim_win_is_valid(state.winid) then
--       vim.api.nvim_win_close(state.winid, true)
--       state.winid = nil
--     end
--   end, {})
--
--   vim.api.nvim_create_user_command('ChattoToggle', function()
--     if state.winid and vim.api.nvim_win_is_valid(state.winid) then
--       vim.api.nvim_win_close(state.winid, true)
--       state.winid = nil
--     else
--       create_window()
--     end
--   end, {})
--
--   vim.api.nvim_create_user_command('Abc', function(opts)
--     if not (state.winid and vim.api.nvim_win_is_valid(state.winid)) then
--       create_window()
--     end
--
--     async.void(function()
--       append_to_chat 'Loading...'
--
--       local ok, copilot_token = pcall(get_copilot_token_from_api, state.github_token)
--       if not ok then
--         append_to_chat('Error getting Copilot token: ' .. copilot_token)
--         return
--       end
--
--       local prompt = table.concat(opts.fargs, ' ')
--       local ok2, response = pcall(send_chat_request, prompt, copilot_token)
--       if not ok2 then
--         append_to_chat('Error in chat request: ' .. response)
--         return
--       end
--
--       -- Clear loading message and show response
--       vim.api.nvim_buf_set_lines(state.bufnr, -2, -1, false, {})
--       append_to_chat(response)
--     end)()
--   end, { nargs = '+' })
-- end
--
-- return M
--
-- --  NOTE: github_token comes form hosts.json
-- --
-- -- local function get_copilot_token(github_token)
-- -- 	local cmd = string.format(
-- -- 		'curl -s -H "Authorization: token %s" -H "Accept: application/json" -H "User-Agent: CopilotChat.nvim/2.0.0" https://api.github.com/copilot_internal/v2/token',
-- -- 		github_token
-- -- 	)
-- --
-- -- 	local handle = io.popen(cmd)
-- -- 	local response = handle:read("*a")
-- -- 	handle:close()
-- --
-- -- 	-- Basic JSON parsing (very simplified, might need to be more robust)
-- -- 	local token = response:match('"token":"([^"]+)"')
-- -- 	if not token then
-- -- 		error("Failed to get Copilot token")
-- -- 	end
-- -- 	return token
-- -- end
-- --
-- -- local function send_chat(prompt, copilot_token)
-- -- 	local escaped_prompt = prompt:gsub('"', '\\"')
-- -- 	local json_body = string.format(
-- -- 		[[
-- --         {
-- --             "model": "gpt-4o",
-- --             "messages": [
-- --                 {"role": "user", "content": "%s"}
-- --             ],
-- --             "stream": false,
-- --             "n": 1
-- --         }
-- --     ]],
-- -- 		escaped_prompt
-- -- 	)
-- --
-- -- 	local temp_file = os.tmpname()
-- -- 	local f = io.open(temp_file, "w")
-- -- 	f:write(json_body)
-- -- 	f:close()
-- --
-- -- 	local cmd = string.format(
-- -- 		'curl -s -X POST "https://api.githubcopilot.com/chat/completions" '
-- -- 			.. '-H "Authorization: Bearer %s" '
-- -- 			.. '-H "Content-Type: application/json" '
-- -- 			.. '-H "OpenAI-Intent: conversation-panel" '
-- -- 			.. '-H "User-Agent: CopilotChat.nvim/2.0.0" '
-- -- 			.. '-H "Editor-Version: Neovim/0.10.2" '
-- -- 			.. '-H "Editor-Plugin-Version: CopilotChat.nvim/2.0.0" '
-- -- 			.. '-H "Copilot-Integration-Id: vscode-chat" '
-- -- 			.. '-H "OpenAI-Organization: github-copilot" '
-- -- 			.. "-d @%s",
-- -- 		copilot_token,
-- -- 		temp_file
-- -- 	)
-- --
-- -- 	local handle = io.popen(cmd)
-- -- 	local response = handle:read("*a")
-- -- 	handle:close()
-- --
-- -- 	print(response)
-- --
-- -- 	os.remove(temp_file)
-- -- 	local content = response:match('"content":"([^"]+)"')
-- -- 	if not content then
-- -- 		error("Failed to get response")
-- -- 	end
-- --
-- -- 	-- Unescape any escaped characters in the content
-- -- 	content = content:gsub('\\"', '"')
-- --
-- -- 	return content
-- -- end
-- --
-- -- local copilot_token = get_copilot_token(github_token)
-- -- local prompt = "hello gpt4o"
-- -- print(copilot_token)
-- -- local response = send_chat(prompt, copilot_token)
-- -- print(response)
--
-- local function get_local_token()
--   local files = {
--     vim.fn.expand '$HOME/.config/github-copilot/hosts.json',
--     vim.fn.expand '$HOME/.config/github-copilot/apps.json',
--   }
--
--   for _, file in ipairs(files) do
--     if vim.fn.filereadable(file) == 1 then
--       local content = vim.fn.json_decode(vim.fn.readfile(file))
--       for key, value in pairs(content) do
--         if key:find 'github.com' then
--           return value.oauth_token
--         end
--       end
--     end
--   end
-- end
