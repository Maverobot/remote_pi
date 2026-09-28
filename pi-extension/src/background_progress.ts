import { createHash, randomUUID } from "node:crypto";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { BackgroundProgressWire, BackgroundTaskWire, ServerMessage } from "./protocol/types.js";

const SNAPSHOT_KIND = "pi-subagents.async-status-snapshot";
const terminal = new Set(["complete", "failed", "stopped", "cancelled", "rejected"]);
type RecordValue = Record<string, unknown>;
function record(value: unknown): RecordValue {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid progress record");
  return value as RecordValue;
}
function text(value: unknown, max = 160): string {
  if (typeof value !== "string" || !value.trim() || value.length > max) throw new Error("Invalid progress text");
  return value.replace(/[\u0000-\u001f\u007f]/g, " ");
}
function time(value: unknown): number | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) throw new Error("Invalid progress time");
  return value;
}
function id(value: string): string { return createHash("sha256").update(value).digest("hex").slice(0, 24); }
interface Node {
  id: string; kind: string; label: string; state: string;
  startedAt?: number; updatedAt?: number; endedAt?: number; children: Node[];
}
export interface AsyncSnapshot {
  generatedAt: number; truncated: boolean; runs: Node[];
}
export function parseAsyncSnapshot(raw: unknown): AsyncSnapshot {
  const value = record(raw);
  if (value.kind !== SNAPSHOT_KIND || value.version !== 1 || !Array.isArray(value.runs) || value.runs.length > 20) throw new Error("Unsupported progress snapshot");
  const omitted = record(value.omitted);
  if (time(omitted.runs) === undefined || time(omitted.children) === undefined || typeof omitted.byteLimitExceeded !== "boolean") throw new Error("Missing snapshot completeness");
  let count = 0;
  const parseNode = (rawNode: unknown, depth: number): Node => {
    if (++count > 2000 || depth > 8) throw new Error("Progress snapshot too large");
    const node = record(rawNode);
    if (!["subagent", "workflow", "step", "host-step"].includes(String(node.kind))) throw new Error("Unknown progress kind");
    if (node.children !== undefined && (!Array.isArray(node.children) || node.children.length > 8)) throw new Error("Invalid progress children");
    return { id: text(node.id), kind: String(node.kind), label: text(node.label), state: text(node.state, 32), startedAt: time(node.startedAt), updatedAt: time(node.updatedAt), endedAt: time(node.endedAt), children: ((node.children ?? []) as unknown[]).map(child => parseNode(child, depth + 1)) };
  };
  const generatedAt = time(value.generatedAt);
  if (generatedAt === undefined) throw new Error("Missing snapshot observation");
  return { generatedAt, truncated: omitted.runs !== 0 || omitted.children !== 0 || omitted.byteLimitExceeded, runs: value.runs.map(node => parseNode(node, 0)) };
}

/** Counts only displayed rows; even an untruncated provider view is not a fleet inventory. */
export function projectBackgroundProgress(snapshot: AsyncSnapshot): Pick<BackgroundProgressWire, "truncated" | "groups"> {
  const groups: BackgroundProgressWire["groups"] = [];
  let truncated = snapshot.truncated;
  let taskCount = 0;
  const seenRuns = new Set<string>();
  const seenTasks = new Set<string>();
  for (const root of snapshot.runs) {
    const group: BackgroundProgressWire["groups"][number] = { id: id(root.id), ...(root.kind === "workflow" ? { label: root.label } : {}), tasks: [] };
    groups.push(group);
    const visit = (node: Node, path: string): void => {
      if (node.kind === "host-step") return;
      if (node.kind === "subagent" || node.kind === "workflow") {
        if (seenRuns.has(node.id)) return;
        seenRuns.add(node.id);
      }
      // A subagent root with steps is their run container, not an additional agent.
      const isContainer = node.kind === "workflow" || (node.kind === "subagent" && node.children.some(child => child.kind === "step"));
      if (!isContainer && !terminal.has(node.state)) {
        const key = node.kind === "step" ? path : node.id;
        if (!seenTasks.has(key) && taskCount < 128) {
          seenTasks.add(key);
          taskCount++;
          const state = ["running", "queued", "paused", "waiting", "partial"].includes(node.state) ? node.state : "unknown";
          const end = state === "running" ? snapshot.generatedAt : node.endedAt ?? node.updatedAt;
          const elapsed = node.startedAt !== undefined && end !== undefined && end >= node.startedAt ? end - node.startedAt : undefined;
          group.tasks.push({ id: id(key), label: node.label, state: state as BackgroundTaskWire["state"], ...(elapsed !== undefined ? { elapsed_ms: elapsed } : {}) });
        } else if (taskCount >= 128) truncated = true;
      }
      for (const child of node.children) visit(child, `${path}/${child.id}`);
    };
    visit(root, root.id);
  }
  return { truncated, groups: groups.filter(group => group.tasks.length > 0) };
}

