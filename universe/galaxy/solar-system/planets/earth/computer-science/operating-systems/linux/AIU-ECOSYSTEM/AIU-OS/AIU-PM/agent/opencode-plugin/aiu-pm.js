// aiu-pm.js -- the CyberDeck pm plugin for OpenCode (V-5, D-036).
//
// pm is the ONLY implementation of package-manager policy. This plugin
// is a shim: it runs `pm ... --format json` through OpenCode's Bun
// shell and hands the document back. Nothing here parses a spec,
// resolves a version, or decides whether a state change is allowed.
//
// Two rules shape the whole file:
//
//   1. READ ONLY. This plugin registers no state-changing tool. There
//      is no `apply`, no `activate`, no `remove`. An agent that wants
//      to change the machine cannot, from here. When pm's dispatch is
//      wired (E-18 debt), those tools will call `context.ask()` --
//      OpenCode's own approval boundary -- before spawning anything.
//
//   2. NO POLLING. `<state>/events/` is watched with fs.watch. New
//      JSON Lines are read when the file actually changes, never on a
//      timer. If pm is not running, this plugin does nothing at all.
//
// API used, all read from the installed @opencode-ai/plugin@1.18.31
// (dist/index.d.ts, dist/tool.d.ts, dist/shell.d.ts):
//   Plugin       = (PluginInput, options?) => Promise<Hooks>
//   PluginInput  = { client, project, directory, worktree, $, ... }
//   Hooks.tool   = { [name]: ToolDefinition }
//   Hooks["chat.system.transform"] = ({sessionID}, {system: string[]})
//   tool()       = { description, args: zodRawShape, execute(args, ctx) }
//   ToolContext  = { sessionID, directory, worktree, abort, metadata, ask }
//
// We deliberately do NOT use `chat.message` + a synthesized Part: the
// SDK Part shape is not present in the installed @opencode-ai/sdk, so
// building one would be guesswork. `system` is a plain string[], which
// is verified, and it is the right surface for a passive digest.

import { tool } from "@opencode-ai/plugin/tool";
import { watch } from "node:fs";
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// ---------------------------------------------------------------------------
// Paths. <state>/events comes from package-manager/src/machine/directories.rkt (XDG_DATA_HOME or
// ~/.local/share). The plugin reads the same layout pm writes; it never
// decides it, so the two cannot drift.

function stateRoot(env) {
  const data = env.XDG_DATA_HOME;
  return data && data.trim() !== "" ? data : join(homedir(), ".local", "share");
}

function eventsDir(env) {
  return join(stateRoot(env), "aiu-pm", "events");
}

// ---------------------------------------------------------------------------
// The feed reader. One entry per run file we have seen: how many bytes
// we have consumed and the events parsed out of them. Offsets are the
// resume point, so a re-read after a watcher event costs nothing.

const feeds = new Map(); // runId -> { offset, events: [] }

function feedPath(dir, runId) {
  return join(dir, `${runId}.jsonl`);
}

/** Read whatever is appended past our cursor. Returns the new events. */
export function drainFeed(dir, runId) {
  const state = feeds.get(runId) || { offset: 0, events: [] };
  const path = feedPath(dir, runId);
  if (!existsSync(path)) return [];
  const text = readFileSync(path, "utf8");
  if (text.length < state.offset) {
    // Truncated or rotated under us: start over rather than read junk.
    state.offset = 0;
    state.events = [];
  }
  if (text.length === state.offset) return [];
  const fresh = text.slice(state.offset);
  const lastNl = fresh.lastIndexOf("\n");
  if (lastNl < 0) return []; // a partial line; wait for the next write
  const added = [];
  for (const line of fresh.slice(0, lastNl).split("\n")) {
    const trimmed = line.trim();
    if (trimmed === "") continue;
    try {
      added.push(JSON.parse(trimmed));
    } catch {
      // A malformed line is skipped, never thrown: the feed is
      // append-only and may be read mid-write.
    }
  }
  state.offset += lastNl + 1;
  state.events = state.events.concat(added);
  feeds.set(runId, state);
  return added;
}

/** The run id pm says is active, or null when pm is not running. */
export function currentRunId(dir) {
  const current = join(dir, "current");
  if (!existsSync(current)) return null;
  const id = readFileSync(current, "utf8").trim();
  return id === "" ? null : id;
}

/** Every run id pm has a feed for, newest feed file first by name. */
export function listRunIds(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => f.endsWith(".jsonl"))
    .map((f) => f.slice(0, -".jsonl".length))
    .sort()
    .reverse();
}

// ---------------------------------------------------------------------------
// Formatting. Kept pure and exported so the offline test can drive it
// with synthetic JSON Lines and no filesystem at all.

/** One event -> one screen-ish line for the model's benefit. */
export function formatEvent(e) {
  const bits = [
    `#${e.seq}`,
    e.kind,
    `${e.who}:`,
    e.what,
  ];
  if (e.why && e.why !== "record") bits.push(`(${e.why})`);
  if (e.how) bits.push(`[${e.how}]`);
  if (e.depth) bits.push(`${"  ".repeat(e.depth)}`);
  return bits.join(" ");
}

