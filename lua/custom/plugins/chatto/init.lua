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
--  example data: data: {"object":"chat.completion.chunk","created":1734165018,"model":"models/gemini-2.0-flash-exp","choices":[{"index":0,"delta":{"content":" am a large language model, trained by Google.\n","role":"assistant","tool_calls":[]},"finish_reason":"stop"}]}
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

M.setup = function()
  local all_configs = vim
    .iter({
      mk_model_configs(models, 'openrouter', key_names['openrouter']),
      mk_model_configs(models, 'aistudio', key_names['aistudio']),
    })
    :flatten()
    :totable()

  local cfgs = vim.tbl_filter(function(cfg)
    return cfg.api_key ~= nil
  end, all_configs)
  local selected = cfgs[3]

  local messages = { { role = 'user', content = 'tell me a bedtime story' } }
  local request_body = mk_request_body(selected, messages)
  print(vim.inspect(selected))
  print(vim.inspect(request_body))

  local handle_stream = function(_, data)
    local chunk = parse_stream(data)
    local log_file = io.open('/tmp/abcd.log', 'a')
    if not log_file then
      error 'Could not open log file'
    end
    if log_file then
      log_file:write(os.date '%Y-%m-%d %H:%M:%S' .. ': ' .. chunk .. '\n')
      log_file:flush()
    end
  end

  fetch(selected, request_body, handle_stream)
end

return M
