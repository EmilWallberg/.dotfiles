return {
    "zbirenbaum/copilot.lua",
    cmd = "Copilot",
    event = "InsertEnter",
    dependencies = {
        "copilotlsp-nvim/copilot-lsp", -- Required for the NES functionality you're using
    },
    config = function()
        -- 1. Initialize the core Copilot engine
        require("copilot").setup({
            -- You can add core copilot.lua options here
            auth_provider_url = os.getenv("GHE_URL") or "https://github.com/",
            suggestion = { enabled = false }, -- Disable built-in suggestions if using NES
            panel = { enabled = false },
        })

        -- 2. Configure Copilot NES variables
        vim.g.copilot_nes_debounce = 500
        -- Note: Ensure "copilot_ls" is handled by your LSP manager (like mason-lspconfig)
        -- or manually enabled if not using one:
        -- vim.lsp.enable("copilot_ls") 

        -- 3. Your custom Tab logic
        vim.keymap.set("n", "<tab>", function()
            local bufnr = vim.api.nvim_get_current_buf()
            local state = vim.b[bufnr].nes_state

            if state then
                -- NES Logic: Jump to start, or apply and jump to end
                local _ = require("copilot-lsp.nes").walk_cursor_start_edit()
                or (
                require("copilot-lsp.nes").apply_pending_nes()
                and require("copilot-lsp.nes").walk_cursor_end_edit()
            )
                return nil
            else
                -- Fallback to jump forward in changelist (C-i)
                return "<C-i>"
            end
        end, { desc = "Accept Copilot NES suggestion", expr = true, silent = true })
    end,
}
