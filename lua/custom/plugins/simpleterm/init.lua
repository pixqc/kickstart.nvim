local M = {}

M.setup = function(opts)
  opts = opts or {}

  local function toggle_terminal()
    local term_bufnr = vim.fn.bufnr 'term://'
    if term_bufnr ~= -1 then
      local term_winnr = vim.fn.bufwinnr(term_bufnr)
      if term_winnr ~= -1 then
        vim.cmd(term_winnr .. 'close')
      else
        vim.cmd 'split'
        vim.cmd 'wincmd j'
        vim.cmd('buffer ' .. term_bufnr)
        vim.cmd('resize ' .. math.floor(vim.o.lines * 0.3))
        vim.cmd 'setlocal wrap'
        vim.cmd 'setlocal noscrollbind'
      end
    else
      vim.cmd 'split'
      vim.cmd 'wincmd j'
      vim.cmd 'terminal'
      vim.cmd('resize ' .. math.floor(vim.o.lines * 0.3))
      vim.cmd 'startinsert'
      vim.cmd 'setlocal wrap'
      vim.cmd 'setlocal noscrollbind'
    end
  end

  vim.keymap.set('n', opts.toggle_key or '<C-\\>', toggle_terminal, { desc = 'Toggle Terminal' })
  vim.keymap.set('t', opts.toggle_key or '<C-\\>', '<cmd>close<CR>', { desc = 'Close Terminal' })
  vim.keymap.set('t', 'kj', '<C-\\><C-n>', { noremap = true })
  vim.keymap.set('t', 'KJ', '<C-\\><C-n>', { noremap = true })
  vim.keymap.set('t', 'Kj', '<C-\\><C-n>', { noremap = true })
  vim.keymap.set('t', 'kJ', '<C-\\><C-n>', { noremap = true })
end

return M
