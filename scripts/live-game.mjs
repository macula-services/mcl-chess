#!/usr/bin/env node
// A live game on the mesh: two macula-mcp agents play one referee'd, timed game
// through to game_ended_v1, and a third agent only watches and reads.
//
// WHAT THIS EXISTS TO PROVE, and why it is a script rather than a test: the
// unit and end-to-end suites mock the mesh (mcl_om and macula are mecked, the
// collector is a process). This is the one path where the referee is a real
// deployed service on the public fleet, the players are two real macula-mcp
// processes with their own node identities, and the clock, the D25 delegation
// and the fact topics are the live ones. Nothing here mocks anything.
//
// THE THREE AGENTS HAVE THREE IDENTITIES. `MACULA_MCP_AGENT=<name>` gives each
// macula-mcp process its own key (`~/.config/macula-mcp/keys/agent-<name>.key`)
// and therefore its own node id, so the referee sees two players and a
// spectator, not one node wearing three hats. Each agent also gets its own
// roster and ring databases: they are sqlite files the server opens on start,
// and three processes sharing one is asking for a lock at an awkward moment.
//
// THE GAME IS FOOL'S MATE, and that is deliberate: four plies, a real checkmate,
// and `game_ended_v1` with reason `checkmate` from the position itself rather
// than from a resignation or a flag. PLAY is the UCI move list on the wire; the
// referee validates every one against its own rules engine.
//
// WHAT IT PRINTS: one JSON object on stdout, and nothing else, so a caller can
// paste it as evidence and a human can still read it.
//
// Usage: node scripts/live-game.mjs
//   MACULA_MCP_PACKAGE  the macula-mcp spec to run (default @macula-io/mcp@0.48.0;
//                       the package name is not the repository name)
//   LIVE_GAME_TIMEOUT_MS  how long to wait for the end fact (default 180000)
//
// No npm dependencies: the MCP transport is newline-delimited JSON-RPC 2.0
// over the child's stdio, which is the whole protocol this needs.

import { spawn } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const PACKAGE = process.env.MACULA_MCP_PACKAGE ?? "@macula-io/mcp@0.48.0";
const TIMEOUT_MS = Number(process.env.LIVE_GAME_TIMEOUT_MS ?? 180000);
const ORG = "mcl-chess";
/// A fact's topic is a five-segment `app_fact`: realm, org, app, domain, name
/// with the version on the name, so the referee's facts are
/// `io.macula/mcl-chess/chess/game/<event>_v1`. The realm segment is part of
/// the topic, not an envelope around it: a subscriber that leaves it out hears
/// nothing at all and cannot tell that from a game that never started.
const REALM_NAME = process.env.LIVE_GAME_REALM ?? "io.macula";
const FACT_PREFIX = `${REALM_NAME}/${ORG}/chess/game`;
const TIME_CONTROL = { initial_ms: 60000, increment_ms: 0 };

// Fool's mate, as UCI: white f3, black e5, white g4, black Qh4#.
const PLAY = [
  { color: "w", move: "f2f3" },
  { color: "b", move: "e7e5" },
  { color: "w", move: "g2g4" },
  { color: "b", move: "d8h4" },
];

/** One macula-mcp process, spoken to over stdio. */
class Agent {
  constructor(name) {
    this.name = name;
    this.nextId = 1;
    this.pending = new Map();
    this.stderr = "";
    this.buffer = "";
    const dir = mkdtempSync(join(tmpdir(), `live-game-${name}-`));
    // `--package <spec> <bin>`, not `npx <spec>`: the package names several
    // executables, and npx refuses to pick one by itself.
    this.child = spawn("npx", ["--yes", "--package", PACKAGE, "macula-mcp"], {
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        MACULA_MCP_AGENT: name,
        MACULA_MCP_ROSTER_DB: join(dir, "roster.sqlite3"),
        MACULA_MCP_RINGS_DB: join(dir, "rings.sqlite3"),
        MACULA_MCP_LOBBY_TRANSCRIPT_DB: join(dir, "lobby.sqlite3"),
      },
    });
    this.child.stdout.setEncoding("utf8");
    this.child.stdout.on("data", (chunk) => this.heard(chunk));
    this.child.stderr.setEncoding("utf8");
    this.child.stderr.on("data", (chunk) => (this.stderr += chunk));
    // A child that dies without answering must fail the run rather than leave
    // a promise that nothing will ever settle: the first version of this
    // script exited 0 in silence when the package name was wrong, because the
    // only handle left was an unref'd timer.
    this.child.on("error", (error) => this.failed(error));
    this.child.on("exit", (code, signal) =>
      this.failed(new Error(`exited (code ${code}, signal ${signal})`)));
    this.exited = new Promise((resolve) => this.child.on("exit", resolve));
  }

  /// Rejects everything waiting on this agent, with what it said on stderr.
  failed(error) {
    if (this.pending.size === 0) return;
    const tail = this.stderr.trim().split("\n").slice(-6).join("\n");
    for (const { reject } of this.pending.values()) {
      reject(new Error(`${this.name}: ${error.message}${tail ? `\n${tail}` : ""}`));
    }
    this.pending.clear();
  }

  heard(chunk) {
    this.buffer += chunk;
    for (;;) {
      const newline = this.buffer.indexOf("\n");
      if (newline < 0) return;
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (line === "") continue;
      this.answered(line);
    }
  }

  answered(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return; // the server logs to stderr; anything unparsable on stdout is not ours
    }
    const waiting = this.pending.get(message.id);
    if (!waiting) return;
    this.pending.delete(message.id);
    if (message.error) waiting.reject(new Error(JSON.stringify(message.error)));
    else waiting.resolve(message.result);
  }

  request(method, params) {
    const id = this.nextId++;
    this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`${this.name}: no answer to ${method}`));
      }, TIMEOUT_MS).unref();
    });
  }

  notify(method, params) {
    this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
  }

  async open() {
    await this.request("initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: `live-game-${this.name}`, version: "1" },
    });
    this.notify("notifications/initialized", {});
    return this;
  }

  /** A tool call, with the MCP text content parsed back into a value. */
  async tool(name, args) {
    const result = await this.request("tools/call", { name, arguments: args });
    const text = (result.content ?? []).map((part) => part.text ?? "").join("");
    const value = parsed(text);
    if (result.isError) throw new Error(`${this.name}: ${name}: ${text}`);
    return value;
  }

  /// Says goodbye first: a killed process leaves its presence to expire, and a
  /// departed agent is what "nothing left behind" means.
  async close() {
    try {
      await this.tool("mesh_goodbye", { message: "the game is over" });
    } catch {
      // an agent that never said hello has nothing to withdraw
    }
    this.child.stdin.end();
    this.child.kill("SIGTERM");
    await Promise.race([this.exited, sleep(5000)]);
  }
}

