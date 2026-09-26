import { closeSync, mkdtempSync, openSync, writeSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Type } from "@earendil-works/pi-ai";
import { createBashToolDefinition, createLocalBashOperations, type ExtensionAPI, type ExtensionContext } from "@earendil-works/pi-coding-agent";

type Job = {
  id: string;
  owner: string;
  path: string;
  controller: AbortController;
  state: string;
  result: string;
  background: boolean;
  done: Promise<void>;
  bytes: number;
  logged: number;
  delivery: "none" | "pending" | "enqueued" | "observed";
  deliveryError?: string;
};

export default function (pi: ExtensionAPI) {
  const jobs = new Map<string, Job>();
  let owner = "";
  let shuttingDown = false;
  let runActive = false;
  let sequence = 0;
  let notificationTimer: ReturnType<typeof setTimeout> | undefined;
  const pending: Job[] = [];
  const identity = (ctx: ExtensionContext) => ctx.sessionManager.getSessionId();
  const text = (value: string) => ({ content: [{ type: "text" as const, text: value }], details: {} });
  const bounded = (value: string, bytes = 4096) => {
    if (bytes <= 0) return "";
    let buffer = Buffer.from(value).subarray(-bytes);
    while (buffer.length && (buffer[0] & 0xc0) === 0x80) buffer = buffer.subarray(1);
    return buffer.toString().split("\n").slice(-80).join("\n");
  };
  const metadata = (job: Job) => `Task ${job.id}: ${job.state}\nBytes: ${job.bytes}; logged: ${job.logged}\nOutput: ${job.path}${job.deliveryError ? `\nDelivery failed: ${job.deliveryError}` : ""}`;
  const summary = (job: Job) => `${metadata(job)}\n${job.result}`;
  const completion = (batch: Job[]) => {
    const budget = Math.min(4096, Math.max(0, Math.floor((8192 - Buffer.byteLength(batch.map(metadata).join("\n\n")) - 128) / batch.length)));
    return { customType: "exec-completion", content: batch.map((job) => {
      const result = bounded(job.result, Math.max(0, budget - 40));
      return `${metadata(job)}\n${result}${result !== job.result ? "\n[Shortened; read log for details.]" : ""}`;
    }).join("\n\n"), display: false, details: { tasks: batch.map((job) => ({ taskId: job.id, state: job.state, outputPath: job.path })) } };
  };
  const takePending = () => pending.splice(0).filter((job) => job.owner === owner && job.delivery === "pending");
  const scheduleNotification = () => {
    if (!runActive && !shuttingDown && pending.some((job) => job.delivery === "pending")) {
      notificationTimer ??= setTimeout(flushNotifications, 250);
    }
  };
  const flushNotifications = () => {
    clearTimeout(notificationTimer);
    notificationTimer = undefined;
    if (runActive || shuttingDown) return;
    const batch = takePending();
    if (!batch.length) return;
    try {
      pi.sendMessage(completion(batch), { deliverAs: "followUp", triggerTurn: true });
      for (const job of batch) job.delivery = "enqueued";
    } catch (error) {
      for (const job of batch) {
        job.deliveryError = bounded(String(error), 256);
        job.delivery = "pending";
        pending.push(job);
      }
      console.error(`exec completion delivery failed for ${batch.map((job) => job.id).join(", ")}: ${error}`);
    }
  };
  const stopAll = async () => {
    shuttingDown = true;
    clearTimeout(notificationTimer);
    notificationTimer = undefined;
    pending.length = 0;
    runActive = false;
    for (const job of jobs.values()) job.controller.abort();
    await Promise.all([...jobs.values()].map((job) => job.done));
    jobs.clear();
  };

  pi.on("session_start", async (_event, ctx) => {
    await stopAll();
    owner = identity(ctx);
    shuttingDown = false;
  });
  pi.on("session_shutdown", stopAll);
  pi.on("agent_start", () => {
    runActive = true;
    clearTimeout(notificationTimer);
    notificationTimer = undefined;
  });
  pi.on("agent_before_settle", () => {
    const batch = takePending();
    if (!batch.length) return;
    const entries = [];
    for (let index = 0; index < batch.length; index += 8) {
      entries.push({ type: "custom_message" as const, ...completion(batch.slice(index, index + 8)) });
    }
    for (const job of batch) job.delivery = "enqueued";
    return { entries, continue: true };
  });
  pi.on("agent_settled", () => {
    runActive = false;
    scheduleNotification();
  });
  pi.on("agent_end", async (event, ctx) => {
    const last = event.messages.at(-1);
    if (last?.role === "assistant" && ["error", "aborted"].includes(last.stopReason)) {
      await stopAll();
      shuttingDown = false;
      return;
    }
    if (ctx.mode !== "print" && ctx.mode !== "json") return;
    // Pi 0.85.1 continues messages queued by awaited agent_end handlers before print disposal.
    await Promise.all([...jobs.values()].filter((job) => job.owner === identity(ctx)).map((job) => job.done));
    flushNotifications();
  });

  pi.registerTool({
    name: "bash",
    label: "bash",
    promptSnippet: "Execute bash with automatic background yield and completion notifications",
    description: "Execute bash. Returns output if done within 10 seconds; otherwise returns a task ID and automatically delivers completion. background:true returns immediately. timeout is an optional hard limit in seconds, NOT a yield interval. Omit timeout for long builds unless a deadline is intended. Results contain at most 4 KiB/80 lines of output tail; read the log for details (64 MiB log limit). Completions during an agent run are delivered together before settlement.",
    promptGuidelines: ["After bash returns a running task, do independent work or end the turn. Completion wakes you automatically; do not poll or sleep merely to wait. Use exec_status only for a requested progress update or troubleshooting; exec_cancel stops a task."],
    parameters: Type.Object({ command: Type.String(), timeout: Type.Optional(Type.Number()), background: Type.Optional(Type.Boolean()) }),
    async execute(_id, args, signal, onUpdate, ctx) {
      if (shuttingDown || identity(ctx) !== owner) throw new Error("Session changed; retry in the active session");
      if (signal?.aborted) throw new Error("Command aborted");
      const directory = mkdtempSync(join(tmpdir(), "pi-exec-"));
      const path = join(directory, "output.log");
      const fd = openSync(path, "wx", 0o600);
      const job: Job = { id: `exec-${++sequence}`, owner, path, controller: new AbortController(), state: "running", result: "", background: false, done: Promise.resolve(), bytes: 0, logged: 0, delivery: "none" };
      jobs.set(job.id, job);
      const abort = () => job.controller.abort();
      signal?.addEventListener("abort", abort, { once: true });
      const operations = createLocalBashOperations();
      let logged = 0;
      let total = 0;
      let tail = Buffer.alloc(0);
      let logError = "";
      let lastUpdate = 0;
      const tool = createBashToolDefinition(ctx.cwd, {
        operations: { async exec(command, cwd, options) {
          try {
            const result = await operations.exec(command, cwd, { ...options, onData(data) {
              total += data.length;
              job.bytes = total;
              tail = Buffer.concat([tail, data.subarray(-4096)]).subarray(-4096);
              const remaining = data.subarray(0, Math.max(0, 64 * 1024 * 1024 - logged));
              try {
                let offset = 0;
                while (offset < remaining.length) offset += writeSync(fd, remaining, offset);
                logged += remaining.length;
                job.logged = logged;
              } catch (error) { logError = String(error); job.controller.abort(); }
              if (!job.background && Date.now() - lastUpdate > 250) {
                lastUpdate = Date.now();
                onUpdate?.(text(bounded(tail.toString())));
              }
            } });
            job.state = result.exitCode === 0 ? "completed" : "failed";
            return result;
          } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            job.state = message.startsWith("timeout:") ? "timed_out" : job.controller.signal.aborted ? "cancelled" : "failed";
            throw error;
          } finally {
            options.onData(Buffer.from(bounded(tail.toString())));
          }
        } },
      });
      job.done = (async () => {
        try {
          const result = await tool.execute(_id, args, job.controller.signal, (update) => {
            if (!job.background) onUpdate?.(update);
          }, ctx);
          job.result = result.content.map((part) => part.type === "text" ? part.text : "").join("\n");
        } catch (error) {
          job.result = error instanceof Error ? error.message : String(error);
          if (job.state === "running") job.state = "failed";
        } finally {
          try { closeSync(fd); } catch (error) { job.state = "failed"; job.result += `\nLog close failed: ${error}`; }
          signal?.removeEventListener("abort", abort);
        }
        if (total > 4096) job.result += "\n[Output tail only; read the log for details.]";
        if (total > logged) job.result += `\n[Log truncated: saved first ${logged} of ${total} bytes; 64 MiB limit.]`;
        if (logError) { job.state = "failed"; job.result += `\nLog write failed: ${logError}`; }
        job.result = bounded(job.result);
        if (job.background && !shuttingDown && owner === job.owner) {
          job.delivery = "pending";
          pending.push(job);
          scheduleNotification();
        }
        const completed = [...jobs.values()].filter((entry) => entry.state !== "running");
        for (const entry of completed.slice(0, -100)) jobs.delete(entry.id);
      })();
      let timer: ReturnType<typeof setTimeout> | undefined;
      if (!args.background) {
        await Promise.race([job.done, new Promise<void>((resolve) => { timer = setTimeout(resolve, 10_000); })]);
        clearTimeout(timer);
      }
      if (job.state !== "running") {
        await job.done;
        if (job.state !== "completed") throw new Error(summary(job));
        return text(summary(job));
      }
      job.background = true;
      signal?.removeEventListener("abort", abort);
      return text(`Task ${job.id}: running\nOutput: ${path}\nCompletion will arrive automatically. Continue independent work or end this turn.`);
    },
  });

  pi.registerTool({
    name: "exec_status", label: "Exec status", description: "Inspect task state, byte counts and log path, without output. No waiting; completion is delivered automatically. Read the log only when details are needed.",
    parameters: Type.Object({ taskId: Type.Optional(Type.String()) }),
    async execute(_id, args) {
      const selected = [...jobs.values()].filter((job) => job.owner === owner && (!args.taskId || job.id === args.taskId));
      const visible = args.taskId ? selected : selected.slice(-20);
      for (const job of visible) if (job.delivery === "pending") job.delivery = "observed";
      return text((args.taskId ? "" : `${selected.length} tasks; showing latest ${visible.length}.\n`) + (visible.map(metadata).join("\n\n") || "No matching tasks"));
    },
  });
  pi.registerTool({
    name: "exec_cancel", label: "Cancel exec", description: "Stop a task and its process tree; wait for cleanup. Completed output remains on disk.",
    parameters: Type.Object({ taskId: Type.String() }),
    async execute(_id, args) {
      const job = jobs.get(args.taskId);
      if (!job || job.owner !== owner) throw new Error("Unknown task");
      job.controller.abort();
      await job.done;
      job.delivery = "observed";
      return text(summary(job));
    },
  });
}
