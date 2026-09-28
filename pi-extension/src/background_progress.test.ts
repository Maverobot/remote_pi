import { afterEach, describe, expect, it, vi } from "vitest";
import { createBackgroundProgressBridge, parseAsyncSnapshot, projectBackgroundProgress } from "./background_progress.js";
import type { ServerMessage } from "./protocol/types.js";

const node = (id: string, kind = "step", state = "running", children?: unknown[]) => ({ id, kind, state, label: id, startedAt: 1000, updatedAt: 4000, ...(children ? { children } : {}) });
const snapshot = (runs: unknown[], children = 0) => ({ kind: "pi-subagents.async-status-snapshot", version: 1, generatedAt: 6000, omitted: { runs: 0, children, byteLimitExceeded: false }, runs });
const project = (runs: unknown[], omitted = 0) => projectBackgroundProgress(parseAsyncSnapshot(snapshot(runs, omitted)));

// Portable fixtures reflect the public DTOs recorded from pi-subagents 0.72.1.
describe("provider-visible background tasks", () => {
  it("counts a single run's self step once and does not invent its original group", () => {
    const result = project([node("run", "subagent", "running", [node("step:0")])]);
    expect(result.groups[0]?.label).toBeUndefined();
    expect(result.groups[0]?.tasks).toHaveLength(1);
    expect(result.groups[0]?.tasks[0]?.elapsed_ms).toBe(5000);
  });
  it("shows one worker then two reviewers in a proven workflow group", () => {
    expect(project([node("dispatch", "workflow", "running", [node("worker")])]).groups[0]?.tasks).toHaveLength(1);
    const result = project([node("dispatch", "workflow", "running", [node("worker", "step", "complete"), node("review-a"), node("review-b"), node("monitor", "host-step")])]);
    expect(result.groups[0]?.label).toBe("dispatch");
    expect(result.groups[0]?.tasks.map(task => task.label)).toEqual(["review-a", "review-b"]);
  });
  it("retains unresolved states and unknown time, removes only terminal rows", () => {
    const states = ["queued", "paused", "waiting", "partial", "future", "failed", "stopped", "rejected", "complete"];
    const result = project([node("dispatch", "workflow", "partial", states.slice(0, 8).map(state => node(state, "step", state)))]);
    expect(result.groups[0]?.tasks.map(task => task.state)).toEqual(["queued", "paused", "waiting", "partial", "unknown"]);
    expect(result.groups[0]?.tasks.map(task => task.elapsed_ms)).toEqual([3000, 3000, 3000, 3000, 3000]);
    const missing = { id: "missing", kind: "subagent", state: "running", label: "Quiet task" };
    expect(project([missing]).groups[0]?.tasks[0]).not.toHaveProperty("elapsed_ms");
    expect(project([node("done", "subagent", "complete")]).groups).toEqual([]);
  });
  it("deduplicates nested run projections and excludes workflow/host containers", () => {
    const child = node("child", "subagent");
    const result = project([node("dispatch", "workflow", "running", [node("worker", "step", "running", [child]), child])]);
    expect(result.groups[0]?.tasks.map(task => task.label)).toEqual(["worker", "child"]);
  });
  it("preserves truncation when omitted children leave no visible rows", () => {
    expect(project([node("dispatch", "workflow")], 2)).toEqual({ truncated: true, groups: [] });
    expect(project([])).toEqual({ truncated: false, groups: [] });
  });
  it("rejects malformed observations instead of turning them into empty success", () => {
    expect(() => parseAsyncSnapshot({ ...snapshot([]), omitted: {} })).toThrow();
    expect(() => parseAsyncSnapshot({ ...snapshot([]), version: 2 })).toThrow();
    expect(() => project([{ ...node("bad"), startedAt: -1 }])).toThrow();
  });
});

function bus() {
  const listeners = new Map<string, Set<(value: unknown) => void>>();
  return {
    listeners,
    on(name: string, fn: (value: unknown) => void) { const group = listeners.get(name) ?? new Set(); group.add(fn); listeners.set(name, group); return () => { group.delete(fn); if (!group.size) listeners.delete(name); }; },
    emit(name: string, value: unknown) { for (const fn of listeners.get(name) ?? []) fn(value); },
  };
}
const ping = (sessionId = "parent") => ({ capabilities: { asyncStatusSnapshot: { kind: "pi-subagents.async-status-snapshot", version: 1 } }, session: { sessionId } });
const settle = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
afterEach(() => vi.useRealTimers());

