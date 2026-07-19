import { describe, expect, test, vi } from "vitest";
import { EventEmitter } from "node:events";
import { BrokerRemote, parseAddress } from "./broker_remote.js";
import type { Broker, RemoteInjectStatus } from "./broker.js";
import { envelope, type Envelope } from "./envelope.js";
import type { MeshTopologySnapshot, PiRoutingIdentity } from "../mesh/siblings.js";

function keyBytes(seed: number): Uint8Array {
  return Uint8Array.from(
    { length: 32 },
    (_, index) => (seed + index * 29) & 0xff,
  );
}

const KEY_A_BYTES = keyBytes(3);
const KEY_B_BYTES = keyBytes(71);
const KEY_C_BYTES = keyBytes(139);
const KEY_D_BYTES = keyBytes(207);
const KEY_A = Buffer.from(KEY_A_BYTES).toString("base64");
const KEY_B = Buffer.from(KEY_B_BYTES).toString("base64");
const KEY_C = Buffer.from(KEY_C_BYTES).toString("base64");
const KEY_D = Buffer.from(KEY_D_BYTES).toString("base64");
const KEY_A_URL = Buffer.from(KEY_A_BYTES).toString("base64url");
const KEY_B_URL = Buffer.from(KEY_B_BYTES).toString("base64url");

function topology(
  self: PiRoutingIdentity,
  siblings: readonly PiRoutingIdentity[] = [],
): MeshTopologySnapshot {
  return { self, siblings };
}

// ── Test doubles ─────────────────────────────────────────────────────────────

/**
 * Minimal `PiForwardClient` stand-in. Records every outbound `sendEnvelopeToPi`
 * call so tests can assert on what was packed onto the relay, and exposes
 * `emit("envelope", env, fromPc)` so tests can simulate inbound delivery.
 */
class FakePi extends EventEmitter {
  readonly sent: { toPc: string; env: Envelope }[] = [];
  sendEnvelopeToPi(toPc: string, env: Envelope): void {
    this.sent.push({ toPc, env });
  }
  detach(): void { /* no-op */ }
}

interface LinkedDelivery {
  direction: "A→B" | "B→A";
  authenticatedFromPc: string;
  env: Envelope;
}

class BoundedInMemoryPiLink {
  constructor(
    private readonly piA: FakePi,
    private readonly piB: FakePi,
  ) {}

  pumpUntilQuiescent(): LinkedDelivery[] {
    const deliveries: LinkedDelivery[] = [];
    const maxRounds = 16;
    const maxFrames = 128;

    for (let round = 0; round < maxRounds; round += 1) {
      const fromA = this.piA.sent.splice(0);
      const fromB = this.piB.sent.splice(0);
      if (fromA.length === 0 && fromB.length === 0) return deliveries;
      if (deliveries.length + fromA.length + fromB.length > maxFrames) {
        throw new Error(`in-memory Pi link exceeded ${maxFrames} frames`);
      }

      for (const sent of fromA) {
        if (sent.toPc !== KEY_B) {
          throw new Error("in-memory Pi link received an unexpected A destination");
        }
        deliveries.push({
          direction: "A→B",
          authenticatedFromPc: KEY_A_URL,
          env: sent.env,
        });
        this.piB.emit("envelope", sent.env, KEY_A_URL);
      }
      for (const sent of fromB) {
        if (sent.toPc !== KEY_A) {
          throw new Error("in-memory Pi link received an unexpected B destination");
        }
        deliveries.push({
          direction: "B→A",
          authenticatedFromPc: KEY_B_URL,
          env: sent.env,
        });
        this.piA.emit("envelope", sent.env, KEY_B_URL);
      }
    }

    throw new Error(`in-memory Pi link did not quiesce after ${maxRounds} rounds`);
  }
}

interface FakeBrokerOptions {
  injectStatus?: RemoteInjectStatus;
  /** Local peer names the fake broker reports via `peerNames()`. Used by
   *  `BrokerRemote` to seed `lastLocalPeers` and to answer
   *  `peers_request` envelopes. Defaults to a single self peer. */
  localPeers?: string[];
}

function makeFakeBroker(opts: FakeBrokerOptions = {}): {
  broker: Broker;
  injectFromRemote: ReturnType<typeof vi.fn>;
  setRemoteRouter: ReturnType<typeof vi.fn>;
  clearRemoteRouter: ReturnType<typeof vi.fn>;
  currentRemoteRouter: () => unknown;
  peerNames: ReturnType<typeof vi.fn>;
  localPeerInfos: ReturnType<typeof vi.fn>;
  injected: Envelope[];
} {
  const injected: Envelope[] = [];
  const status = opts.injectStatus ?? "received";
  const injectFromRemote = vi.fn((env: Envelope) => {
    injected.push(env);
    return status;
  });
  let currentRemoteRouter: unknown = null;
  const setRemoteRouter = vi.fn((router: unknown) => {
    currentRemoteRouter = router;
  });
  const clearRemoteRouter = vi.fn((expected: unknown) => {
    if (currentRemoteRouter === expected) currentRemoteRouter = null;
  });
  let _localPeers = opts.localPeers ?? ["self"];
  const peerNames = vi.fn(() => [..._localPeers]);
  // plan/38 Fase 2: the cross-PC push reads the structured local inventory.
  // Synthesize `{cwd:"", name:addr, address:addr}` from the same address list.
  const localPeerInfos = vi.fn(() => _localPeers.map((address) => ({ cwd: "", name: address, address })));
  // Expose a setter for tests that mutate the local set mid-test.
  (peerNames as unknown as { set: (p: string[]) => void }).set = (p: string[]) => {
    _localPeers = p;
  };
  const broker = {
    injectFromRemote,
    setRemoteRouter,
    clearRemoteRouter,
    peerNames,
    localPeerInfos,
  } as unknown as Broker;
  return {
    broker,
    injectFromRemote,
    setRemoteRouter,
    clearRemoteRouter,
    currentRemoteRouter: () => currentRemoteRouter,
    peerNames,
    localPeerInfos,
    injected,
  };
}

