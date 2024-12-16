local curl = require 'plenary.curl'
local M = {}

local state = {
  winid = nil,
  bufnr = nil,
}

---@alias Endpoint "aistudio" | "openrouter"
---@alias MessageRole "user" | "assistant" | "system"

---@class Message
---@field role MessageRole
---@field content string

---@class Messages
---@field messages Message[] @ must NonEmpty

---@class ModelConfig
---@field url string
---@field name string
---@field api_key string @ from IO: must NonEmpty

---@class RequestBody
---@field model string
---@field messages Messages
---@field stream boolean

local models = {
  aistudio = {
    {
      url = 'https://generativelanguage.googleapis.com/v1beta/chat/completions',
      name = 'models/gemini-2.0-flash-exp',
    },
  },
  openrouter = {
    {
      url = 'https://openrouter.ai/api/v1/chat/completions',
      name = 'meta-llama/llama-3.3-70b-instruct',
    },
    {
      url = 'https://openrouter.ai/api/v1/chat/completions',
      name = 'anthropic/claude-3.5-sonnet:beta',
    },
  },
}

local key_names = {
  aistudio = 'GOOGLE_AISTUDIO_API_KEY',
  openrouter = 'OPENROUTER_API_KEY',
}

---@param models_ table<string, {url: string, name: string}[]>
---@param endpoint_ Endpoint
---@param key_name string
---@return ModelConfig[]
local function mk_model_configs(models_, endpoint_, key_name)
  local configs = {}
  for _, model in ipairs(models_[endpoint_]) do
    table.insert(configs, {
      url = model.url,
      name = model.name,
      api_key = os.getenv(key_name),
    })
  end
  return configs
end

---@param cfg ModelConfig
---@param msgs Messages
---@return RequestBody
local function mk_request_body(cfg, msgs)
  return {
    model = cfg.name,
    messages = msgs,
    stream = true,
  }
end

---@param cfg ModelConfig
---@param body RequestBody
---@param handle_stream function
---@return nil
local function fetch(cfg, body, handle_stream)
  curl.post(cfg.url, {
    headers = {
      ['Content-Type'] = 'application/json',
      ['Authorization'] = 'Bearer ' .. cfg.api_key,
    },
    body = vim.json.encode(body),
    stream = handle_stream,
  })
end

---@param data string
--- Example data format:
---{
---  "object": "chat.completion.chunk",
---  "created": 1734165018,
---  "model": "models/gemini-2.0-flash-exp",
---  "choices": [
---    {
---      "index": 0,
---      "delta": {
---        "content": " am a large language model, trained by Google.\n",
---        "role": "assistant",
---        "tool_calls": []
---      },
---      "finish_reason": "stop"
---    }
---  ]
---}
---@return string
local function parse_stream(data)
  for line in data:gmatch '[^\r\n]+' do
    if line:match '^data: ' then
      local json_str = line:sub(7)
      local ok, decoded = pcall(vim.json.decode, json_str)
      if ok and decoded and decoded.choices then
        for _, choice in ipairs(decoded.choices) do
          if choice.delta and choice.delta.content then
            return choice.delta.content
          end
        end
      end
    end
  end
  return ''
end

local function ensure_buffer()
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    local buf_name = vim.api.nvim_buf_get_name(state.bufnr)
    if buf_name:match 'chatto$' then
      return
    end
  end

  local bufnr = nil
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match 'chatto$' then
      bufnr = buf
      break
    end
  end

  if bufnr then
    state.bufnr = bufnr
  else
    state.bufnr = vim.api.nvim_create_buf(false, true)
    local unique_name = string.format('%s/chatto', vim.fn.getcwd())
    pcall(vim.api.nvim_buf_set_name, state.bufnr, unique_name)
  end
end

local function create_window()
  vim.cmd 'botright vsplit'
  state.winid = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(state.winid, state.bufnr)
  vim.api.nvim_win_set_width(state.winid, math.floor(vim.o.columns * 0.35))
  vim.api.nvim_set_option_value('number', true, { win = state.winid })
  vim.api.nvim_set_option_value('relativenumber', true, { win = state.winid })
  vim.api.nvim_set_option_value('winfixwidth', true, { win = state.winid })
  vim.api.nvim_set_option_value('wrap', true, { win = state.winid })
  vim.api.nvim_set_option_value('linebreak', true, { win = state.winid })
  vim.api.nvim_buf_set_name(state.bufnr, 'chatto')
end

-- take current buffer input and turn to Messages
local function parse_buffer() end

local function append_buffer(chunk)
  vim.schedule_wrap(function()
    local last_line = vim.api.nvim_buf_get_lines(state.bufnr, -2, -1, false)[1] or ''

    if chunk:find '\n' then
      local lines = {}
      for line in chunk:gmatch '[^\n]+' do
        table.insert(lines, line)
      end
      if #lines > 0 then
        vim.api.nvim_buf_set_lines(state.bufnr, -2, -1, false, { last_line .. lines[1] })
        if #lines > 1 then
          vim.api.nvim_buf_set_lines(state.bufnr, -1, -1, false, { unpack(lines, 2) })
        end
      end
    else
      vim.api.nvim_buf_set_lines(state.bufnr, -2, -1, false, { last_line .. chunk })
    end
  end)()
end

M.setup = function()
  ensure_buffer()
  local cfgs_ = vim
    .iter({
      mk_model_configs(models, 'openrouter', key_names['openrouter']),
      mk_model_configs(models, 'aistudio', key_names['aistudio']),
    })
    :flatten()
    :totable()

  local cfgs = vim.tbl_filter(function(cfg)
    return cfg.api_key ~= nil
  end, cfgs_)
  local messages = { { role = 'user', content = 'tell me a bedtime story' } }
  local selected = cfgs[3]
  local request_body = mk_request_body(selected, messages)

  print(state.bufnr)
  local handle_stream = function(_, data)
    local chunk = parse_stream(data)

    if chunk ~= '' and state.bufnr then
      append_buffer(chunk)
    end
  end

  fetch(selected, request_body, handle_stream)

  -- // window related setups --

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
    complete = function()
      return { 'open', 'close', 'toggle' }
    end,
  })
end
return M
