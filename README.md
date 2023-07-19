# Savior.nvim

> **Note** <br>
> This plugin is in a relatively early state, and while it has been relatively
> stable there may be some bugs.

Features:

- Event-based autosaving, both deferred and immediate
- Interval-based autosaving
- Condition stack to determine if it is safe to save
- Pretty notifications by hooking into Neovim's builtin LSP client
  - As an added bonus, the `notify` method is exported so you can
    make your own LSP status notifications
- Written with performance in mind