// ── parseAddress ─────────────────────────────────────────────────────────────

describe("parseAddress", () => {
  test("no prefix → null", () => {
    expect(parseAddress("backend")).toBeNull();
  });
  test("colon at end → null (empty peer name)", () => {
    expect(parseAddress("trab:")).toBeNull();
  });
  test("colon at start → null (empty pc label)", () => {
    expect(parseAddress(":agent")).toBeNull();
  });
  test("simple pc:peer → both parts", () => {
    expect(parseAddress("trab:agent-1")).toEqual({ pcLabel: "trab", peerName: "agent-1" });
  });
  test("multiple colons → split on first", () => {
    expect(parseAddress("trab:sub:agent")).toEqual({ pcLabel: "trab", peerName: "sub:agent" });
  });
});

// ── tryRouteOutbound ────────────────────────────────────────────────────────

describe("BrokerRemote.tryRouteOutbound", () => {
  test("no prefix → false (broker delivers locally)", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "self", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
    });
    fakePi.sent.length = 0;  // drop bootstrap peers_request

    const env = envelope("sess-3", "agent-1", { x: 1 });
    expect(br.tryRouteOutbound(env)).toBe(false);
    expect(fakePi.sent.length).toBe(0);
  });

  test("self prefix → false (local handles)", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology({ pcLabel: "self", pcPubkey: KEY_A }),
    });

    const env = envelope("sess-3", "self:agent-1", { x: 1 });
    expect(br.tryRouteOutbound(env)).toBe(false);
    expect(fakePi.sent.length).toBe(0);
  });

  test("unknown prefix → false (backward-compat for local names with ':')", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "self", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
    });
    fakePi.sent.length = 0;  // drop bootstrap peers_request

    const env = envelope("sess-3", "weird:peer", { x: 1 });
    expect(br.tryRouteOutbound(env)).toBe(false);
    expect(fakePi.sent.length).toBe(0);
  });

  test("known sibling prefix → packs frame to relay, rewrites from", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
    });

    const env = envelope("sess-3", "trab:agent-1", { x: 1 });
    expect(br.tryRouteOutbound(env)).toBe(true);
    expect(fakePi.sent.length).toBeGreaterThanOrEqual(1);
    const main = fakePi.sent.find((s) => s.env.id === env.id);
    expect(main).toBeDefined();
    expect(main!.toPc).toBe(KEY_B);
    expect(main!.env.from).toBe("casa:sess-3");
    expect(main!.env.to).toBe("trab:agent-1");
  });

  test("cache miss triggers a peers_request alongside the main send", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
    });
    // Bootstrap fires peers_request to every sibling on construction.
    // Clear that out so we can verify the cache-miss path also fires one.
    fakePi.sent.length = 0;

    const env = envelope("sess-3", "trab:agent-1", { x: 1 });
    br.tryRouteOutbound(env);

    const peersReq = fakePi.sent.find((s) =>
      (s.env.body as { type?: string } | null)?.type === "peers_request",
    );
    expect(peersReq).toBeDefined();
    expect(peersReq!.toPc).toBe(KEY_B);
  });

  test("does not trigger peers_request when cache is already populated", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
    });

    // Prime the cache via peers_update
    fakePi.emit("envelope", envelope(
      "trab:_broker_remote", "casa:_broker_remote",
      { type: "peers_update", peers: ["agent-1"] },
    ), KEY_B);

    fakePi.sent.length = 0;
    const env = envelope("sess-3", "trab:agent-1", { x: 1 });
    br.tryRouteOutbound(env);

    const peersReq = fakePi.sent.find((s) =>
      (s.env.body as { type?: string } | null)?.type === "peers_request",
    );
    expect(peersReq).toBeUndefined();
  });
});

// ── handleIncoming ──────────────────────────────────────────────────────────

