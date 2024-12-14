local curl = require 'plenary.curl'
local M = {}

local state = {
  winid = nil,
  bufnr = nil,
}

---@alias Endpoint "aistudio" | "openrouter"
---@alias MessageRole "user" | "assistant" | "system"

---@class Message
---@field messageRole MessageRole
---@field messageContent string

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
    stream = false,
  }
end

---@param cfg ModelConfig
---@param body RequestBody
---@return table
local function fetch(cfg, body)
  local response = curl.post(cfg.url, {
    headers = {
      ['Content-Type'] = 'application/json',
      ['Authorization'] = 'Bearer ' .. cfg.api_key,
    },
    body = vim.json.encode(body),
  })

  if response.status ~= 200 then
    error(string.format('Request failed with status %d: %s', response.status, response.body))
  end

  return vim.json.decode(response.body)
end

M.setup = function()
  local all_configs = vim
    .iter({
      mk_model_configs(models, 'openrouter', key_names['openrouter']),
      mk_model_configs(models, 'aistudio', key_names['aistudio']),
    })
    :flatten()
    :totable()

  local valid_configs = vim.tbl_filter(function(cfg)
    return cfg.api_key ~= nil
  end, all_configs)

  print(vim.inspect(valid_configs))

  local messages = { { messageRole = 'user', messageContent = 'hi, who r u' } }
  local request_body = mk_request_body(valid_configs[1], messages)
  print(vim.inspect(request_body))

  local response = fetch(valid_configs[1], request_body)
  print(vim.inspect(response))
end
return M
