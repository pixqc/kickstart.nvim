local Job = require 'plenary.job'

local M = {}
local ns_id = vim.api.nvim_create_namespace 'llmbuffer'

local function log(level, message)
  local log_file = io.open('/tmp/llmbuffer.log', 'a')
  if log_file then
    log_file:write(os.date '[%Y-%m-%d %H:%M:%S]' .. ' [' .. level .. '] ' .. message .. '\n')
    log_file:close()
  end
end

-- https://github.com/chottolabs/kznllm.nvim/blob/main/lua/kznllm/init.lua#L40
-- write tokens to buffer
local function write_string_at_extmark(str, extmark_id)
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

local configs = {
  {
    name = 'openrouter:gemini-flash',
    spec = 'openrouter',
    keybinding = '<leader>lk',
    model = 'google/gemini-flash-1.5-exp',
    api_endpoint = 'https://openrouter.ai/api/v1',
    api_key = vim.fn.getenv 'OPENROUTER_API_KEY',
  },
  {
    name = 'aistudio:gemini-flash',
    spec = 'aistudio',
    keybinding = '<leader>ll',
    model = 'gemini-1.5-flash-latest',
    api_endpoint = 'https://generativelanguage.googleapis.com/v1beta',
    api_key = vim.fn.getenv 'GOOGLE_AISTUDIO_API_KEY',
  },
}

local function get_url(config)
  if config.spec == 'openrouter' then
    return string.format('%s/chat/completions', config.api_endpoint)
  elseif config.spec == 'aistudio' then
    return string.format('%s/models/%s:streamGenerateContent?alt=sse&key=%s', config.api_endpoint, config.model, config.api_key)
  end
end

local sse_parser = {
  openrouter = function(line)
    local data = line:match '^data: (.+)$'
    if data and data:match '"delta":' then
      local json = vim.json.decode(data)
      if json.choices and json.choices[1] and json.choices[1].delta and json.choices[1].delta.content then
        return json.choices[1].delta.content
      end
    end
    return nil
  end,

  aistudio = function(line)
    local data = line:match '^data: (.+)$'
    if data then
      local json = vim.json.decode(data)
      if json.candidates and json.candidates[1] and json.candidates[1].content and json.candidates[1].content.parts then
        local content_parts = {}
        for _, part in ipairs(json.candidates[1].content.parts) do
          if part.text then
            table.insert(content_parts, part.text)
          end
        end
        if #content_parts > 0 then
          return table.concat(content_parts, '\n')
        end
      end
    end
    return nil
  end,
}

local function format_aistudio(messages)
  local formatted = {}
  for _, msg in ipairs(messages) do
    local role = msg.role == 'assistant' and 'model' or msg.role
    table.insert(formatted, {
      role = role,
      parts = { { text = msg.content } },
    })
  end
  return formatted
end

local function get_curl_args(data, config)
  local base_args = {
    '-s',
    '--fail-with-body',
    '-N',
    '-X',
    'POST',
    '-H',
    'Content-Type: application/json',
  }

  if config.spec == 'openrouter' then
    table.insert(base_args, '-H')
    table.insert(base_args, 'Authorization: Bearer ' .. config.api_key)
  end

  table.insert(base_args, '-d')
  table.insert(base_args, vim.fn.json_encode(data))
  table.insert(base_args, get_url(config))

  return base_args
end

-- turn buffer to messages
local function parse_buffer()
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

function M.chat(config_name)
  local config
  for _, cfg in ipairs(configs) do
    if cfg.name == config_name then
      config = cfg
      break
    end
  end

  local messages = parse_buffer()
  if config.spec == 'aistudio' then
    messages = format_aistudio(messages)
  end
  local payload
  if config.spec == 'openrouter' then
    payload = {
      model = config.model,
      messages = messages,
      stream = true,
    }
  elseif config.spec == 'aistudio' then
    payload = {
      contents = messages,
    }
  end

  local curl_args = get_curl_args(payload, config)
  log('INFO', 'curl ' .. table.concat(curl_args, ' '))
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local stream_end_extmark_id = vim.api.nvim_buf_set_extmark(0, ns_id, row - 1, col, {})
  write_string_at_extmark('\n<assistant>\n', stream_end_extmark_id)

  Job:new({
    command = 'curl',
    args = curl_args,
    on_stdout = function(_, line)
      local content = sse_parser[config.spec](line)
      print('content:', content)
      if content then
        write_string_at_extmark(content, stream_end_extmark_id)
      else
        log('ERROR', 'Unparseable line: ' .. line)
      end
    end,
    on_stderr = function(_, line)
      vim.schedule(function()
        local error_message = 'API Error: ' .. line
        vim.api.nvim_err_writeln(error_message)
        log('ERROR', error_message)
      end)
    end,
    on_exit = function(j, return_val)
      vim.schedule(function()
        if return_val ~= 0 then
          local error_message = 'API request failed with exit code ' .. return_val
          vim.api.nvim_err_writeln(error_message)
          log('ERROR', error_message)

          -- Print stdout and stderr for debugging
          local stdout = j:result()
          local stderr = j:stderr_result()
          print('Stdout:', vim.inspect(stdout))
          print('Stderr:', vim.inspect(stderr))
          log('INFO', 'Stdout: ' .. vim.inspect(stdout))
          log('INFO', 'Stderr: ' .. vim.inspect(stderr))
        else
          write_string_at_extmark('\n</assistant>\n', stream_end_extmark_id)
        end
      end)
    end,
  }):start()
end

function M.setup()
  for _, config in ipairs(configs) do
    vim.api.nvim_set_keymap(
      'n',
      config.keybinding,
      string.format([[<cmd>lua require('%s').chat('%s')<CR>]], 'custom.plugins.llmbuffer', config.name),
      { noremap = true, silent = true }
    )
  end
end

return M
