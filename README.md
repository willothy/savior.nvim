# Savior.nvim

Hassle-free autosaving plugin for Neovim. It just works, and it gives you nice notifications when things are being saved.

Saves are performed on a set interval as well as based on events, and can be immediate or deferred depending on the event.

Before saving, each buffer goes through a list of predicates that determine whether it is safe to save. If any of these conditions fails,
the buffer is not saved. The events, conditions and delays can all be easily customized.

Features:

- Event-based autosaving, both deferred and immediate
- Interval-based autosaving
- Condition stack to determine if it is safe to save
- Pretty notifications using `fidget.nvim`
- Written with performance in mind

Requires `fidget.nvim`.

## Installation

with `folke/lazy.nvim`:

```lua
local spec = {
  "willothy/savior.nvim",
  dependencies = { "j-hui/fidget.nvim" },
  event = { "InsertEnter", "TextChanged" },
  config = true
}
```

## Configuration

savior comes with the following defaults:

```lua
local savior = require("savior")

savior.setup({
  events = {
    immediate = {
      "FocusLost",
      "BufLeave",
    },
    deferred = {
      "InsertLeave",
      "TextChanged",
    },
    cancel = {
      "InsertEnter",
      "BufWritePost",
      "TextChanged",
    },
  },
  callbacks = {},
  conditions = {
    savior.conditions.is_file_buf,
    savior.conditions.not_of_filetype({
      "gitcommit",
      "gitrebase",
    }),
    savior.conditions.is_named,
    savior.conditions.file_exists,
    savior.conditions.has_no_errors,
  },
  throttle_ms = 3000,
  interval_ms = 30000,
  defer_ms = 1000
})
```

## Builtin conditions

Conditions have the signature `fun(buf: bufnr): boolean`.

The builtin conditions are:

```lua
-- Ensures that `b:buftype == ""`
function conditions.is_file_buf(bufnr)
end
```

```lua
-- Ensures that a buffer is modified before saving
function conditions.is_modified(bufnr)
end
```

```lua
-- Ensures that a buffer is listed before saving
function conditions.is_listed(bufnr)
end
```

```lua
-- Ensures that the buffer is named (even though vim will do this anyways, we want to silence the warning)
function conditions.is_named(bufnr)
end
```

```lua
-- Ensures that the buffer has no diagnostic / LSP errors before saving
function conditions.has_no_errors(bufnr)
end
```

```lua
-- Checks if the buffer's underlying file exists before writing
function conditions.file_exists(bufnr)
end
```

```lua
-- This is a special condition that is created dynamically based on the filetypes provided.
-- It ensures that autosaves aren't run on files of the provided types.
-- Example shown in the default config.
--
---@type fun(filetypes: string[]): fun(buf: bufnr):boolean
function conditions.not_of_filetype(filetypes)
  return function(bufnr)
    -- ...
  end
end
```
