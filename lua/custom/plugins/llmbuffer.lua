local M = {}

local ns_id = vim.api.nvim_create_namespace 'llmbuffer'

local API_ERROR_MESSAGE = [[
ERROR: API key is missing from your environment variables.

Please set it using `export %s=<api_key>` in your shell configuration.
]]

local Job = require 'plenary.job'

local config = {
  keybinding = '<leader>ll',
  model = 'google/gemini-flash-1.5-exp',
  api_endpoint = 'https://openrouter.ai/api/v1/chat/completions',
  api_key = vim.fn.getenv 'OPENROUTER_API_KEY',
}

local function merge_configs(user_config)
  if not user_config then
    return
  end
  for key, value in pairs(user_config) do
    config[key] = value
  end
end

local function make_curl_args(data)
  return {
    '-s', -- Silent mode
    '--fail-with-body',
    '-N', -- No buffer
    '-X',
    'POST',
    '-H',
    'Content-Type: application/json',
    '-H',
    'Authorization: Bearer ' .. config.api_key,
    '-d',
    vim.fn.json_encode(data),
    config.api_endpoint,
  }
end

function M.write_string_at_extmark(str, extmark_id)
  vim.schedule(function()
    local extmark = vim.api.nvim_buf_get_extmark_by_id(0, ns_id, extmark_id, { details = false })
    if extmark and #extmark >= 2 then
      local row, col = extmark[1], extmark[2]
      vim.cmd 'undojoin'
      local lines = vim.split(str, '\n')
      vim.api.nvim_buf_set_text(0, row, col, row, col, lines)
    end
  end)
end

function M.parse_buffer()
  local messages = {}
  local assistant_mode = false
  local assistant_content = {}

  for _, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if line:match '<assistant>' then
      assistant_mode = true
    elseif line:match '</assistant>' then
      assistant_mode = false
      if #assistant_content > 0 then
        table.insert(messages, {
          role = 'assistant',
          content = table.concat(assistant_content, '\n'),
        })
        assistant_content = {}
      end
    elseif assistant_mode then
      table.insert(assistant_content, line)
    else
      if line ~= '' then
        table.insert(messages, {
          role = 'user',
          content = line,
        })
      end
    end
  end

  return messages
end

function M.send_to_llm_provider()
  local messages = M.parse_buffer()
  local payload = {
    model = config.model,
    messages = messages,
    stream = true,
  }

  local curl_args = make_curl_args(payload)
  local logfile = '/tmp/llmbuffer.log'

  local file = io.open(logfile, 'a')
  if file then
    file:write(os.date '[%Y-%m-%d %H:%M:%S] ' .. 'curl ' .. table.concat(curl_args, ' ') .. '\n')
    file:close()
  end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local stream_end_extmark_id = vim.api.nvim_buf_set_extmark(0, ns_id, row - 1, col, {})

  Job:new({
    command = 'curl',
    args = curl_args,
    on_stdout = function(_, line)
      -- Handle and write the data
      local data = line:match '^data: (.+)$'
      if data and data:match '"delta":' then
        local json = vim.json.decode(data)
        if json.choices and json.choices[1] and json.choices[1].delta and json.choices[1].delta.content then
          local content = json.choices[1].delta.content
          M.write_string_at_extmark(content, stream_end_extmark_id)
        else
          vim.schedule(function()
            vim.print(data)
          end)
        end
      end
    end,
    on_stderr = function(_, line)
      vim.schedule(function()
        local error_logfile = '/tmp/llmbuffer_error.log'
        local error_file = io.open(error_logfile, 'a')
        if error_file then
          error_file:write(os.date '[%Y-%m-%d %H:%M:%S] ' .. line .. '\n')
          error_file:close()
          vim.api.nvim_err_writeln('API Error: Check ' .. error_logfile .. ' for details.')
        else
          vim.api.nvim_err_writeln 'API Error: Failed to write to log file.'
        end
      end)
    end,
    on_exit = function(j, return_val)
      vim.schedule(function()
        if return_val ~= 0 then
          vim.api.nvim_err_writeln('API request failed with exit code ' .. return_val)
        end
      end)
    end,
  }):start()
end

function M.setup(user_config)
  merge_configs(user_config)

  if not config.api_key or config.api_key == '' then
    config.api_key = vim.fn.getenv(API_KEY_NAME)
    if not config.api_key or config.api_key == '' then
      vim.schedule(function()
        vim.notify('API key is not set. Please provide it in the configuration or set the environment variable.', vim.log.levels.ERROR)
      end)
      return
    end
  end

  vim.api.nvim_set_keymap('n', config.keybinding, '<cmd>lua require("custom.plugins.llmbuffer").send_to_llm_provider()<CR>', { noremap = true, silent = true })
end

return M
