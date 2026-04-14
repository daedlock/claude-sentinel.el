# Claude Sentinel

> **Experimental** — This package was built for my personal setup (Doom Emacs + vterm + persp-mode). It works well for me but is not production-ready. Feel free to fork and adjust for your own workflow.

Monitor and manage [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI instances running in Emacs vterm buffers.

Claude Sentinel tracks the state of every Claude Code session across workspaces, providing a dashboard, modeline indicator, tabbed header-line, and desktop notifications — so you always know what your agents are doing.

## Features

### Dashboard (`claude-sentinel-dashboard`)
A tree-structured buffer grouping Claude instances by workspace.

- Collapsible workspace nodes with instance counts
- Animated spinner for working instances
- Duration display since last state change
- LLM-generated session summaries
- Jump to any instance with `RET`

**Keybindings:**
| Key   | Action                    |
|-------|---------------------------|
| `RET` | Jump to instance / toggle fold |
| `TAB` | Toggle workspace fold     |
| `d`   | Kill instance             |
| `g`   | Refresh                   |
| `q`   | Quit                      |

### Modeline (`claude-sentinel-modeline`)
A pre-cached modeline segment showing live status of all Claude instances.

- `⠂ 2/5` — 2 working out of 5 total
- `✳ 3` — 3 waiting for input
- Click to open the dashboard

Works with `doom-modeline` (as a named segment) and vanilla Emacs.

### Header-line tabs (`claude-sentinel-headerline`)
Tabbed header-line for Claude vterm buffers.

- Shows tabs only when 2+ instances share the same project
- Click tabs or use `M-]` / `M-[` to switch between sibling instances
- Auto-switches to sibling when a buffer is killed

### Notifications (`claude-sentinel-notify`)
Desktop notifications when instances change state.

- Notifies on `waiting` and `dead` states
- Multi-backend: D-Bus, `notify-send`, `message` fallback
- Debounced waiting notifications (default 3s) to avoid false alerts during tool calls

## States

Claude Sentinel tracks four states via vterm title changes (OSC sequences):

| State     | Meaning                        |
|-----------|--------------------------------|
| `working` | Claude is processing / running tools |
| `waiting` | Claude is waiting for user input |
| `shell`   | Shell prompt (Claude not active) |
| `dead`    | Buffer killed or process exited |

## Installation

### Doom Emacs

Add to `packages.el`:

```elisp
(package! claude-sentinel :recipe
  (:host github :repo "daedlock/claude-sentinel"))
```

Add to `config.el`:

```elisp
(use-package! claude-sentinel
  :config
  (claude-sentinel-mode 1)
  (claude-sentinel-dashboard-mode-global 1)
  (claude-sentinel-headerline-mode 1)
  (claude-sentinel-notify-mode 1))

;; Add modeline segment (doom-modeline)
(use-package! claude-sentinel-modeline
  :after doom-modeline
  :config
  (claude-sentinel-modeline-mode 1)
  (doom-modeline-def-segment claude-sentinel
    (claude-sentinel-modeline-string))
  ;; Add to your modeline layout:
  ;; (doom-modeline-def-modeline 'main
  ;;   '(... claude-sentinel ...))
  )

;; Keybindings
(map! :leader "c c" #'claude-sentinel-dashboard)
```

### Manual

Clone this repo and add to your `load-path`:

```elisp
(add-to-list 'load-path "/path/to/claude-sentinel")
(require 'claude-sentinel)
(claude-sentinel-mode 1)
```

## Requirements

- Emacs 28.1+
- [vterm](https://github.com/akermu/emacs-libvterm)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI

## LLM Summaries

Claude Sentinel can auto-generate short session titles using an LLM via [OpenRouter](https://openrouter.ai/). This requires an API key:

```elisp
(setq claude-sentinel-openrouter-api-key "sk-or-...")
```

Without this, instances will show their project name instead of a summary. The default model is Gemini 2.0 Flash (cheap and fast).

## Optional

- **Desktop notifications**: Requires D-Bus or `notify-send` on Linux.

## API

```elisp
(claude-sentinel-instances)     ; list of all tracked instances
(claude-sentinel-total-count)   ; total instance count
(claude-sentinel-working-count) ; working instance count
(claude-sentinel-waiting-count) ; waiting instance count
```

Each instance is a struct with fields: `buffer`, `project`, `workspace`, `state`, `state-changed-at`, `title`, `summary`.

## License

MIT
