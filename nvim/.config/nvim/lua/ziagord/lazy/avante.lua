return {
    "yetone/avante.nvim",
    build = vim.fn.has("win32") ~= 0
        and "powershell -ExecutionPolicy Bypass -File Build.ps1 -BuildFromSource false"
        or "make",
    event = "VeryLazy",
    version = false, -- never "*"

    opts = (function()
        -- Determine host for WSL2 or native Windows
        local host
        if vim.fn.has("wsl") ~= 0 then
            local handle = io.popen("ip route | awk '/default/ {print $3}'")
            host = handle:read("*l")
            handle:close()
        else
            host = "localhost"
        end

        return {
            instructions_file = "avante.md",
            provider = "ollama",
            providers = {
                ollama = {
                    endpoint = "http://" .. host .. ":11434",
                    model = "qwen2.5-coder",
                },
            },
        }
    end)(),

    dependencies = {
        "nvim-lua/plenary.nvim",
        "MunifTanjim/nui.nvim",
        "echasnovski/mini.pick",
        "nvim-telescope/telescope.nvim",
        "hrsh7th/nvim-cmp",
        "ibhagwan/fzf-lua",
        "stevearc/dressing.nvim",
        "folke/snacks.nvim",
        "nvim-tree/nvim-web-devicons",
        "zbirenbaum/copilot.lua",
        {
            "HakonHarnes/img-clip.nvim",
            event = "VeryLazy",
            opts = {
                default = {
                    embed_image_as_base64 = false,
                    prompt_for_file_name = false,
                    drag_and_drop = { insert_mode = true },
                    use_absolute_path = true,
                },
            },
        },
        {
            "MeanderingProgrammer/render-markdown.nvim",
            ft = { "markdown", "Avante" },
            opts = { file_types = { "markdown", "Avante" } },
        },
    },
}