describe("BrokerRemote.handleIncoming (anti-spoof + injection)", () => {
  test("from_pc not in sibling cache → drop + log", () => {
    const fakePi = new FakePi();
    const { broker, injectFromRemote } = makeFakeBroker();
    const logs: string[] = [];
    new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
      log: (m) => logs.push(m),
    });

    fakePi.emit("envelope", envelope("evil:sess", "casa:agent-1", { x: 1 }), KEY_D);

    expect(injectFromRemote).not.toHaveBeenCalled();
    expect(logs.some((line) => /reason=unknown_from_pc/.test(line))).toBe(true);
    expect(logs.every((line) => !line.includes(KEY_D))).toBe(true);
  });

  test("sender prefix is display-only and rewrites to the receiver-local alias", () => {
    const fakePi = new FakePi();
    const { broker, injectFromRemote } = makeFakeBroker();
    const logs: string[] = [];
    new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
      log: (m) => logs.push(m),
    });

    fakePi.emit("envelope", envelope("sender-old:sess", "receiver-old:agent-1", { x: 1 }), KEY_B_URL);

    expect(injectFromRemote).toHaveBeenCalledTimes(1);
    expect(injectFromRemote.mock.calls[0]![0]).toMatchObject({
      from: "trab:sess",
      to: "agent-1",
    });
    expect(logs).toEqual([]);
  });

  test("valid envelope → strip to-prefix, injectFromRemote, ACK back", () => {
    const fakePi = new FakePi();
    const { broker, injectFromRemote } = makeFakeBroker({ injectStatus: "received" });
    new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
    });

    const inbound = envelope("trab:agent-1", "casa:sess-3", { hello: "world" });
    fakePi.emit("envelope", inbound, KEY_B);

    expect(injectFromRemote).toHaveBeenCalledTimes(1);
    const injected = injectFromRemote.mock.calls[0]![0] as Envelope;
    expect(injected.from).toBe("trab:agent-1");
    expect(injected.to).toBe("sess-3");  // prefix stripped

    // ACK packed back to K_B
    const ack = fakePi.sent.find((s) =>
      (s.env.body as { type?: string } | null)?.type === "ack",
    );
    expect(ack).toBeDefined();
    expect(ack!.toPc).toBe(KEY_B);
    expect(ack!.env.re).toBe(inbound.id);
    expect((ack!.env.body as { status: string }).status).toBe("received");
  });

  test("target prefix is display-only after Relay selected this Pi", () => {
    const fakePi = new FakePi();
    const { broker, injectFromRemote } = makeFakeBroker();
    const logs: string[] = [];
    new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
      log: (m) => logs.push(m),
    });

    const inbound = envelope("trab:agent-1", "other:peer", { x: 1 });
    fakePi.emit("envelope", inbound, KEY_B);

    expect(injectFromRemote).toHaveBeenCalledTimes(1);
    expect(injectFromRemote.mock.calls[0]![0]).toMatchObject({
      from: "trab:agent-1",
      to: "peer",
    });
    expect(logs).toEqual([]);
  });

  test("incoming ACK does not generate a recursive ACK", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
    });

    const ackEnv: Envelope = envelope(
      "trab:broker", "casa:sess-3",
      { type: "ack", status: "received", target: "agent-1" },
      "01976000-0000-7000-8000-000000000000",
    );
    fakePi.emit("envelope", ackEnv, KEY_B);

    const generatedAck = fakePi.sent.find((s) =>
      (s.env.body as { type?: string } | null)?.type === "ack",
    );
    expect(generatedAck).toBeUndefined();
  });
});

// ── peers_update / peers_request control ────────────────────────────────────

describe("BrokerRemote: control envelopes (peers_update / peers_request)", () => {
  test("peers_update populates cache (getRemotePeers returns)", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
    });

    fakePi.emit("envelope", envelope(
      "trab:_broker_remote", "casa:_broker_remote",
      { type: "peers_update", peers: ["agent-1", "agent-2"] },
    ), KEY_B);

    expect(br.getRemotePeers("trab")).toEqual(["agent-1", "agent-2"]);
    expect(br.listRemotePeers()).toEqual(["trab:agent-1", "trab:agent-2"]);
  });

  test("peers_update with peers_detailed → listRemotePeerInfos fills pc + prefixes address (plan/38 Fase 2)", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
    });

    fakePi.emit("envelope", envelope(
      "trab:_broker_remote", "casa:_broker_remote",
      {
        type: "peers_update",
        peers: ["/w/app@App", "/w/api@Api"],
        peers_detailed: [
          { cwd: "/w/app", name: "App", address: "/w/app@App" },
          { cwd: "/w/api", name: "Api", address: "/w/api@Api" },
        ],
      },
    ), KEY_B);

    // Addresses (the `peers` half) get the sibling-label prefix.
    expect(br.listRemotePeers()).toEqual(["trab:/w/app@App", "trab:/w/api@Api"]);
    // Structured: `pc` filled from the verified sibling label, cwd/name preserved,
    // address prefixed `<pc>:<cwd>@<nome>` — this is what powers `peers_detailed`.
    expect(br.listRemotePeerInfos()).toEqual([
      { pc: "trab", cwd: "/w/app", name: "App", address: "trab:/w/app@App" },
      { pc: "trab", cwd: "/w/api", name: "Api", address: "trab:/w/api@Api" },
    ]);
  });

  test("back-compat: peers_update with ONLY peers[] (Fase-1 sibling) → synthesized infos, mesh not broken", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
    });

    // An older sibling sends addresses only — no peers_detailed.
    fakePi.emit("envelope", envelope(
      "trab:_broker_remote", "casa:_broker_remote",
      { type: "peers_update", peers: ["/w/app@App"] },
    ), KEY_B);

    expect(br.listRemotePeers()).toEqual(["trab:/w/app@App"]);
    // Synthesized: cwd "", name == address, pc filled, address prefixed. Routing
    // still works (address is intact); only cwd/name grouping is degraded.
    expect(br.listRemotePeerInfos()).toEqual([
      { pc: "trab", cwd: "", name: "/w/app@App", address: "trab:/w/app@App" },
    ]);
  });

  test("cache TTL expires entries", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
      cacheTtlMs: 10,  // tight TTL for tests
    });

    fakePi.emit("envelope", envelope(
      "trab:_broker_remote", "casa:_broker_remote",
      { type: "peers_update", peers: ["agent-1"] },
    ), KEY_B);
    expect(br.getRemotePeers("trab")).toEqual(["agent-1"]);

    return new Promise<void>((resolve) => {
      setTimeout(() => {
        expect(br.getRemotePeers("trab")).toEqual([]);
        resolve();
      }, 30);
    });
  });

  test("peers_request triggers peers_update reply with current local peers", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker({ localPeers: ["sess-3", "agent-1"] });
    new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
    });
    fakePi.sent.length = 0;

    fakePi.emit("envelope", envelope(
      "trab:_broker_remote", "casa:_broker_remote",
      { type: "peers_request" },
    ), KEY_B);

    const reply = fakePi.sent.find((s) =>
      (s.env.body as { type?: string } | null)?.type === "peers_update",
    );
    expect(reply).toBeDefined();
    expect(reply!.toPc).toBe(KEY_B);
    expect((reply!.env.body as { peers: string[] }).peers).toEqual(["sess-3", "agent-1"]);
  });

  test("peers_request reply pulls the LIVE local inventory (broker.localPeerInfos), not a stale cache", () => {
    // Regression: in a single-peer mesh (only the wrapper itself), no
    // peer_joined event ever fires for the joiner, so a cached local list
    // would stay []. Reading the broker's live inventory bypasses that.
    const fakePi = new FakePi();
    const { broker, localPeerInfos } = makeFakeBroker({ localPeers: ["MacMini"] });
    new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "MacMini", pcPubkey: KEY_B },
        [{ pcLabel: "MacBook", pcPubkey: KEY_A }],
      ),
    });
    // Note: no `onLocalPeersChanged` was ever called. Bootstrap traffic
    // was sent; clear it so we observe the reply path cleanly.
    fakePi.sent.length = 0;

    fakePi.emit("envelope", envelope(
      "MacBook:_broker_remote", "MacMini:_broker_remote",
      { type: "peers_request" },
    ), KEY_A);

    const reply = fakePi.sent.find((s) =>
      (s.env.body as { type?: string } | null)?.type === "peers_update",
    );
    expect(reply).toBeDefined();
    const body = reply!.env.body as { peers: string[]; peers_detailed: Array<{ cwd: string; name: string; address: string }> };
    expect(body.peers).toEqual(["MacMini"]);
    // plan/38 Fase 2: the reply also carries the structured roster.
    expect(body.peers_detailed).toEqual([{ cwd: "", name: "MacMini", address: "MacMini" }]);
    expect(localPeerInfos).toHaveBeenCalled();
  });

  test("onLocalPeersChanged pushes peers_update to every sibling", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [
        { pcLabel: "trab", pcPubkey: KEY_B },
        { pcLabel: "movel", pcPubkey: KEY_C },
      ],
      ),
    });
    // Discard bootstrap announce/request traffic; we only care about the
    // peers_update emitted by `onLocalPeersChanged` below.
    fakePi.sent.length = 0;
    br.onLocalPeersChanged(["sess-3"]);

    const updates = fakePi.sent.filter((s) =>
      (s.env.body as { type?: string } | null)?.type === "peers_update",
    );
    expect(updates.map((u) => u.toPc).sort()).toEqual([KEY_B, KEY_C]);
  });

  test("periodic re-announce re-pushes to a STABLE sibling set (keeps roster warm vs TTL)", () => {
    // Regression: without a timer, a stable mesh never re-announces (only NEW
    // siblings get the bootstrap pair), so a single dropped push lets both
    // caches expire and the peer silently drops from list_peers overnight.
    vi.useFakeTimers();
    try {
      const fakePi = new FakePi();
      const { broker } = makeFakeBroker({ localPeers: ["sess-3"] });
      const br = new BrokerRemote({
        broker, pi: fakePi as never,
        topology: topology(
          { pcLabel: "casa", pcPubkey: KEY_A },
          [{ pcLabel: "trab", pcPubkey: KEY_B }],
        ),
        reannounceIntervalMs: 1_000,
      });
      fakePi.sent.length = 0;  // drop bootstrap request+push

      vi.advanceTimersByTime(1_000);
      // One full re-announce cycle = the bootstrap pair (request + push).
      const byType = (t: string) => fakePi.sent.filter(
        (s) => (s.env.body as { type?: string } | null)?.type === t,
      );
      expect(byType("peers_request").map((s) => s.toPc)).toEqual([KEY_B]);
      expect(byType("peers_update").map((s) => s.toPc)).toEqual([KEY_B]);

      // detach() stops the timer — no further traffic.
      br.detach();
      fakePi.sent.length = 0;
      vi.advanceTimersByTime(5_000);
      expect(fakePi.sent.length).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });
});