describe("background RPC bridge", () => {
  it("replaces observations on the compatible pong carrier using only ping/status", async () => {
    vi.useFakeTimers();
    const events = bus(); const methods: string[] = [];
    let runs = [node("worker", "subagent")];
    events.on("subagents:rpc:v1:request", raw => {
      const request = raw as { requestId: string; method: string; params?: unknown };
      methods.push(request.method); expect(request.params).toBeUndefined();
      events.emit(`subagents:rpc:v1:reply:${request.requestId}`, { version: 1, requestId: request.requestId, success: true, data: request.method === "ping" ? ping() : { asyncSnapshot: snapshot(runs) } });
    });
    const bridge = createBackgroundProgressBridge(events); bridge.setSession("parent");
    const modern = { send: vi.fn() };
    expect(methods).toEqual([]);
    bridge.renew(modern, "phone-A"); await settle();
    expect(modern.send.mock.calls[0]?.[0]).toMatchObject({ type: "pong", in_reply_to: "phone-A", background_progress: { available: true, groups: [{ tasks: [{ label: "worker" }] }] } });
    runs = []; await vi.advanceTimersByTimeAsync(2000);
    expect(modern.send.mock.lastCall?.[0]).toMatchObject({ background_progress: { available: true, groups: [] } });
    expect(methods).toEqual(["ping", "status", "ping", "status"]);
    bridge.dispose(); expect(vi.getTimerCount()).toBe(0);
    expect([...events.listeners.keys()]).toEqual(["subagents:rpc:v1:request"]);
  });
  it("times out observation as unavailable without implying completion", async () => {
    vi.useFakeTimers(); const events = bus(); const bridge = createBackgroundProgressBridge(events);
    bridge.setSession("parent"); const peer = { send: vi.fn() }; bridge.renew(peer, "sync");
    await vi.advanceTimersByTimeAsync(3000);
    expect(peer.send.mock.lastCall?.[0]).toMatchObject({ background_progress: { available: false, groups: [] } });
    bridge.unsubscribe(peer); expect(vi.getTimerCount()).toBe(0); expect(events.listeners.size).toBe(0);
  });
  it("rejects wrong-session and malformed provider replies", async () => {
    vi.useFakeTimers(); const events = bus(); let wrong = true;
    events.on("subagents:rpc:v1:request", raw => {
      const r = raw as { requestId: string; method: string };
      events.emit(`subagents:rpc:v1:reply:${r.requestId}`, { version: 1, requestId: r.requestId, success: true, data: r.method === "ping" ? ping(wrong ? "other" : "parent") : { asyncSnapshot: {} } });
    });
    const bridge = createBackgroundProgressBridge(events); bridge.setSession("parent"); const peer = { send: vi.fn() }; bridge.renew(peer, "s"); await settle();
    expect(peer.send.mock.lastCall?.[0].background_progress.available).toBe(false);
    wrong = false; await vi.advanceTimersByTimeAsync(2000); expect(peer.send.mock.lastCall?.[0].background_progress.available).toBe(false);
    bridge.dispose();
  });
  it("expires each phone independently, renews quietly and stops observing without a disconnect callback", async () => {
    vi.useFakeTimers(); const events = bus(); const requests: string[] = [];
    events.on("subagents:rpc:v1:request", raw => {
      const r = raw as { requestId: string; method: string }; requests.push(r.method);
      events.emit(`subagents:rpc:v1:reply:${r.requestId}`, { version: 1, requestId: r.requestId, success: true, data: r.method === "ping" ? ping() : { asyncSnapshot: snapshot([node("worker", "subagent")]) } });
    });
    const bridge = createBackgroundProgressBridge(events); bridge.setSession("parent");
    const peer = { send: vi.fn() };
    bridge.renew(peer, "phone-A"); bridge.renew(peer, "phone-B"); await vi.advanceTimersByTimeAsync(0);
    for (let i = 0; i < 3; i++) {
      await vi.advanceTimersByTimeAsync(5000);
      const before = requests.length;
      bridge.renew(peer, "phone-A"); await settle();
      expect(requests.length).toBe(before); // renewal is not a history/RPC replay
    }
    peer.send.mockClear();
    await vi.advanceTimersByTimeAsync(2000);
    expect(peer.send.mock.calls.map(call => call[0].in_reply_to)).toEqual(["phone-A"]);
    // Both sockets silently vanish: no owner-level disconnect callback is needed.
    await vi.advanceTimersByTimeAsync(15000);
    const count = requests.length;
    await vi.advanceTimersByTimeAsync(30000);
    events.emit("subagent:child-status", {}); await settle();
    expect(requests.length).toBe(count); expect(vi.getTimerCount()).toBe(0);
    expect([...events.listeners.keys()]).toEqual(["subagents:rpc:v1:request"]);
    peer.send.mockClear(); bridge.renew(peer, "reconnected-A"); await settle();
    expect(peer.send.mock.lastCall?.[0]).toMatchObject({ in_reply_to: "reconnected-A", background_progress: { available: true } });
    bridge.dispose();
  });
  it("coalesces refreshes, fences old-session replies and disposes pending listeners", async () => {
    vi.useFakeTimers(); const events = bus(); const requests: { requestId: string; method: string }[] = [];
    events.on("subagents:rpc:v1:request", raw => requests.push(raw as typeof requests[number]));
    const bridge = createBackgroundProgressBridge(events); bridge.setSession("parent");
    const messages: ServerMessage[] = []; const peer = { send: (msg: ServerMessage) => messages.push(msg) };
    bridge.renew(peer, "first"); events.emit("subagent:child-status", {}); events.emit("subagent:async-complete", {});
    expect(requests).toHaveLength(1);
    const old = requests[0]!;
    bridge.setSession("replacement");
    events.emit(`subagents:rpc:v1:reply:${old.requestId}`, { version: 1, requestId: old.requestId, success: true, data: ping() });
    await settle(); await vi.advanceTimersByTimeAsync(0);
    expect(messages).toHaveLength(1); expect(messages[0]).toMatchObject({ background_progress: { session_id: "replacement", available: false } });
    bridge.dispose(); await settle(); expect(vi.getTimerCount()).toBe(0);
    expect([...events.listeners.keys()]).toEqual(["subagents:rpc:v1:request"]);
  });
});
