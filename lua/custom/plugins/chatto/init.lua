local curl = require 'plenary.curl'
local M = {}

---@class Chatto.State
---@field winid integer|nil @ nvim window ID
---@field bufnr integer|nil @ nvim buffer number
---@field model_configs Chatto.ModelConfig[]|nil
---@field model_config_idx integer|nil
---@field debug_file file*|nil

---@alias Chatto.Endpoint "aistudio" | "openrouter"
---@alias Chatto.Role "user" | "assistant" | "system"

---@class Chatto.Messages
---@field messages { role: Chatto.Role, content: string }[] @ must NonEmpty

---@class Chatto.ModelConfig
---@field url string
---@field name string
---@field api_key string @ from IO: must NonEmpty

---@class Chatto.RequestBody
---@field model string
---@field messages Chatto.Messages
---@field stream boolean

---@param f file*
---@param thing string
---@return nil
local function log(f, thing)
  local timestamp = os.date '%Y-%m-%d %H:%M:%S'
  f:write(string.format('[%s] %s\n', timestamp, thing))
  f:flush()
end

---@param bufnr integer
---@return integer winid
local function create_window(bufnr)
  vim.cmd 'botright vsplit'
  local winid = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.api.nvim_win_set_width(winid, math.floor(vim.o.columns * 0.35))
  vim.api.nvim_set_option_value('number', true, { win = winid })
  vim.api.nvim_set_option_value('relativenumber', true, { win = winid })
  vim.api.nvim_set_option_value('winfixwidth', true, { win = winid })
  vim.api.nvim_set_option_value('wrap', true, { win = winid })
  vim.api.nvim_set_option_value('linebreak', true, { win = winid })
  vim.api.nvim_buf_set_name(bufnr, 'chatto')

  return winid
end

---@param model_name string
---@return integer
local function ensure_buffer(model_name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match 'chatto$' then
      vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
      return buf -- existing buffer
    end
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  local name = string.format('%s/chatto', vim.fn.getcwd())
  vim.api.nvim_buf_set_name(bufnr, name)
  local initial_content = string.format('model: %s\n\n<user>\n', model_name)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(initial_content, '\n'))
  return bufnr -- create new buffer, return bufnr
end

---@param models_ table<string, {url: string, name: string}[]>
---@param endpoint_ Chatto.Endpoint
---@param key_name string
---@return Chatto.ModelConfig[]
local function mk_model_configs(models_, endpoint_, key_name)
  local configs = {}
  for _, model in pairs(models_[endpoint_]) do
    table.insert(configs, {
      url = model.url,
      name = model.name,
      api_key = os.getenv(key_name),
    })
  end
  return configs
end

---@param cfg Chatto.ModelConfig
---@param msgs Chatto.Messages
---@return Chatto.RequestBody
local function mk_request_body(cfg, msgs)
  return {
    model = cfg.name,
    messages = msgs,
    stream = true,
  }
end

---@param cfgs Chatto.ModelConfig[]
---@param cfg_idx integer
---@return Chatto.State
local function mk_state(cfgs, cfg_idx)
  local f, err = io.open('/tmp/chatto.log', 'a')
  if not f then
    vim.notify('Failed to open chatto.log: ' .. err, vim.log.levels.WARN)
    f = nil
  end

  return {
    winid = nil,
    bufnr = ensure_buffer(cfgs[cfg_idx].name),
    model_configs = cfgs,
    model_config_idx = cfg_idx,
    debug_file = f,
  }
end

---@param cfg Chatto.ModelConfig
---@param body Chatto.RequestBody
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

---@param bufnr integer @ guaranteed nonempty
---@return Chatto.Messages
local function parse_buffer(bufnr)
  local function trim(s)
    return s:match '^%s*(.-)%s*$'
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local messages = {}
  local current_role = nil
  local current_content = {}

  for _, line in ipairs(lines) do
    if line:match '^<user>%s*$' then
      if current_role and #current_content > 0 then
        table.insert(messages, {
          role = current_role,
          content = trim(table.concat(current_content, '\n')),
        })
      end
      current_role = 'user'
      current_content = {}
    elseif line:match '^<assistant>%s*$' then
      if current_role and #current_content > 0 then
        table.insert(messages, {
          role = current_role,
          content = trim(table.concat(current_content, '\n')),
        })
      end
      current_role = 'assistant'
      current_content = {}
    elseif current_role then
      table.insert(current_content, line)
    end
  end

  if current_role and #current_content > 0 then
    table.insert(messages, {
      role = current_role,
      content = trim(table.concat(current_content, '\n')),
    })
  end

  return messages
end

---@param bufnr integer
---@param chunk string
---@return nil
local function append_buffer(bufnr, chunk)
  vim.schedule(function()
    local last_line = vim.api.nvim_buf_get_lines(bufnr, -2, -1, false)[1] or ''
    local lines = vim.split(last_line .. chunk, '\n', { plain = true })
    vim.api.nvim_buf_set_lines(bufnr, -2, -1, false, lines)
  end)
end

---@param state Chatto.State
---@param messages Chatto.Messages
---@return nil
local function chat(state, messages)
  local cfg = state.model_configs[state.model_config_idx]
  local request_body = mk_request_body(cfg, messages)
  append_buffer(state.bufnr, '\n\n<assistant>\n\n')
  local handle_stream = function(_, data)
    local chunk = parse_stream(data)
    if chunk ~= '' and state.bufnr then
      append_buffer(state.bufnr, chunk)
    end

    if data:match 'data: %[DONE%]' then
      vim.schedule(function()
        append_buffer(state.bufnr, '\n<user>\n')
      end)
    end
  end
  fetch(cfg, request_body, handle_stream)
end

M.setup = function()
  local models = {
    aistudio = {
      {
        url = 'https://generativelanguage.googleapis.com/v1beta/chat/completions',
        name = 'gemini-2.0-flash-exp',
      },
    },
    openrouter = {
      {
        url = 'https://openrouter.ai/api/v1/chat/completions',
        name = 'meta-llama/llama-3.2-1b-instruct',
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

  local state = mk_state(cfgs, 3)

  -- // window related setups --

  vim.api.nvim_create_user_command('Chatto', function(opts)
    if opts.args == 'open' then
      if not (state.winid and vim.api.nvim_win_is_valid(state.winid)) then
        state.winid = create_window(state.bufnr)
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
        state.winid = create_window(state.bufnr)
      end
    end
  end, {
    nargs = 1,
    complete = function()
      return { 'open', 'close', 'toggle' }
    end,
  })

  -- // keymaps --

  if state.bufnr then
    vim.api.nvim_buf_set_keymap(state.bufnr, 'n', '<CR>', '', {
      callback = function()
        local messages = parse_buffer(state.bufnr)
        if messages then
          chat(state, messages)
        end
      end,
      noremap = true,
      silent = true,
    })
  end
end

return M