function parsed(text) {
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** The call to the referee: one procedure, its args, on the io.macula realm.
 *
 * mesh_call answers with the exchange around the provider's reply (the reply
 * itself under `result`, plus duration and how it was sealed), so what a game
 * needs is unwrapped here and nowhere else.
 */
async function referee(agent, procedure, args) {
  const exchange = await agent.tool("mesh_call", { procedure: `${ORG}/${procedure}`, args });
  const answer = exchange?.result ?? exchange;
  if (answer && typeof answer === "object" && "error" in answer) {
    throw new Error(`${agent.name}: ${procedure} refused: ${answer.error}`);
  }
  return answer;
}

/** The first watched fact carrying our game's id, or undefined. */
function ours(watched, gameId) {
  return (watched.events ?? []).find((event) => event.payload?.game_id === gameId);
}

async function main() {
  const [white, black, spectator] = await Promise.all(
    ["chess-white", "chess-black", "chess-spectator"].map((name) =>
      new Agent(name).open(),
    ),
  );

  const evidence = { started: new Date().toISOString(), agents: {}, game: {} };

  try {
    const hello = async (agent) => {
      const answer = await agent.tool("mesh_hello", {});
      evidence.agents[agent.name] = answer?.node_id ?? answer;
    };
    await Promise.all([hello(white), hello(black), hello(spectator)]);

    // Watching starts before the game does: a subscription that is created
    // after the fact has happened hears nothing, there is no replay.
    const startedWatch = spectator.tool("mesh_watch", {
      topic: `${FACT_PREFIX}/game_started_v1`,
      duration_seconds: TIMEOUT_MS / 1000,
      count: 1,
    });

    const view = await referee(white, "initiate_game", { time_control: TIME_CONTROL });
    const gameId = view.game_id;
    evidence.game.game_id = gameId;
    evidence.game.time_control = TIME_CONTROL;

    evidence.game.white_claim = await referee(white, "claim_seat", { game_id: gameId, color: "w" });
    evidence.game.black_claim = await referee(black, "claim_seat", { game_id: gameId, color: "b" });

    const started = ours(await startedWatch, gameId);
    if (!started) throw new Error("game_started_v1 was never seen on the mesh");
    evidence.facts = { game_started_v1: factOf(started) };

    // The end fact is watched for while the game is played, for the same
    // reason as the start.
    const endedWatch = spectator.tool("mesh_watch", {
      topic: `${FACT_PREFIX}/game_ended_v1`,
      duration_seconds: TIMEOUT_MS / 1000,
      count: 1,
    });

    evidence.game.moves = [];
    for (const { color, move } of PLAY) {
      const mover = color === "w" ? white : black;
      evidence.game.moves.push(await referee(mover, "submit_move", { game_id: gameId, move }));
    }

    const ended = ours(await endedWatch, gameId);
    if (!ended) throw new Error("game_ended_v1 was never seen on the mesh");
    evidence.facts.game_ended_v1 = factOf(ended);

    // The read model, read by the spectator: the third identity proves a
    // reader needs neither seat to see how the game finished.
    const final = await referee(spectator, "get_game_by_id", { game_id: gameId });
    evidence.game.final = final;
    evidence.game.ended_at_ms = Date.now();
  } finally {
    await Promise.all([white.close(), black.close(), spectator.close()]);
  }

  process.stdout.write(`${JSON.stringify(evidence, null, 2)}\n`);
}

function factOf(event) {
  return { topic: event.topic, publisher: event.publisher, payload: event.payload };
}

/// `--check`: prove this harness reaches the live mesh at all before it is
/// trusted with a game. It calls the fleet's always-on echo, which needs no
/// realm grant and no service of ours to be deployed.
async function check() {
  const agent = await new Agent("chess-check").open();
  try {
    const answer = await agent.tool("mesh_call", {
      procedure: "mcl-echo/echo",
      args: { message: "live-game check" },
    });
    process.stdout.write(`${JSON.stringify({ echo: answer }, null, 2)}\n`);
  } finally {
    await agent.close();
  }
}

if (process.argv.includes("--check")) {
  check().catch((error) => {
    process.stderr.write(`${error.stack ?? error}\n`);
    process.exitCode = 1;
  });
} else {
  main().catch((error) => {
    process.stderr.write(`${error.stack ?? error}\n`);
    process.exitCode = 1;
  });
}
