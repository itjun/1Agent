import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import adapter from "../Resources/agent-sessions/session-extension.mjs";

const folder = mkdtempSync(join(tmpdir(), "oneagent-extension-test-"));
try {
  for (const kind of ["pi", "omp"]) {
    const invocationID = randomUUID().toUpperCase();
    Object.assign(process.env, { ONEAGENT_AGENT_KIND: kind, ONEAGENT_AGENT_STATE: join(folder, "invocation.json"),
      ONEAGENT_AGENT_INVOCATION: invocationID, ONEAGENT_AGENT_EXECUTABLE: "/tmp/agent" });
    writeFileSync(process.env.ONEAGENT_AGENT_STATE, JSON.stringify({ invocationID }));
    const handlers = {};
    adapter({ on: (name, handler) => { handlers[name] = handler; } });
    let sessionID = randomUUID();
    const ctx = { hasUI: true, cwd: "/tmp/project", mode: kind === "omp" ? "tui" : undefined,
      agent: kind === "omp" ? { kind: "main" } : undefined,
      sessionManager: { getSessionId: () => sessionID, getSessionFile: () => "/tmp/" + sessionID + ".jsonl" } };
    handlers.session_start({}, ctx);
    const output = join(folder, invocationID + ".json");
    assert.equal(JSON.parse(readFileSync(output)).sessionID, sessionID);
    sessionID = randomUUID();
    handlers[kind === "omp" ? "session_switch" : "session_start"]({}, ctx);
    assert.equal(JSON.parse(readFileSync(output)).sessionID, sessionID, "session switch must replace identity");
    const expected = readFileSync(output, "utf8");
    if (kind === "omp") ctx.agent.kind = "subagent";
    else ctx.hasUI = false;
    sessionID = randomUUID(); handlers.agent_end({}, ctx);
    assert.equal(readFileSync(output, "utf8"), expected, "headless/subagent must not overwrite terminal");
    writeFileSync(process.env.ONEAGENT_AGENT_STATE, JSON.stringify({ invocationID: randomUUID() }));
    ctx.hasUI = true; if (ctx.agent) ctx.agent.kind = "main";
    handlers.session_start({}, ctx);
    assert.equal(readFileSync(output, "utf8"), expected, "late event must not overwrite another invocation");
  }
  console.log("Agent extension tests passed: Pi/OMP session switches, subagent isolation and stale events");
} finally { rmSync(folder, { recursive: true, force: true }); }