/** A run -> a START/END summary: did it finish, how long, what failed. */
export function summarizeRun(events) {
  if (events.length === 0) return { count: 0, summary: "no events yet" };
  const first = events[0];
  const last = events[events.length - 1];
  const fails = events.filter((e) => e.kind === "FAIL");
  const ends = events.filter((e) => e.kind === "END" && e.depth === 0);
  const started = events.find((e) => e.kind === "START" && e.depth === 0);
  return {
    count: events.length,
    runId: first.runId,
    started: started ? started.what : null,
    ended: ends.length > 0,
    endResult: ends.length > 0 ? ends[ends.length - 1].result : null,
    durationMs: last.durationMs,
    lastKind: last.kind,
    failures: fails.map((e) => `${e.who}: ${e.what} -- ${e.result}`),
    summary:
      `${events.length} events, last ${last.kind}` +
      (ends.length > 0 ? ", run closed" : ", run still open") +
      (fails.length > 0 ? `, ${fails.length} failure(s)` : ""),
  };
}

/** Events strictly after `fromSeq`, newest last, bounded. */
export function tailEvents(events, fromSeq, limit = 50) {
  const after = events.filter((e) => Number(e.seq) > Number(fromSeq || 0));
  const slice = after.slice(Math.max(0, after.length - limit));
  return {
    count: after.length,
    returned: slice.length,
    nextSeq: slice.length > 0 ? slice[slice.length - 1].seq : fromSeq || 0,
    lines: slice.map(formatEvent),
  };
}

// ---------------------------------------------------------------------------
// The plugin.

export const AiuPmPlugin = async ({ $ }, options = {}) => {
  const env = options.env || process.env;
  const dir = options.eventsDir || eventsDir(env);
  const pmBin = options.pmBin || "pm";

  // One watcher for the whole directory. pm writes `current` and the
  // .jsonl files here; either write fires us, we drain, done. No timer,
  // no interval, no wakeup: if pm never runs, this never fires.
  const watcher = watch(dir, () => {
    const id = currentRunId(dir);
    if (id) drainFeed(dir, id);
  });

  return {
    tool: {
      aiu_run_status: tool({
        description:
          "CyberDeck pm: what is the package manager doing right now? " +
          "Read-only. Returns the active run id and a START/END summary " +
          "with the current run's event count and any failures.",
        args: {
          runId: tool.schema
            .string()
            .optional()
            .describe("Run id; omit for the active run."),
        },
        async execute(args) {
          const id = args.runId || currentRunId(dir);
          if (!id) {
            return {
              title: "pm: no active run",
              output:
                "No active pm run. A run id appears once pm writes " +
                `${dir}/current. Known runs: ${
                  listRunIds(dir).join(", ") || "(none)"
                }`,
            };
          }
          drainFeed(dir, id);
          const events = feeds.get(id)?.events || [];
          return {
            title: `pm run ${id}`,
            output: JSON.stringify(summarizeRun(events), null, 2),
          };
        },
      }),

      aiu_events_tail: tool({
        description:
          "CyberDeck pm: read the live event feed for one run, newest " +
          "last. Read-only. Each line is #seq KIND who: what (why). " +
          "Pass nextSeq back to continue where you stopped.",
        args: {
          runId: tool.schema
            .string()
            .optional()
            .describe("Run id; omit for the active run."),
          fromSeq: tool.schema
            .number()
            .optional()
            .describe("Return only events after this sequence number."),
          limit: tool.schema.number().optional().describe("Max lines."),
        },
        async execute(args) {
          const id = args.runId || currentRunId(dir);
          if (!id) {
            return {
              title: "pm: no active run",
              output:
                "No active pm run, so there is no feed to tail. " +
                `Known runs: ${listRunIds(dir).join(", ") || "(none)"}`,
            };
          }
          drainFeed(dir, id);
          const events = feeds.get(id)?.events || [];
          return {
            title: `pm feed ${id}`,
            output: JSON.stringify(
              tailEvents(events, args.fromSeq, args.limit ?? 50),
              null,
              2,
            ),
          };
        },
      }),
    },

    // Passive digest only. The watcher has already recorded what is new;
    // this just tells the model there is something to read, without
    // spending a turn or interrupting anything.
    "chat.system.transform": async (_input, output) => {
      const id = currentRunId(dir);
      if (!id) return;
      drainFeed(dir, id);
      const events = feeds.get(id)?.events || [];
      if (events.length === 0) return;
      const s = summarizeRun(events);
      output.system.push(
        `CyberDeck pm is running (run ${id}, ${s.count} events). ` +
          `Use aiu_events_tail for the detail and aiu_run_status for the ` +
          `summary. The feed already carries what, why, how, UTC time ` +
          `and duration for every step, decision and skip.`
      );
    },

    dispose: async () => {
      watcher.close();
    },
  };
};

export default AiuPmPlugin;