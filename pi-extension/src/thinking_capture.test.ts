import { afterEach, expect, test, vi } from "vitest";
import type { ExtensionEvent } from "@earendil-works/pi-coding-agent";
import { ThinkingCapture, thinkingFrame, ThinkingPayloadTooLarge, checkedThinkingFrame } from "./thinking_capture.js";
import type { ServerMessage, ThinkingSnapshotWire } from "./protocol/types.js";

type Assistant = Extract<Extract<ExtensionEvent, { type: "message_end" }>["message"], { role: "assistant" }>;
function message(content: Assistant["content"], stopReason: Assistant["stopReason"] = "stop"): Assistant {
  return { role: "assistant", content, stopReason, timestamp: 1, api: "openai-responses", provider: "openai", model: "synthetic", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
}
function harness() {
  const sent: ThinkingSnapshotWire[] = [];
  const capture = new ThinkingCapture(() => "R", (frame: ServerMessage) => { if (frame.type === "pong" && frame.thinking) sent.push(frame.thinking); });
  capture.setSession("S");
  return { capture, sent };
}
afterEach(() => vi.useRealTimers());

test("groups indexed thinking, replaces final summaries, and separates same-run messages", () => {
  vi.useFakeTimers();
  const { capture, sent } = harness();
  const partial = message([{ type: "thinking", thinking: "" }, { type: "text", text: "answer" }, { type: "thinking", thinking: "" }]);
  capture.start(partial, 0, "u");
  for (const [contentIndex, delta] of [[2, "B"], [0, " A\n"]] as const) capture.update({ type: "message_update", message: partial, assistantMessageEvent: { type: "thinking_delta", contentIndex, delta, partial } }, 0, "u");
  expect(sent).toHaveLength(0);
  vi.advanceTimersByTime(200);
  expect(sent[0]!.text).toBe(" A\n\n\nB");
  capture.end(message([{ type: "thinking", thinking: "Final summary" }]), 0, "u");
  expect(sent.at(-1)).toMatchObject({ text: "Final summary", status: "complete" });
  const firstId = sent.at(-1)!.message_id;
  capture.end(message([{ type: "thinking", thinking: "Final-only" }]), 1, "u");
  expect(sent.at(-1)!.message_id).not.toBe(firstId);
  expect(sent.at(-1)!.run_id).toBe("u");
});

test("abort retains omitted readable slots; explicit redaction retracts without signatures", () => {
  vi.useFakeTimers();
  const { capture, sent } = harness();
  const partial = message([{ type: "thinking", thinking: "partial" }]);
  capture.update({ type: "message_update", message: partial, assistantMessageEvent: { type: "thinking_end", contentIndex: 0, content: "partial", partial } }, 0);
  capture.end(message([], "aborted"), 0);
  expect(sent.at(-1)).toMatchObject({ text: "partial", status: "incomplete" });
  capture.start(partial, 1);
  capture.update({ type: "message_update", message: partial, assistantMessageEvent: { type: "thinking_end", contentIndex: 0, content: "partial", partial } }, 1);
  capture.flush();
  capture.end(message([{ type: "thinking", thinking: "[Reasoning redacted]", redacted: true, thinkingSignature: "SECRET" }], "error"), 1);
  expect(sent.at(-1)).toMatchObject({ text: "", status: "incomplete" });
  expect(JSON.stringify(sent)).not.toContain("SECRET");
  const count = sent.length;
  capture.end(message([{ type: "thinking", thinking: "", thinkingSignature: "opaque" }]), 2);
  expect(sent).toHaveLength(count);
});

test("history anchors refer to original events, include in-flight/thought-only and limit zero", () => {
  const { capture } = harness();
  capture.end(message([{ type: "thinking", thinking: "before" }]), 0);
  capture.end(message([{ type: "thinking", thinking: "tool message" }]), 2);
  capture.end(message([{ type: "thinking", thinking: "after" }]), 4);
  // user, tool request, tool result: three events but only two ordinary rows.
  const view = capture.history([1, 2, 3], 3);
  expect(view.snapshots.map(s => s.history)).toEqual([{ index: 0, before_event: 0 }, { index: 1, before_event: 1 }, { index: 2, before_event: 3 }]);
  expect(capture.history([1, 2, 3], 1).snapshots.map(s => s.text)).toEqual(["after"]);
  expect(capture.history([], 2).manifest).toMatchObject({ count: 2, truncated: true });
  expect(capture.history([], 0).manifest).toMatchObject({ count: 0, truncated: true });
  const id = view.snapshots[0]!.message_id;
  capture.setSession("S");
  expect(capture.history([], 3).snapshots[0]!.message_id).toBe(id);
});

test("oversized complete snapshots fail explicitly, never truncate", () => {
  const snapshot: ThinkingSnapshotWire = { session_id: "S", epoch: "E", room_id: "R", message_id: "m", revision: 1, status: "complete", text: "x".repeat(4 * 1024 * 1024), ts: 1 };
  expect(() => thinkingFrame(snapshot)).toThrow(ThinkingPayloadTooLarge);
  expect(() => checkedThinkingFrame({ type: "session_history", in_reply_to: "sync", session_started_at: 1, eos: true, truncated: false, events: [{ type: "agent_message", in_reply_to: "u", text: snapshot.text, ts: 1 }], thinking_history: { kind: "reply", session_id: "S", epoch: "E", count: 0, truncated: false } })).toThrow(ThinkingPayloadTooLarge);
  expect(thinkingFrame({ ...snapshot, text: "x".repeat(4 * 1024 * 1024 - 1024) }).type).toBe("pong");
});
