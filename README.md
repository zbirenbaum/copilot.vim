# Copilot.vim

GitHub Copilot is an AI pair programmer which suggests line completions and
entire function bodies as you type. GitHub Copilot is powered by the OpenAI
Codex AI system, trained on public Internet text and billions of lines of
code.  Copilot.vim is a Vim plugin for GitHub Copilot.

To learn more about GitHub Copilot, visit copilot.github.com.

## Getting started

Copilot.vim requires a [recent prerelease build of
Neovim](https://github.com/neovim/neovim/releases). [Node 12 or
newer](https://nodejs.org/en/download/) is also required.

Install the plugin by cloning the repository into Neovim's package path (or
use any package manager):

    git clone https://github.com/github/copilot.vim.git \
      ~/.config/nvim/pack/github/start/copilot.vim

To authenticate and enable GitHub Copilot, invoke `:Copilot setup`.
