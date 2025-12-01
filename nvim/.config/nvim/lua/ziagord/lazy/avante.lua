return {
    "yetone/avante.nvim",
    build = vim.fn.has("win32") ~= 0
        and "powershell -ExecutionPolicy Bypass -File Build.ps1 -BuildFromSource false"
        or "make",
    event = "VeryLazy",
    version = false, -- never "*"

    opts = (function()
        -- Determine host for WSL2 or native Windows
        local host = "localhost"

        local searxng_port = 8777
        local ollama_port = 11434

        -- Automatically start SearXNG Docker container if not running
        local handle = io.popen('docker ps -q -f name=searxng')
        local searxng_running = handle:read("*l")
        handle:close()

        local docker_files
        if vim.fn.has("wsl") ~= 0 then
            docker_files = "/mnt/c/.docker_files"
        else
            docker_files = "$HOME/.docker_files"
        end


        if not searxng_running then
            print("Starting SearXNG container on port " .. searxng_port .. "...")
            os.execute([[
                mkdir -p ./searxng/config ./searxng/data
                docker run --name searxng -d -p ]] .. searxng_port .. [[:8080 \
                -v "]] .. docker_files .. [[/searxng/config/:/etc/searxng/" \
                -v "]] .. docker_files .. [[/searxng/data/:/var/cache/searxng/" \
                docker.io/searxng/searxng:latest
            ]])
        end

        vim.fn.setenv("SEARXNG_API_URL", "http://" .. host .. ":" .. searxng_port .. "/search")

        return {
            instructions_file = "avante.md",
            provider = "copilot",

            web_search_engine = {
                provider = "searxng",
                proxy = nil,
            },

            rag_service = {
                enabled = true,
                host_mount = os.getenv("DEV_PATH"), -- Host mount path for the rag service (Docker will mount this path)
                runner = "docker", -- Runner for the RAG service (can use docker or nix)
                llm = { -- Configuration for the Language Model (LLM) used by the RAG service
                  provider = "ollama", -- The LLM provider ("ollama")
                  endpoint = "http://localhost:11434", -- The LLM API endpoint for Ollama
                  api_key = "", -- Ollama typically does not require an API key
                  model = "llama2", -- The LLM model name (e.g., "llama2", "mistral")
                  extra = nil, -- Extra configuration options for the LLM (optional) Kristin", -- Extra configuration options for the LLM (optional)
                },
                embed = { -- Embedding model configuration for RAG service
                    provider = "ollama", -- Embedding provider
                    endpoint = "http://" .. host .. ":" .. ollama_port, -- Embedding API endpoint
                    api_key = "", -- Environment variable name for the embedding API key
                    model = "nomic-embed-text", -- Embedding model name
                    extra = { -- Extra configuration options for the Embedding model (optional)
                      embed_batch_size = 10,
                    },
                },
                docker_extra_args = "", -- Extra arguments to pass to the docker command
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