type Peer = { send(message: ServerMessage): void };
export interface BackgroundProgressBridge {
  setSession(sessionId: string): void;
  renew(peer: Peer, interestId: string): void;
  unsubscribe(peer: Peer): void;
  clear(): void;
  dispose(): void;
}
// Lease expiry stops observation only, never child execution. Renew every 5s.
export const BACKGROUND_INTEREST_LEASE_MS = 15_000;
const MAX_INTERESTS_PER_OWNER = 32;
interface Interest { expiresAt: number }
export function createBackgroundProgressBridge(events: ExtensionAPI["events"]): BackgroundProgressBridge {
  const peers = new Map<Peer, Map<string, Interest>>();
  let leaseTimer: ReturnType<typeof setTimeout> | undefined;
  let sessionId = "";
  let epoch = randomUUID();
  let generation = 0;
  let disposed = false;
  let busy = false;
  let again = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const pending = new Set<() => void>();
  let listeners: (() => void)[] = [];
  const cancel = () => {
    generation++;
    if (timer) clearTimeout(timer);
    timer = undefined;
    for (const stop of pending) stop();
    for (const off of listeners) off();
    listeners = [];
  };
  const armLeases = () => {
    if (leaseTimer) clearTimeout(leaseTimer);
    leaseTimer = undefined;
    let next = Infinity;
    for (const [peer, interests] of peers) {
      for (const [token, interest] of interests) {
        if (interest.expiresAt <= Date.now()) interests.delete(token);
        else next = Math.min(next, interest.expiresAt);
      }
      if (!interests.size) peers.delete(peer);
    }
    if (!peers.size) cancel();
    else leaseTimer = setTimeout(armLeases, Math.max(0, next - Date.now()));
  };
  const send = (peer: Peer, token: string, data: Pick<BackgroundProgressWire, "available" | "truncated" | "groups">) => {
    // The relay fans out to every connection sharing the Owner key. Legacy
    // phones recognize pong and ignore its optional observation payload.
    try { peer.send({ type: "pong", in_reply_to: token, background_progress: { session_id: sessionId, epoch, ...data } }); }
    catch { /* Lease expiry also covers silently dropped relay delivery. */ }
  };
  const rpc = (method: "ping" | "status"): Promise<RecordValue> => new Promise((resolve, reject) => {
    const requestId = randomUUID();
    let off = () => {};
    const finish = () => { clearTimeout(timeout); off(); pending.delete(stop); };
    const stop = () => { finish(); reject(new Error("Progress observation cancelled")); };
    const timeout = setTimeout(stop, 3000);
    pending.add(stop);
    off = events.on(`subagents:rpc:v1:reply:${requestId}`, raw => {
      finish();
      try {
        const reply = record(raw);
        if (reply.version !== 1 || reply.requestId !== requestId || reply.success !== true) throw new Error("Progress source unavailable");
        resolve(record(reply.data));
      } catch (error) { reject(error); }
    });
    try { events.emit("subagents:rpc:v1:request", { version: 1, requestId, method }); }
    catch (error) { finish(); reject(error); }
  });
  const refresh = async () => {
    if (disposed || !peers.size || !sessionId) return;
    if (busy) { again = true; return; }
    busy = true;
    again = false;
    const owned = generation;
    const recipients = [...peers].flatMap(([peer, interests]) => [...interests].map(([token, interest]) => ({ peer, token, interest })));
    let data: Pick<BackgroundProgressWire, "available" | "truncated" | "groups"> = { available: false, truncated: false, groups: [] };
    try {
      const ping = await rpc("ping");
      const capability = record(record(ping.capabilities).asyncStatusSnapshot);
      if (capability.kind !== SNAPSHOT_KIND || capability.version !== 1 || record(ping.session).sessionId !== sessionId) throw new Error("Unsupported progress source");
      if (generation !== owned) return;
      const result = await rpc("status");
      data = { available: true, ...projectBackgroundProgress(parseAsyncSnapshot(result.asyncSnapshot)) };
    } catch { /* Failed observations never replace a last-known task list with empty success. */ }
    finally {
      busy = false;
      if (!disposed && generation === owned) {
        for (const { peer, token, interest } of recipients) {
          if (peers.get(peer)?.get(token) !== interest || interest.expiresAt <= Date.now()) continue;
          send(peer, token, data);
        }
      }
      if (!disposed && peers.size) {
        if (timer) clearTimeout(timer);
        timer = setTimeout(() => { void refresh(); }, again || generation !== owned ? 0 : 2000);
      }
    }
  };
  const listen = () => {
    if (listeners.length) return;
    for (const name of ["subagents:rpc:v1:ready", "subagent:async-complete", "subagent:child-status"]) listeners.push(events.on(name, () => { void refresh(); }));
  };
  return {
    setSession(next) {
      if (disposed || next === sessionId) return;
      cancel(); sessionId = next; epoch = randomUUID();
      // A new parent invalidates the previous view before its first RPC reply.
      for (const [peer, interests] of peers) {
        for (const [token, interest] of interests) {
          if (interest.expiresAt > Date.now()) send(peer, token, { available: false, truncated: false, groups: [] });
        }
      }
      if (peers.size) { listen(); void refresh(); }
    },
    renew(peer, token) {
      if (disposed || typeof token !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(token)) return;
      armLeases();
      const interests = peers.get(peer) ?? new Map<string, Interest>();
      const existing = interests.get(token);
      if (!existing && interests.size >= MAX_INTERESTS_PER_OWNER) return;
      interests.set(token, existing ?? { expiresAt: 0 });
      interests.get(token)!.expiresAt = Date.now() + BACKGROUND_INTEREST_LEASE_MS;
      peers.set(peer, interests);
      armLeases(); listen();
      if (!existing) void refresh();
    },
    unsubscribe(peer) { peers.delete(peer); armLeases(); },
    clear() { peers.clear(); armLeases(); },
    dispose() { disposed = true; peers.clear(); armLeases(); },
  };
}
