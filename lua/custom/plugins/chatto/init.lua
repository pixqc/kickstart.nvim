local curl = require 'plenary.curl'
local M = {}

---@class Chatto.State
---@field winid integer|nil @ nvim window ID
---@field bufnr integer|nil @ nvim buffer number
---@field model_configs Chatto.ModelConfig[]|nil
---@field model_config_idx integer|nil
---@field debug_file file*|nil

---@alias Chatto.Endpoint "aistudio" | "openrouter" | "groq"
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
---@param stream_handler function
---@param error_handler function
---@return nil
local function fetch(cfg, body, stream_handler, error_handler)
  curl.post(cfg.url, {
    headers = {
      ['Content-Type'] = 'application/json',
      ['Authorization'] = 'Bearer ' .. cfg.api_key,
    },
    body = vim.json.encode(body),
    stream = stream_handler,
    on_error = error_handler,
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
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local messages = {}
  local current_role = nil
  local current_content = {}

  for _, line in ipairs(lines) do
    if line:match '^<user>%s*$' then
      if current_role and #current_content > 0 then
        table.insert(messages, {
          role = current_role,
          content = vim.trim(table.concat(current_content, '\n')),
        })
      end
      current_role = 'user'
      current_content = {}
    elseif line:match '^<assistant>%s*$' then
      if current_role and #current_content > 0 then
        table.insert(messages, {
          role = current_role,
          content = vim.trim(table.concat(current_content, '\n')),
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
      content = vim.trim(table.concat(current_content, '\n')),
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
  local stream_handler = function(_, data)
    log(state.debug_file, data)
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

  -- doens't work btw
  local error_handler = function(err)
    append_buffer(state.bufnr, err)
  end
  fetch(cfg, request_body, stream_handler, error_handler)
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
        name = 'meta-llama/llama-3.3-70b-instruct',
      },
      {
        url = 'https://openrouter.ai/api/v1/chat/completions',
        name = 'anthropic/claude-3.5-sonnet:beta',
      },
    },
    groq = {
      {
        url = 'https://api.groq.com/openai/v1/chat/completions',
        name = 'llama-3.1-8b-instant',
      },
    },
  }
  local key_names = {
    aistudio = 'GOOGLE_AISTUDIO_API_KEY',
    openrouter = 'OPENROUTER_API_KEY',
    groq = 'GROQ_API_KEY',
  }

  local cfgs_ = vim
    .iter({
      mk_model_configs(models, 'openrouter', key_names['openrouter']),
      mk_model_configs(models, 'aistudio', key_names['aistudio']),
      mk_model_configs(models, 'groq', key_names['groq']),
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
    elseif opts.args == 'switch' then
      local model_names = vim.tbl_map(function(cfg)
        return cfg.name
      end, state.model_configs)

      vim.ui.select(model_names, {
        prompt = 'Select model:',
        format_item = function(item)
          return item
        end,
      }, function(choice, idx)
        if choice then
          state.model_config_idx = idx
          if state.bufnr then
            local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, 1, false)
            lines[1] = string.format('model: %s', choice)
            vim.api.nvim_buf_set_lines(state.bufnr, 0, 1, false, lines)
          end
        end
      end)
    end
  end, {
    nargs = 1,
    complete = function()
      return { 'open', 'close', 'toggle', 'switch' }
    end,
  })

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
