import { randomUUID } from "node:crypto";
import type { ExtensionEvent } from "@earendil-works/pi-coding-agent";
import type { ServerMessage, ThinkingHistoryWire, ThinkingSnapshotWire } from "./protocol/types.js";

type Update = Extract<ExtensionEvent, { type: "message_update" }>;
type Message = Extract<ExtensionEvent, { type: "message_end" }>["message"];
interface Captured {
  messageId: string;
  source: number;
  ts: number;
  runId?: string;
  slots: Map<number, string>;
  snapshot?: ThinkingSnapshotWire;
}

export class ThinkingPayloadTooLarge extends Error {
  constructor(readonly bytes: number) { super(`Thinking payload ${bytes} bytes exceeds 4194304-byte transport bound`); }
}

/** Mirrors the relay's base64-decoded inner JSON bound, including padding. */
export function thinkingFrame(snapshot: ThinkingSnapshotWire, reply = `thinking:${snapshot.message_id}`): ServerMessage {
  return checkedThinkingFrame({ type: "pong", in_reply_to: reply, thinking: snapshot });
}

/** Also checks the small history manifest addition at the existing transport boundary. */
export function checkedThinkingFrame(frame: ServerMessage): ServerMessage {
  const bytes = Math.ceil(Buffer.byteLength(JSON.stringify(frame), "utf8") / 3) * 3;
  if (bytes > 4 * 1024 * 1024) throw new ThinkingPayloadTooLarge(bytes);
  return frame;
}

/** Only provider-visible indexed strings are retained; never retain signatures. */
export class ThinkingCapture {
  private sessionId = "";
  private suspendedSession: string | undefined;
  get suspended(): boolean { return this.suspendedSession !== undefined; }
  suspend(): void { this.clear(); this.suspendedSession = this.sessionId; }
  private epoch = randomUUID();
  private current?: Captured;
  private messages: Captured[] = [];
  private pending = new Map<string, ThinkingSnapshotWire>();
  private timer?: ReturnType<typeof setTimeout>;

  constructor(private readonly room: () => string, private readonly send: (frame: ServerMessage) => void) {}

  setSession(sessionId: string, reset = false): void {
    if (!sessionId.trim()) throw new Error("Thinking capture requires an SDK session ID");
    if (this.suspendedSession === sessionId) return;
    this.suspendedSession = undefined;
    if (this.sessionId === sessionId && !reset) return;
    this.clear();
    this.sessionId = sessionId;
    this.epoch = randomUUID();
  }

  clear(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
    this.pending.clear();
    this.current = undefined;
    this.messages = [];
  }

  get scope(): Pick<ThinkingHistoryWire, "session_id" | "epoch"> {
    if (!this.sessionId) throw new Error("Thinking capture requires an SDK session ID");
    return { session_id: this.sessionId, epoch: this.epoch };
  }

  start(message: Message, source: number, runId?: string): void {
    if (this.suspended || message.role !== "assistant") return;
    this.finishInterrupted();
    // Validates before allocating; never manufacture a scope from timestamps.
    void this.scope;
    this.current = { messageId: randomUUID(), source, ts: message.timestamp, runId, slots: new Map() };
    this.messages.push(this.current);
  }

  update(event: Update, source: number, runId?: string): void {
    if (this.suspended) return;
    const delta = event.assistantMessageEvent;
    if (delta.type !== "thinking_start" && delta.type !== "thinking_delta" && delta.type !== "thinking_end") return;
    if (!this.current) this.start(event.message, source, runId);
    const current = this.current;
    if (!current) return;
    const slot = delta.partial.content[delta.contentIndex];
    if (slot?.type === "thinking" && slot.redacted) {
      current.slots.delete(delta.contentIndex);
    } else if (delta.type === "thinking_delta") {
      current.slots.set(delta.contentIndex, (current.slots.get(delta.contentIndex) ?? "") + delta.delta);
    } else if (delta.type === "thinking_end") {
      current.slots.set(delta.contentIndex, delta.content);
    }
    this.project(current, "streaming");
  }

  end(message: Message, source: number, runId?: string): void {
    if (this.suspended || message.role !== "assistant") return;
    if (!this.current) this.start(message, source, runId);
    const current = this.current!;
    current.source = source;
    const complete = message.stopReason === "stop" || message.stopReason === "toolUse";
    if (complete) current.slots.clear();
    message.content.forEach((slot, index) => {
      if (slot.type !== "thinking") return;
      if (slot.redacted) current.slots.delete(index);
      else if (complete || slot.thinking.trim()) current.slots.set(index, slot.thinking);
    });
    this.project(current, complete ? "complete" : "incomplete");
    this.current = undefined;
  }

  finishInterrupted(): void {
    if (this.current) this.project(this.current, "incomplete");
    this.current = undefined;
    this.flush();
  }

  private project(message: Captured, status: ThinkingSnapshotWire["status"]): void {
    const text = [...message.slots.entries()].sort(([a], [b]) => a - b).map(([, text]) => text).filter(text => text.trim()).join("\n\n");
    const previous = message.snapshot;
    // Unreadable-only messages have no visible observation to retract.
    if (!previous && !text) return;
    if (previous?.text === text && previous.status === status) return;
    const snapshot: ThinkingSnapshotWire = { ...this.scope, room_id: this.room(), message_id: message.messageId, revision: (previous?.revision ?? 0) + 1, status, text, ts: message.ts, ...(message.runId ? { run_id: message.runId } : {}) };
    thinkingFrame(snapshot); // Fail explicitly before claiming delivery of an oversized snapshot.
    message.snapshot = snapshot;
    this.pending.set(message.messageId, snapshot);
    if (status !== "streaming" || !text || (previous && previous.status !== status)) this.flush();
    else this.timer ??= setTimeout(() => this.flush(), 200);
  }

  flush(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
    const snapshots = [...this.pending.values()];
    this.pending.clear();
    for (const snapshot of snapshots) this.send(thinkingFrame({ ...snapshot, room_id: this.room() }));
  }

  /** Anchors precede client-side tool collapse. position maps capture-buffer
   * sources into the caller's history source indices (identity for legacy).
   * anchorAllEvents changes coordinates, not optional observation selection. */
  history(eventSources: readonly number[], limit: number, position: (source: number) => number | undefined = source => source, anchorAllEvents = false): { manifest: ThinkingHistoryWire; snapshots: ThinkingSnapshotWire[] } {
    const start = Math.max(0, eventSources.length - limit);
    const firstSource = start > 0 ? eventSources[start] : undefined;
    const eligible = this.messages.filter(m => {
      const source = position(m.source);
      return m.snapshot && source !== undefined && (firstSource === undefined || source >= firstSource);
    });
    const selected = limit > 0 ? eligible.slice(-limit) : [];
    const retained = anchorAllEvents ? eventSources : eventSources.slice(start);
    return {
      manifest: { kind: "reply", ...this.scope, count: selected.length, truncated: eligible.length > selected.length },
      snapshots: selected.map((m, index) => {
        const before = retained.findIndex(source => source >= position(m.source)!);
        return { ...m.snapshot!, room_id: this.room(), history: { index, before_event: before < 0 ? retained.length : before } };
      }),
    };
  }
}
