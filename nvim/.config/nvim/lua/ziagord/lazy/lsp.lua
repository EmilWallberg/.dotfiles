local root_markers = {
    '.luarc.json',
    '.luarc.jsonc',
    '.luacheckrc',
    '.stylua.toml',
    'stylua.toml',
    'selene.toml',
    'selene.yml',
    '.git',
}


return {
    "neovim/nvim-lspconfig",
    dependencies = {
        "stevearc/conform.nvim",
        "williamboman/mason.nvim",
        "williamboman/mason-lspconfig.nvim",
        "hrsh7th/cmp-nvim-lsp",
        "hrsh7th/cmp-buffer",
        "hrsh7th/cmp-path",
        "hrsh7th/cmp-cmdline",
        "hrsh7th/nvim-cmp",
        "L3MON4D3/LuaSnip",
        "saadparwaiz1/cmp_luasnip",
        "j-hui/fidget.nvim",
        "zbirenbaum/copilot.lua",
        "copilotlsp-nvim/copilot-lsp",
        (vim.fn.has 'win32' == 1 or vim.fn.has 'wsl' == 1)
            and { 'GrzegorzKozub/ahk.nvim' } or {},
    },

    config = function()
        require("conform").setup({
                    formatters_by_ft = {
                        Lua = { "stylua" },
                        Gdscript = { "gdtoolkit" },
                    }
                })

        local cmp = require('cmp')
        local cmp_lsp = require("cmp_nvim_lsp")
        local capabilities = vim.tbl_deep_extend(
                "force",
                {},
                vim.lsp.protocol.make_client_capabilities(),
                cmp_lsp.default_capabilities()
                )

        require("fidget").setup({})
        require("mason").setup()
        require("mason-lspconfig").setup({
                ensure_installed = { "lua_ls" },
                })


    -- Diagnostics defaults
        local diagnostics_below = false
        vim.diagnostic.config({
                virtual_lines = false,
                float = {
                focusable = false,
                style = "minimal",
                border = "rounded",
                source = "always",
                header = "",
                prefix = "",
                max_width = 80,
                wrap = true,
                },
                })


    -- on_attach for keymaps and toggle

        local on_attach = function(client, bufnr)
        local bufopts = { noremap=true, silent=true, buffer=bufnr }

        -- Rename
        vim.keymap.set('n', '<leader>lr', vim.lsp.buf.rename, bufopts)
        -- Jump to definition
        vim.keymap.set('n', '<leader>ld', vim.lsp.buf.definition, bufopts)
        -- Hover diagnostics
        vim.keymap.set('n', '<leader>lh', vim.diagnostic.open_float, bufopts)
        -- Toggle inline ↔ below-line diagnostics
        vim.keymap.set('n', '<leader>lt', function()
                diagnostics_below = not diagnostics_below
                vim.diagnostic.config({
                    virtual_lines = diagnostics_below,
                    })

                print("Diagnostics mode:", diagnostics_below and "Below line" or "Inline")
                end, bufopts)
        end

        -- Lua LSP

        vim.lsp.config('lua_ls', {
                cmd = { 'lua-language-server' },
                filetypes = { 'lua' },
                root_markers = root_markers,
                settings = {
                Lua = {
                    format = {
                        enable = true,
                            defaultConfig = {
                                indent_style = "space",
                                indent_size = "2",
                            }
                        },
                    }
                },
                capabilities = capabilities,
                on_attach = on_attach,
        })


    -- GDScript LSP

        vim.lsp.config('gdscript', {
                cmd = { 'godot-wsl-lsp', '--useMirroredNetworking' },
                filetypes = { 'gdscript' },
                root_markers = { 'project.godot', '.git' },
                capabilities = capabilities,
                on_attach = on_attach,
                })


    -- Enable configured servers

        vim.lsp.enable({ 'lua_ls', 'gdscript' })

        -- CMP setup

        local cmp_select = { behavior = cmp.SelectBehavior.Select }

    cmp.setup({
            snippet = {
            expand = function(args)
            require('luasnip').lsp_expand(args.body)
            end,
            },


            mapping = cmp.mapping.preset.insert({
                    ['<C-p>'] = cmp.mapping.select_prev_item(cmp_select),
                    ['<C-n>'] = cmp.mapping.select_next_item(cmp_select),
                    ['<Tab>'] = cmp.mapping.confirm({ select = true }),
                    ['<C-Space>'] = cmp.mapping.complete(),
                    }),

            sources = cmp.config.sources({
                    { name = "copilot", group_index = 2 },
                    { name = 'nvim_lsp' },
                    { name = 'luasnip' },
                    }, {
                    { name = 'buffer' },
                    })
    })
    end
} 
