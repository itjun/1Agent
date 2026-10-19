import { readFileSync, writeFileSync, renameSync } from "node:fs";
import { dirname, join } from "node:path";

// Loaded only for this terminal invocation. No global Pi/OMP extension installation.
export default function (api) {
  const record = (_event, ctx) => {
    try {
      const env = process.env;
      if (!ctx.hasUI) return;
      if (env.ONEAGENT_AGENT_KIND === "omp" && (ctx.mode !== "tui" || ctx.agent?.kind !== "main")) return;
      const invocation = JSON.parse(readFileSync(env.ONEAGENT_AGENT_STATE, "utf8"));
      if (invocation.invocationID.toUpperCase() !== env.ONEAGENT_AGENT_INVOCATION.toUpperCase()) return;
      const sessionFile = ctx.sessionManager.getSessionFile();
      const sessionID = ctx.sessionManager.getSessionId();
      if (!sessionFile || !sessionID) return;
      const storageEnvironment = {};
      for (const key of ["PI_CODING_AGENT_DIR", "PI_AGENT_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME"]) {
        if (env[key]) storageEnvironment[key] = env[key];
      }
      const value = { kind: env.ONEAGENT_AGENT_KIND, sessionID, sessionFile,
        directory: ctx.cwd, executable: env.ONEAGENT_AGENT_EXECUTABLE, storageEnvironment };
      const destination = join(dirname(env.ONEAGENT_AGENT_STATE), invocation.invocationID + ".json");
      const temporary = destination + ".tmp";
      writeFileSync(temporary, JSON.stringify(value), { mode: 0o600 });
      renameSync(temporary, destination);
    } catch { /* An unavailable adapter must never interfere with the Agent. */ }
  };
  api.on("session_start", record);
  api.on("agent_end", record);
  if (process.env.ONEAGENT_AGENT_KIND === "omp") api.on("session_switch", record);
}
