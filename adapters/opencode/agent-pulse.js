/**
 * agent-pulse — OpenCode adapter.
 *
 * Translates OpenCode plugin events into the canonical vocabulary and hands
 * them to agent-report. It knows nothing about tmux; that is agent-report's job.
 *
 * Resolution order for the binary:
 *   1. $AGENT_PULSE_BIN            explicit override
 *   2. agent-report on $PATH       normal install
 *   3. ~/.config/agent-pulse/scripts/agent-report
 *
 * Notification plumbing must never take OpenCode down with it, so every failure
 * path here is swallowed on purpose.
 */
import { execFile } from "node:child_process"
import { existsSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const resolveBin = () => {
  if (process.env.AGENT_PULSE_BIN) return process.env.AGENT_PULSE_BIN
  const fallback = join(homedir(), ".config", "agent-pulse", "scripts", "agent-report")
  if (existsSync(fallback)) return fallback
  return "agent-report" // let PATH resolve it
}

const bin = resolveBin()

const report = (state, message = "") => {
  try {
    const child = execFile(bin, [state, message], { timeout: 3000 }, () => {})
    child.on("error", () => {})
  } catch {
    // deliberately ignored
  }
}

export const AgentPulse = async () => ({
  event: async ({ event }) => {
    if (!event?.type) return

    switch (event.type) {
      case "session.idle":
        report("idle")
        return
      case "session.error":
        report("error")
        return
      case "session.status": {
        const status = event.properties?.status?.type
        if (status === "idle") report("idle")
        if (status === "busy" || status === "retry") report("working")
        return
      }
      case "permission.updated":
      case "permission.replied":
        report("blocked")
        return
      default:
        return
    }
  },

  "chat.message": async () => {
    report("working")
  },

  "permission.ask": async (input) => {
    report("blocked", input?.permission?.title ?? "")
  },
})

export default AgentPulse
