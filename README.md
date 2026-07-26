# agent-pulse

**Know which AI agent needs you, without hunting through panes.**

Run five agents across tmux windows and the hard part stops being launching
them. It becomes knowing, at a glance, which one finished, which one is still
working, and which one is sitting there waiting on your answer.

agent-pulse turns agent lifecycle events into a colour in your tab bar.

```
  1 api ○      2 review ●      3 notes
    working      blocked         idle
```

## Design

Four rules, in order of importance. Everything else follows from them.

**1. Semantic events only.** Agents already announce what they are doing. We
translate those announcements; we never infer "finished" from a quiet terminal.
A silent pane might be thinking.

**2. Out-of-order events must not win.** Hooks fire from independent processes,
so a slow `working` can land after a fast `idle`. Every report carries a
monotonic sequence number and anything older than what the pane already recorded
is dropped. Without this, a late event silently corrupts the state.

**3. State lives on the pane; the window is a rollup.** tmux garbage-collects
pane options when the pane dies, so state cannot outlive the agent that owned
it. A window shows its worst pane: `error > blocked > working > idle`.

**4. Never nag about what you are already looking at.** Alerts fire on real
transitions, and only for panes that are off screen.

### States

| State | Meaning | You should |
|---|---|---|
| `working` | busy, making progress | nothing |
| `blocked` | waiting on your answer | go now |
| `error`   | it failed | go look |
| `idle`    | finished its turn | pick up the result |

## Install

### Nix (home-manager)

```nix
{
  inputs.agent-pulse.url = "github:FullFran/agent-pulse";

  # in your home-manager modules:
  imports = [ inputs.agent-pulse.homeManagerModules.default ];

  programs.agent-pulse = {
    enable = true;
    opencode.enable = true;   # installs the OpenCode plugin
  };
}
```

Then source the tmux layer at the **end** of your tmux config, after your theme:

```tmux
source-file ~/.config/agent-pulse/tmux/agents.conf
```

### Without Nix

Clone it, put `scripts/` on your `PATH`, and source `tmux/agents.conf`.

## Wiring your agents

Everything funnels through one entry point. Adapters translate; `agent-report`
decides.

```
opencode plugin ─┐
Claude Code hook ─┼─→ agent-report ─→ tmux pane state ─→ window rollup ─→ tab bar
Codex hook      ─┘                                   └─→ sound + message
```

**Any agent, from a shell:**

```sh
agent-report working
agent-report blocked "needs permission to write"
agent-report idle
```

**Claude Code / Codex** — point the hooks at the adapter, passing the event name:

```json
{
  "hooks": {
    "Stop":             [{ "hooks": [{ "type": "command", "command": "hook-adapter Stop" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "hook-adapter Notification" }] }],
    "PreToolUse":       [{ "hooks": [{ "type": "command", "command": "hook-adapter PreToolUse" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "hook-adapter UserPromptSubmit" }] }]
  }
}
```

**OpenCode** — the module installs the plugin; otherwise copy
`adapters/opencode/agent-pulse.js` into your plugins directory.

## Rendering

The tmux layer enables **behaviour** by default and leaves your status line
alone, because overwriting `window-status-format` throws away whatever your
theme built. Read `@win_agent_state` wherever you want the marker:

```tmux
#{?#{==:#{@win_agent_state},blocked}, #[fg=red]●#[default],\
#{?#{==:#{@win_agent_state},working}, #[fg=yellow]○#[default],}}
```

Or set `@agent_pulse_auto_format on` before sourcing to get a plain layout.

| Option | Scope | Contents |
|---|---|---|
| `@agent_state` | pane | this pane's state |
| `@agent_msg` | pane | optional label, e.g. the permission text |
| `@agent_seq` | pane | monotonic sequence, internal |
| `@win_agent_state` | window | worst state across the window's panes |
| `@agent_pulse_idle_ttl` | global | seconds before a finished pane is forgotten (default 1800, 0 disables) |
| `@session_agent_state` | session | worst state across the session's windows |

### Across sessions

The tab bar answers "which window here needs me". Once you are running agents in
several sessions, the question changes to "which of my sessions needs me at
all", and no tab bar can answer that — the other sessions are not on screen.

`agent-sessions` answers it, derived from live tmux options rather than a file
in `/tmp`, so there is nothing to leave stale and it survives a server restart.

```sh
agent-sessions                                  # ●api ○review ◐notes
agent-sessions --only-attention                 # just the ones that need you
agent-sessions --format marked --only-attention # "● api", for a picker
agent-sessions --format plain                   # "blocked<TAB>api", for scripts
```

In a status line, and in a session picker:

```tmux
set -g status-right "#(agent-sessions) | %H:%M"

bind -n C-S-s display-popup -E "agent-sessions --format marked \
  | fzf --prompt='session > ' | awk '{print \$NF}' | xargs -r tmux switch-client -t"
```

## The hole this does not fill

Event pipelines have one structural weakness: **some transitions emit no event
at all.** Cancel a permission prompt and no hook fires, so the pane would stay
`blocked` forever.

agent-pulse treats *looking at the window* as the missing event — navigation
hooks clear attention states you have demonstrably seen. That recovers from
missed **clears**.

Finished panes also age out. A window you never visit would otherwise keep its
marker indefinitely, so `idle` is cleared once it is older than
`@agent_pulse_idle_ttl` seconds (30 minutes by default, `0` disables it):

```tmux
set -g @agent_pulse_idle_ttl 900   # forget finished agents after 15 minutes
```

Only `idle` ages out. `blocked` and `error` are open requests and stay until
answered — an agent can legitimately wait an hour for you, and dropping that
silently is worse than a stale marker. No timer is involved: every run walks
every pane, so any navigation anywhere sweeps stale markers everywhere.

It does **not** recover from missed **sets**. If an agent dies without emitting
anything, its pane keeps whatever it last reported. The robust fix is
screen-tail detection — periodically reading each pane's output and matching
per-agent patterns. [herdr](https://github.com/ogulcancelik/herdr) implements
this properly in Rust, with arbitration between the two sources. If you want
that guarantee today, use herdr; it is a better tool for that job than a bash
reimplementation would be.

## Testing

```sh
tests/run.sh
```

Runs against a throwaway tmux server on its own socket. Every behaviour worth
testing here is tmux semantics, so mocking tmux would only test the mock.

## Prior art, honestly

This grew out of my own dotfiles, where the first version was a bell and a
yellow tab. Two projects shaped what it became, and both deserve the credit:

- **[herdr](https://github.com/ogulcancelik/herdr)** (Rust, agent multiplexer) —
  the source of the hybrid state model: rich states rather than a done flag, and
  sequence-based arbitration between reports. I read its `detect.rs` and hook
  assets as a reference and ported the *ideas* into bash. I did not adopt herdr
  itself, because I already have tmux; if you would rather have the whole tool,
  it is excellent.
- **[gentle-agent-state](https://github.com/Gentleman-Programming/gentle-agent-state)**
  by Gentleman Programming — arrived at the same problem independently and
  solved several parts better than I had. Pane-level state with a window rollup,
  alerting only on transitions, and healing state when you look at a pane are
  all patterns I took from it after comparing implementations. It also supports
  Zellij and native Ghostty, which this does not.

What is mine: the semantic-events-only rule from the start, the monotonic
sequence guard, and `error` as a state distinct from `idle`.

## License

Apache-2.0