// ── transport_error propagation ──────────────────────────────────────────────

describe("BrokerRemote: trusted transport_error provenance boundary", () => {
  const VALID_RE = "01976000-0000-7000-8000-000000000000";

  function relayError(overrides: Partial<Envelope> = {}): Envelope {
    return {
      ...envelope(
        "_relay",
        "casa:sess-3",
        { type: "transport_error", reason: "offline", ignored: "private-detail" },
        VALID_RE,
      ),
      ...overrides,
    };
  }

  function ackCount(fakePi: FakePi): number {
    return fakePi.sent.filter(
      (sent) => (sent.env.body as { type?: string } | null)?.type === "ack",
    ).length;
  }

  test.each(["offline", "not_authorized", "bad_envelope"] as const)(
    "converts trusted Relay reason %s to exact local broker provenance without ACK",
    (reason) => {
      const fakePi = new FakePi();
      const { broker, injectFromRemote } = makeFakeBroker();
      new BrokerRemote({
        broker, pi: fakePi as never,
        topology: topology(
          { pcLabel: "casa", pcPubkey: KEY_A },
          [{ pcLabel: "trab", pcPubkey: KEY_B }],
        ),
      });

      const incoming = relayError({
        body: { type: "transport_error", reason, ignored: "must-not-cross" },
      });
      fakePi.emit("envelope", incoming, "_relay");

      expect(injectFromRemote).toHaveBeenCalledTimes(1);
      expect(injectFromRemote).toHaveBeenCalledWith({
        ...incoming,
        from: "broker",
        to: "sess-3",
        body: { type: "transport_error", reason },
      });
      expect(ackCount(fakePi)).toBe(0);
    },
  );

  test("drops malformed privileged frames before UDS injection or ACK", () => {
    const fakePi = new FakePi();
    const { broker, injectFromRemote } = makeFakeBroker();
    const logs: string[] = [];
    new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
      log: (message) => logs.push(message),
    });

    const invalidFrames: Envelope[] = [
      relayError({ from: "private-origin:sender" }),
      relayError({ id: "01976000000070008000000000000000" }),
      relayError({ id: "not-a-uuid" }),
      relayError({ re: null }),
      relayError({ re: "01976000000070008000000000000000" }),
      relayError({ re: "not-a-uuid" }),
      relayError({ to: ["casa:private-target"] }),
      relayError({ to: "broadcast" }),
      relayError({ to: "casa:broadcast" }),
      relayError({ to: "casa:" }),
      relayError({ body: { type: "ack", reason: "offline" } }),
      relayError({ body: { type: "transport_error" } }),
      relayError({
        to: "casa:private-target",
        body: { type: "transport_error", reason: "TOP_SECRET_BODY" },
      }),
    ];
    for (const frame of invalidFrames) fakePi.emit("envelope", frame, "_relay");

    expect(injectFromRemote).not.toHaveBeenCalled();
    expect(ackCount(fakePi)).toBe(0);
    expect(logs).toHaveLength(invalidFrames.length);
    expect(logs.every((line) => /event=drop reason=invalid_relay_error/.test(line))).toBe(true);
    for (const privateValue of [
      "private-origin",
      "private-target",
      "TOP_SECRET_BODY",
      KEY_B,
    ]) {
      expect(logs.every((line) => !line.includes(privateValue))).toBe(true);
    }
  });

  test.each([
    [KEY_B, "_relay"],
    ["_relay ", "_relay"],
    ["_RELAY", "_relay"],
  ])("requires the exact authenticated outer sentinel: %s", (fromPc, innerFrom) => {
    const fakePi = new FakePi();
    const { broker, injectFromRemote } = makeFakeBroker();
    new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
      log: () => undefined,
    });

    fakePi.emit("envelope", relayError({ from: innerFrom }), fromPc);

    expect(injectFromRemote).not.toHaveBeenCalled();
    expect(ackCount(fakePi)).toBe(0);
  });

  test.each([
    {
      from: "sender-old:sender",
      body: { type: "transport_error", reason: "offline" },
      expectedFrom: "trab:sender",
    },
    {
      from: "sender-old:_relay",
      body: { text: "_relay" },
      expectedFrom: "trab:_relay",
    },
  ])("keeps authenticated sibling text ordinary for $expectedFrom", ({ from, body, expectedFrom }) => {
    const fakePi = new FakePi();
    const { broker, injectFromRemote } = makeFakeBroker({ injectStatus: "received" });
    new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
    });

    const incoming = envelope(from, "casa:sess-3", body);
    fakePi.emit("envelope", incoming, KEY_B);

    expect(injectFromRemote).toHaveBeenCalledTimes(1);
    expect(injectFromRemote.mock.calls[0]![0]).toMatchObject({
      from: expectedFrom,
      to: "sess-3",
      body,
    });
    expect(injectFromRemote.mock.calls[0]![0].from).not.toBe("broker");
    expect(ackCount(fakePi)).toBe(1);
  });
});

