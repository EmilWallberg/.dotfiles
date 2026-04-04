return {
  "ahmedkhalf/project.nvim",
  config = function()
    require("project_nvim").setup({
      -- Manual mode doesn't change the root automatically
      -- Set to false so it "just works" when you open a file
      manual_mode = false,

      -- Methods used to detect the project root
      detection_methods = { "lsp", "pattern" },

      -- Patterns to look for to identify a project root
      patterns = { ".git", "_darcs", ".hg", ".bzr", ".svn", "Makefile", "package.json", "go.mod" },

      -- Don't change directory if the current one is in this list
      ignore_lsp = {},

      -- Where to write the project history (used by Telescope)
      datapath = vim.fn.stdpath("data"),
    })
  end
}
