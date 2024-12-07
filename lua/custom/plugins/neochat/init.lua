local curl = require 'plenary.curl'
local async = require 'plenary.async'
local M = {}

local state = {
  winid = nil,
  bufnr = nil,
  github_token = nil,
}

function M.config_path()
  local config = vim.fn.expand '$XDG_CONFIG_HOME'
  if config and vim.fn.isdirectory(config) > 0 then
    return config
  end

  if vim.fn.has 'win32' > 0 then
    config = vim.fn.expand '$LOCALAPPDATA'
    if not config or vim.fn.isdirectory(config) == 0 then
      config = vim.fn.expand '$HOME/AppData/Local'
    end
  else
    config = vim.fn.expand '$HOME/.config'
  end

  if config and vim.fn.isdirectory(config) > 0 then
    return config
  end
  return nil
end

local function append_to_chat(text)
  vim.schedule(function()
    if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
      local lines = vim.split(text, '\n')
      vim.api.nvim_buf_set_lines(state.bufnr, -1, -1, false, lines)
    end
  end)
end

-- local function ask_copilot(prompt)
--   if not state.github_token then
--     vim.notify('No GitHub token found', vim.log.levels.ERROR)
--     return
--   end
--
--   local body = vim.fn.json_encode {
--     messages = {
--       { role = 'system', content = 'You are a helpful AI assistant.' },
--       { role = 'user', content = prompt },
--     },
--     model = 'gpt-4o',
--     stream = true,
--     temperature = 0.1,
--   }
--
--   curl_post('https://api.githubcopilot.com/chat/completions', {
--     headers = {
--       ['Content-Type'] = 'application/json',
--       ['Authorization'] = 'Bearer ' .. state.github_token,
--       ['X-Github-Api-Version'] = '2023-07-07',
--     },
--     body = body,
--     stream = true,
--     on_chunk = function(_, chunk)
--       if chunk:match '^data: ' then
--         local line = chunk:gsub('^data: ', '')
--         if line ~= '[DONE]' then
--           local ok, decoded = pcall(vim.fn.json_decode, line)
--           if ok and decoded.choices and decoded.choices[1].delta.content then
--             append_to_chat(decoded.choices[1].delta.content)
--           end
--         end
--       end
--     end,
--     callback = function(response)
--       if not response or response.status ~= 200 then
--         vim.notify('Failed to get response from Copilot', vim.log.levels.ERROR)
--       end
--     end,
--   })
-- end

local function get_copilot_token()
  local config_path = M.config_path()
  if not config_path then
    return nil, 'Could not find config directory'
  end

  local file_paths = {
    config_path .. '/github-copilot/hosts.json',
    config_path .. '/github-copilot/apps.json',
  }

  for _, file_path in ipairs(file_paths) do
    if vim.fn.filereadable(file_path) == 1 then
      local ok, content = pcall(vim.fn.readfile, file_path)
      if ok then
        local ok2, data = pcall(vim.fn.json_decode, content)
        if ok2 then
          for key, value in pairs(data) do
            if string.find(key, 'github.com') then
              return value.oauth_token
            end
          end
        end
      end
    end
  end

  return nil, 'No GitHub token found in Copilot config files'
end

local function create_window()
  local current_window = vim.api.nvim_get_current_win()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    state.bufnr = vim.api.nvim_create_buf(false, true)
  end
  vim.cmd 'botright vsplit'
  state.winid = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(state.winid, state.bufnr)
  vim.api.nvim_win_set_width(state.winid, math.floor(vim.o.columns * 0.35))
  vim.api.nvim_set_option_value('number', true, { win = state.winid })
  vim.api.nvim_set_option_value('relativenumber', true, { win = state.winid })
  vim.api.nvim_set_option_value('winfixwidth', true, { win = state.winid })
  vim.api.nvim_set_option_value('signcolumn', 'no', { win = state.winid })
  vim.api.nvim_set_option_value('wrap', true, { win = state.winid })
  vim.api.nvim_set_current_win(current_window)
  vim.api.nvim_buf_set_name(state.bufnr, 'neochat')
end

M.setup = function()
  state.github_token = get_copilot_token()

  vim.api.nvim_create_user_command('NeochatOpen', function()
    if not (state.winid and vim.api.nvim_win_is_valid(state.winid)) then
      create_window()
    end
  end, {})

  vim.api.nvim_create_user_command('NeochatClose', function()
    if state.winid and vim.api.nvim_win_is_valid(state.winid) then
      vim.api.nvim_win_close(state.winid, true)
      state.winid = nil
    end
  end, {})

  vim.api.nvim_create_user_command('NeochatToggle', function()
    if state.winid and vim.api.nvim_win_is_valid(state.winid) then
      vim.api.nvim_win_close(state.winid, true)
      state.winid = nil
    else
      create_window()
    end
  end, {})

  vim.api.nvim_create_user_command('Abc', function(opts)
    if not (state.winid and vim.api.nvim_win_is_valid(state.winid)) then
      create_window()
    end
    curl.get('https://jsonplaceholder.typicode.com/todos/1', {
      headers = {
        ['Content-Type'] = 'application/json',
      },
      callback = function(response)
        append_to_chat(vim.inspect(response))
      end,
    })
  end, { nargs = '+' })
end

return M
