vim.g.transparent_enabled = true

-- 1. Updated Function: Now handles the toggle logic and re-application
function ColorMyPencils(color)
    color = color or "catppuccin-mocha"
    
    -- Ensure the global variable exists so themes don't error out
    if vim.g.transparent_enabled == nil then
        vim.g.transparent_enabled = false
    end

    vim.cmd.colorscheme(color)
end

-- 2. Toggle Command: Add this so you can swap on the fly
-- Usage: Type :ToggleTransparency in command mode
    vim.api.nvim_create_user_command("ToggleTransparency", function()
    vim.g.transparent_enabled = not vim.g.transparent_enabled
    
    -- Re-run ColorMyPencils to refresh the theme with the new variable state
    ColorMyPencils(vim.g.colors_name)
    
    -- If using xiyaowong/transparent.nvim, tell it to sync up
    local status, transparent = pcall(require, "transparent")
    if status then
        if vim.g.transparent_enabled then
            transparent.clear()
        else
            -- There isn't a native 'unclear', so we just re-source the theme
            vim.cmd("colorscheme " .. vim.g.colors_name)
        end
    end
end, {})

return {
    {
        "xiyaowong/transparent.nvim",
        config = function()
            require("transparent").setup({
                extra_groups = {
                    "NormalFloat", 
                },
            })
        end
    },
    { 
        "catppuccin/nvim", 
        name = "catppuccin", 
        priority = 1000,
        config = function()
            require("catppuccin").setup({
                flavour = "auto",
                -- This will now update correctly when ColorMyPencils is called
                transparent_background = vim.g.transparent_enabled, 
                integrations = {
                    cmp = true,
                    gitsigns = true,
                    nvimtree = true,
                    treesitter = true,
                },
            })
        end
    },
    {
        "folke/tokyonight.nvim",
        config = function()
            require("tokyonight").setup({
                style = "moon",
                -- Respects the toggle
                transparent = vim.g.transparent_enabled, 
                styles = {
                    sidebars = "dark",
                    floats = "dark",
                },
            })
            ColorMyPencils()
        end
    },
    {
        "rose-pine/neovim",
        name = "rose-pine",
        config = function()
            require('rose-pine').setup({
                -- For Rose Pine, we link this to our variable
                disable_background = vim.g.transparent_enabled,
            })
            ColorMyPencils()
        end
    },
}