// ── setTopology ──────────────────────────────────────────────────────────────

describe("BrokerRemote.setTopology", () => {
  test("dropping a sibling clears its cache entry", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [
        { pcLabel: "trab", pcPubkey: KEY_B },
        { pcLabel: "movel", pcPubkey: KEY_C },
      ],
      ),
    });
    fakePi.emit("envelope", envelope(
      "trab:_broker_remote", "casa:_broker_remote",
      { type: "peers_update", peers: ["agent-1"] },
    ), KEY_B);
    expect(br.getRemotePeers("trab")).toEqual(["agent-1"]);

    br.setTopology(topology(
      { pcLabel: "casa", pcPubkey: KEY_A },
      [{ pcLabel: "movel", pcPubkey: KEY_C }],
    ));
    expect(br.getRemotePeers("trab")).toEqual([]);
  });

  test("self never appears in sibling set", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [
        { pcLabel: "casa", pcPubkey: KEY_A },     // self by both
        { pcLabel: "trab", pcPubkey: KEY_B },
      ],
      ),
    });

    const env = envelope("sess-3", "casa:agent-1", { x: 1 });
    expect(br.tryRouteOutbound(env)).toBe(false);  // self → local
  });
});

// ── Bootstrap: warm cache via peers_request ──────────────────────────────────

describe("BrokerRemote: bootstrap peers_request (plan/25 Wave B)", () => {
  test("constructor pings every initial sibling with peers_request", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [
        { pcLabel: "trab", pcPubkey: KEY_B },
        { pcLabel: "movel", pcPubkey: KEY_C },
      ],
      ),
    });

    const requests = fakePi.sent.filter((s) =>
      (s.env.body as { type?: string } | null)?.type === "peers_request",
    );
    expect(requests.map((r) => r.toPc).sort()).toEqual([KEY_B, KEY_C]);
  });

  test("constructor also announces our own peers (peers_update) to every sibling", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker({ localPeers: ["MacMini"] });
    new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "MacMini", pcPubkey: KEY_B },
        [{ pcLabel: "MacBook", pcPubkey: KEY_A }],
      ),
    });

    const announces = fakePi.sent.filter((s) =>
      (s.env.body as { type?: string } | null)?.type === "peers_update",
    );
    expect(announces.length).toBe(1);
    expect(announces[0]!.toPc).toBe(KEY_A);
    expect((announces[0]!.env.body as { peers: string[] }).peers).toEqual(["MacMini"]);
  });

  test("no peers_request emitted when there are zero siblings", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology({ pcLabel: "casa", pcPubkey: KEY_A }),
    });

    expect(fakePi.sent.length).toBe(0);
  });

  test("setTopology sends peers_request only to newly-added siblings", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [{ pcLabel: "trab", pcPubkey: KEY_B }],
      ),
    });
    // Drop initial bootstrap traffic so the assertion is isolated.
    fakePi.sent.length = 0;

    // Replace with set that keeps K_B and adds K_C. We expect a single
    // peers_request to K_C; K_B should NOT be re-pinged.
    br.setTopology(topology(
      { pcLabel: "casa", pcPubkey: KEY_A },
      [
        { pcLabel: "trab", pcPubkey: KEY_B },
        { pcLabel: "movel", pcPubkey: KEY_C },
      ],
    ));

    const requests = fakePi.sent.filter((s) =>
      (s.env.body as { type?: string } | null)?.type === "peers_request",
    );
    expect(requests.map((r) => r.toPc)).toEqual([KEY_C]);
  });

  test("setTopology removes a sibling without firing peers_request for the survivors", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker, pi: fakePi as never,
      topology: topology(
        { pcLabel: "casa", pcPubkey: KEY_A },
        [
        { pcLabel: "trab", pcPubkey: KEY_B },
        { pcLabel: "movel", pcPubkey: KEY_C },
      ],
      ),
    });
    fakePi.sent.length = 0;

    br.setTopology(topology(
      { pcLabel: "casa", pcPubkey: KEY_A },
      [{ pcLabel: "movel", pcPubkey: KEY_C }],
    ));

    const requests = fakePi.sent.filter((s) =>
      (s.env.body as { type?: string } | null)?.type === "peers_request",
    );
    expect(requests).toEqual([]);
  });
});

