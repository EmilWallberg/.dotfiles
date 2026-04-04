return {
    "yetone/avante.nvim",
    build = vim.fn.has("win32") ~= 0
        and "powershell -ExecutionPolicy Bypass -File Build.ps1 -BuildFromSource false"
        or "make",
    event = "VeryLazy",
    version = false,

    opts = (function()
        local searxng_port = 8777
        local ollama_port = 11434
        local docker_files = vim.fn.expand("$HOME/.docker_files")

        -- Logic for SearXNG container
        local handle = io.popen('docker ps -q -f name=searxng')
        local searxng_running = handle:read("*l")
        handle:close()

        if not searxng_running then
            os.execute(string.format([[
                mkdir -p %s/searxng/config %s/searxng/data
                docker run --name searxng -d -p 127.0.0.1:%d:8080 \
                -v "%s/searxng/config/:/etc/searxng/" \
                -v "%s/searxng/data/:/var/cache/searxng/" \
                docker.io/searxng/searxng:latest
            ]], docker_files, docker_files, searxng_port, docker_files, docker_files))
        end

        vim.fn.setenv("SEARXNG_API_URL", "http://127.0.0.1:" .. searxng_port .. "/search")

        return {
            provider = "copilot",
            providers = {
                 ollama = {
                    endpoint = "http://127.0.0.1:" .. ollama_port,
                    model = "qwq:32b",
                  },
            },
            instructions_file = "avante.md",

            -- Integration Hooks for MCPHub
            system_prompt = function()
                local hub = require("mcphub").get_hub_instance()
                return hub:get_active_servers_prompt() or ""
            end,

            custom_tools = function()
                return {
                    require("mcphub.extensions.avante").mcp_tool(),
                }
            end,

            -- Disable built-ins to avoid duplication with MCP Neovim server
            disabled_tools = {
                "list_files", "search_files", "read_file", "create_file",
                "rename_file", "delete_file", "create_dir", "rename_dir",
                "delete_dir", "bash",
            },

            web_search_engine = {
                provider = "searxng",
                proxy = nil,
            },

            rag_service = {
                enabled = true,
                host_mount = os.getenv("DEV_PATH"),
                runner = "docker",
                llm = {
                    provider = "ollama",
                    endpoint = "http://127.0.0.1:" .. ollama_port,
                    model = "llama2",
                    api_key = "",
                },
                embed = {
                    provider = "ollama",
                    endpoint = "http://127.0.0.1:" .. ollama_port,
                    model = "nomic-embed-text",
                    api_key = "",
                    extra = { embed_batch_size = 10 },
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