describe("BrokerRemote canonical topology and receiver-local routing", () => {
  test.each([KEY_B, KEY_B_URL])(
    "canonicalizes authenticated from_pc variant %s and ignores divergent text aliases",
    (fromPc) => {
      const fakePi = new FakePi();
      const { broker, injectFromRemote } = makeFakeBroker();
      new BrokerRemote({
        broker,
        pi: fakePi as never,
        topology: topology(
          { pcLabel: "Captiva-RTX-4090", pcPubkey: KEY_A },
          [{ pcLabel: "mac", pcPubkey: KEY_B }],
        ),
        reannounceIntervalMs: 0,
      });
      fakePi.sent.length = 0;

      fakePi.emit(
        "envelope",
        envelope(
          "Mac:C:\\work\\sender@agent",
          "RTX4090:/local@target",
          { hello: "world" },
        ),
        fromPc,
      );

      expect(injectFromRemote).toHaveBeenCalledTimes(1);
      expect(injectFromRemote.mock.calls[0]![0]).toMatchObject({
        from: "mac:C:\\work\\sender@agent",
        to: "/local@target",
      });
    },
  );

  test("invalid and unknown authenticated keys drop with metadata-only diagnostics", () => {
    const fakePi = new FakePi();
    const { broker, injectFromRemote } = makeFakeBroker();
    const logs: string[] = [];
    new BrokerRemote({
      broker,
      pi: fakePi as never,
      topology: topology(
        { pcLabel: "self", pcPubkey: KEY_A },
        [{ pcLabel: "remote", pcPubkey: KEY_B }],
      ),
      reannounceIntervalMs: 0,
      log: (message) => logs.push(message),
    });

    fakePi.emit(
      "envelope",
      envelope("raw-secret:sender", "raw-target:local", { secret: true }),
      "bad key",
    );
    fakePi.emit(
      "envelope",
      envelope("raw-secret:sender", "raw-target:local", { secret: true }),
      KEY_D,
    );

    expect(injectFromRemote).not.toHaveBeenCalled();
    expect(logs).toHaveLength(2);
    expect(logs[0]).toMatch(/reason=invalid_from_pc/);
    expect(logs[1]).toMatch(/reason=unknown_from_pc fingerprint=[0-9a-f]{8}/);
    expect(logs.every((line) => !/raw-secret|raw-target|bad key|secret/.test(line))).toBe(true);
  });

  test("rejects a sibling alias that conflicts with the self alias", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();

    expect(() => new BrokerRemote({
      broker,
      pi: fakePi as never,
      topology: topology(
        { pcLabel: "same", pcPubkey: KEY_A },
        [{ pcLabel: "same", pcPubkey: KEY_B }],
      ),
      reannounceIntervalMs: 0,
    })).toThrow(/alias conflicts with self/);
  });

  test("alias-only topology refresh preserves cache, rekeys roster, and reboots controls", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker,
      pi: fakePi as never,
      topology: topology(
        { pcLabel: "self-old", pcPubkey: KEY_A },
        [{ pcLabel: "remote-old", pcPubkey: KEY_B }],
      ),
      reannounceIntervalMs: 0,
    });
    fakePi.sent.length = 0;
    fakePi.emit(
      "envelope",
      envelope(
        "sender-old:_broker_remote",
        "receiver-old:_broker_remote",
        { type: "peers_update", peers: ["/remote@app"] },
      ),
      KEY_B_URL,
    );
    expect(br.listRemotePeers()).toEqual(["remote-old:/remote@app"]);
    fakePi.sent.length = 0;

    br.setTopology(
      topology(
        { pcLabel: "self-new", pcPubkey: KEY_A },
        [{ pcLabel: "remote-new", pcPubkey: KEY_B_URL }],
      ),
    );

    expect(br.listRemotePeers()).toEqual(["remote-new:/remote@app"]);
    expect(fakePi.sent.filter((sent) =>
      (sent.env.body as { type?: string } | null)?.type === "peers_request"
    ).map((sent) => sent.toPc)).toEqual([KEY_B]);
    expect(fakePi.sent.filter((sent) =>
      (sent.env.body as { type?: string } | null)?.type === "peers_update"
    ).map((sent) => sent.toPc)).toEqual([KEY_B]);
    const outbound = envelope("local", "remote-new:agent", { task: true });
    br.tryRouteOutbound(outbound);
    expect(fakePi.sent.find((sent) => sent.env.id === outbound.id)?.env.from)
      .toBe("self-new:local");

    expect(() => br.setTopology(topology(
      { pcLabel: "self-new", pcPubkey: KEY_C },
      [{ pcLabel: "remote-new", pcPubkey: KEY_B }],
    ))).toThrow(/self public key/);
    expect(br.listRemotePeers()).toEqual(["remote-new:/remote@app"]);
  });

  test("prototype-like aliases remain own data keys in grouped listings", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker,
      pi: fakePi as never,
      topology: topology(
        { pcLabel: "self", pcPubkey: KEY_A },
        [{ pcLabel: "__proto__", pcPubkey: KEY_B }],
      ),
      reannounceIntervalMs: 0,
    });
    fakePi.emit("envelope", envelope(
      "ignored:_broker_remote",
      "self:_broker_remote",
      { type: "peers_update", peers: ["remote"] },
    ), KEY_B);

    const grouped = br.getAllRemote();
    expect(Object.prototype.hasOwnProperty.call(grouped, "__proto__")).toBe(true);
    expect(grouped["__proto__"]).toEqual(["remote"]);
    expect(Object.getPrototypeOf(grouped)).toBe(Object.prototype);
  });

  test("invalid alias/key topology is rejected atomically", () => {
    const fakePi = new FakePi();
    const { broker } = makeFakeBroker();
    const br = new BrokerRemote({
      broker,
      pi: fakePi as never,
      topology: topology(
        { pcLabel: "self", pcPubkey: KEY_A },
        [{ pcLabel: "remote", pcPubkey: KEY_B }],
      ),
      reannounceIntervalMs: 0,
    });
    fakePi.sent.length = 0;

    expect(() => br.setTopology(topology(
      { pcLabel: "self", pcPubkey: KEY_A },
      [
        { pcLabel: "duplicate", pcPubkey: KEY_C },
        { pcLabel: "duplicate", pcPubkey: KEY_D },
      ],
    ))).toThrow(/duplicate sibling routing alias/);
    expect(() => br.setTopology(topology(
      { pcLabel: "self", pcPubkey: KEY_A },
      [
        { pcLabel: "one", pcPubkey: KEY_B },
        { pcLabel: "two", pcPubkey: KEY_B_URL },
      ],
    ))).toThrow(/duplicate sibling public key/);

    const outbound = envelope("local", "remote:agent", { task: true });
    expect(br.tryRouteOutbound(outbound)).toBe(true);
    expect(fakePi.sent.find((sent) => sent.env.id === outbound.id)?.toPc).toBe(KEY_B);
  });

  test("missing technical prefixes fail closed without logging addresses", () => {
    const fakePi = new FakePi();
    const { broker, injectFromRemote } = makeFakeBroker();
    const logs: string[] = [];
    new BrokerRemote({
      broker,
      pi: fakePi as never,
      topology: topology(
        { pcLabel: "self", pcPubkey: KEY_A },
        [{ pcLabel: "remote", pcPubkey: KEY_B }],
      ),
      reannounceIntervalMs: 0,
      log: (message) => logs.push(message),
    });

    fakePi.emit("envelope", envelope("no-prefix", "self:target", { x: 1 }), KEY_B);
    fakePi.emit("envelope", envelope("old:sender", "no-prefix", { x: 2 }), KEY_B);
    fakePi.emit("envelope", envelope("old:", "self:target", { x: 3 }), KEY_B);
    fakePi.emit("envelope", {
      ...envelope("old:sender", "self:target", { x: 4 }),
      to: ["self:target"],
    }, KEY_B);

    expect(injectFromRemote).not.toHaveBeenCalled();
    expect(logs).toEqual([
      expect.stringMatching(/reason=invalid_cross_pc_address/),
      expect.stringMatching(/reason=invalid_cross_pc_address/),
      expect.stringMatching(/reason=invalid_cross_pc_address/),
      expect.stringMatching(/reason=invalid_to/),
    ]);
    expect(logs.every((line) => !/no-prefix|target|sender/.test(line))).toBe(true);
  });
});

describe("BrokerRemote linked two-PC matrix", () => {
  test("exchanges receiver-local rosters, messages, ACKs, and replies in both directions", () => {
    const localPeersA = ["/mac/orchestrator@Orch", "/mac/api@Api"];
    const localPeersB = ["/rtx/worker@Worker", "/rtx/tests@Test"];
    const piA = new FakePi();
    const piB = new FakePi();
    const brokerA = makeFakeBroker({ localPeers: localPeersA });
    const brokerB = makeFakeBroker({ localPeers: localPeersB });
    const remoteA = new BrokerRemote({
      broker: brokerA.broker,
      pi: piA as never,
      topology: topology(
        { pcLabel: "Mac", pcPubkey: KEY_A },
        [{ pcLabel: "RTX4090", pcPubkey: KEY_B }],
      ),
      reannounceIntervalMs: 0,
    });
    const remoteB = new BrokerRemote({
      broker: brokerB.broker,
      pi: piB as never,
      topology: topology(
        { pcLabel: "Captiva-RTX-4090", pcPubkey: KEY_B },
        [{ pcLabel: "mac", pcPubkey: KEY_A }],
      ),
      reannounceIntervalMs: 0,
    });
    const link = new BoundedInMemoryPiLink(piA, piB);

    try {
      const bootstrap = link.pumpUntilQuiescent();
      expect(bootstrap.some((delivery) =>
        (delivery.env.body as { type?: string } | null)?.type === "peers_request"
      )).toBe(true);
      expect(bootstrap.some((delivery) =>
        (delivery.env.body as { type?: string } | null)?.type === "peers_update"
      )).toBe(true);
      expect(piA.sent).toEqual([]);
      expect(piB.sent).toEqual([]);

      expect(remoteA.getAllRemote()).toEqual({ RTX4090: localPeersB });
      expect(remoteA.getRemotePeers("RTX4090")).toEqual(localPeersB);
      expect(remoteA.listRemotePeers()).toEqual(
        localPeersB.map((address) => `RTX4090:${address}`),
      );
      expect(remoteA.listRemotePeerInfos()).toEqual(
        localPeersB.map((address) => ({
          pc: "RTX4090",
          cwd: "",
          name: address,
          address: `RTX4090:${address}`,
        })),
      );

      expect(remoteB.getAllRemote()).toEqual({ mac: localPeersA });
      expect(remoteB.getRemotePeers("mac")).toEqual(localPeersA);
      expect(remoteB.listRemotePeers()).toEqual(
        localPeersA.map((address) => `mac:${address}`),
      );
      expect(remoteB.listRemotePeerInfos()).toEqual(
        localPeersA.map((address) => ({
          pc: "mac",
          cwd: "",
          name: address,
          address: `mac:${address}`,
        })),
      );

      const modes = [
        {
          direction: "A→B" as const,
          senderRemote: remoteA,
          receiverRemote: remoteB,
          senderBroker: brokerA,
          receiverBroker: brokerB,
          senderLocal: localPeersA[0]!,
          receiverLocal: localPeersB[0]!,
          senderWireAlias: "Mac",
          receiverWireAlias: "Captiva-RTX-4090",
          receiverAliasAtSender: "RTX4090",
          senderAliasAtReceiver: "mac",
          authenticatedSender: KEY_A_URL,
          authenticatedReceiver: KEY_B_URL,
        },
        {
          direction: "B→A" as const,
          senderRemote: remoteB,
          receiverRemote: remoteA,
          senderBroker: brokerB,
          receiverBroker: brokerA,
          senderLocal: localPeersB[1]!,
          receiverLocal: localPeersA[1]!,
          senderWireAlias: "Captiva-RTX-4090",
          receiverWireAlias: "Mac",
          receiverAliasAtSender: "mac",
          senderAliasAtReceiver: "RTX4090",
          authenticatedSender: KEY_B_URL,
          authenticatedReceiver: KEY_A_URL,
        },
      ];

      for (const mode of modes) {
        const messageBody = { type: "work", direction: mode.direction };
        const message = envelope(
          mode.senderLocal,
          `${mode.receiverAliasAtSender}:${mode.receiverLocal}`,
          messageBody,
        );
        expect(mode.senderRemote.tryRouteOutbound(message)).toBe(true);
        const messageDeliveries = link.pumpUntilQuiescent();
        const messageOnWire = messageDeliveries.find(
          (delivery) => delivery.env.id === message.id,
        );
        expect(messageOnWire).toMatchObject({
          direction: mode.direction,
          authenticatedFromPc: mode.authenticatedSender,
          env: {
            from: `${mode.senderWireAlias}:${mode.senderLocal}`,
            to: `${mode.receiverAliasAtSender}:${mode.receiverLocal}`,
            id: message.id,
            re: null,
            body: messageBody,
          },
        });
        expect(mode.senderWireAlias).not.toBe(mode.senderAliasAtReceiver);
        expect(mode.receiverAliasAtSender).not.toBe(mode.receiverWireAlias);

        const receivedMessage = mode.receiverBroker.injected.find(
          (candidate) => candidate.id === message.id,
        );
        expect(receivedMessage).toEqual({
          ...message,
          from: `${mode.senderAliasAtReceiver}:${mode.senderLocal}`,
          to: mode.receiverLocal,
        });
        const messageAck = mode.senderBroker.injected.find(
          (candidate) =>
            candidate.re === message.id &&
            (candidate.body as { type?: string } | null)?.type === "ack",
        );
        expect(messageAck).toMatchObject({
          from: `${mode.receiverAliasAtSender}:broker`,
          to: mode.senderLocal,
          re: message.id,
          body: {
            type: "ack",
            status: "received",
            target: mode.receiverLocal,
          },
        });

        const replyBody = { type: "reply", direction: mode.direction };
        const reply = envelope(
          mode.receiverLocal,
          `${mode.senderAliasAtReceiver}:${mode.senderLocal}`,
          replyBody,
          message.id,
        );
        expect(mode.receiverRemote.tryRouteOutbound(reply)).toBe(true);
        const replyDeliveries = link.pumpUntilQuiescent();
        const reverseDirection = mode.direction === "A→B" ? "B→A" : "A→B";
        const replyOnWire = replyDeliveries.find(
          (delivery) => delivery.env.id === reply.id,
        );
        expect(replyOnWire).toMatchObject({
          direction: reverseDirection,
          authenticatedFromPc: mode.authenticatedReceiver,
          env: {
            from: `${mode.receiverWireAlias}:${mode.receiverLocal}`,
            to: `${mode.senderAliasAtReceiver}:${mode.senderLocal}`,
            id: reply.id,
            re: message.id,
            body: replyBody,
          },
        });

        const receivedReply = mode.senderBroker.injected.find(
          (candidate) => candidate.id === reply.id,
        );
        expect(receivedReply).toEqual({
          ...reply,
          from: `${mode.receiverAliasAtSender}:${mode.receiverLocal}`,
          to: mode.senderLocal,
        });
        const replyAck = mode.receiverBroker.injected.find(
          (candidate) =>
            candidate.re === reply.id &&
            (candidate.body as { type?: string } | null)?.type === "ack",
        );
        expect(replyAck).toMatchObject({
          from: `${mode.senderAliasAtReceiver}:broker`,
          to: mode.receiverLocal,
          re: reply.id,
          body: {
            type: "ack",
            status: "received",
            target: mode.senderLocal,
          },
        });
      }

      expect(KEY_A_URL).not.toBe(KEY_A);
      expect(KEY_B_URL).not.toBe(KEY_B);
      expect(piA.sent).toEqual([]);
      expect(piB.sent).toEqual([]);
    } finally {
      remoteA.detach();
      remoteB.detach();
    }
  });
});
