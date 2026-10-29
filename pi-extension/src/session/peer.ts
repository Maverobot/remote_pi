import type { Socket } from "node:net";
import { setTimeout as delay } from "node:timers/promises";
import {
  type Envelope,
  type TransportErrorReason,
  asTransportErrorBody,
  envelope,
  hasTransportErrorType,
  parse,
  serialize,
  EnvelopeError,
} from "./envelope.js";
import { joinOrLead, type ElectionResult } from "./leader_election.js";
import { Broker } from "./broker.js";

/**
 * Symmetric peer-in-session API. Hides whether you are leader or follower;
 * `send`, `request`, `onMessage`, `rename`, `leave` all work the same.
 *
 * Pending map demuxes parallel `request()` calls by message `id` → `re`.
 *
 * Failover: when the leader dies, follower socket emits `close`. Remaining
 * peers re-run `joinOrLead`. One becomes the new leader; others reconnect.
 */
export type MessageHandler = (env: Envelope) => void;
export type ReconnectHandler = () => void;

/** A lock-backed peer cannot use a different automatic registration identity. */
export class ReconnectNameConflictError extends Error {
  constructor(readonly expectedName: string, readonly assignedName: string) {
    super(`broker assigned "${assignedName}" instead of reserved name "${expectedName}"`);
    this.name = "ReconnectNameConflictError";
  }
}

export interface SessionPeerOptions {
  sockPath: string;
  name: string;
  /**
   * Working directory of this agent. Sent in the `register` so the broker can
   * key peers by the (cwd, name) pair: two agents in the SAME folder with the
   * same name are the SAME logical agent reincarnating (switch_session /
   * restart), so the broker take-over the name instead of suffixing `#N`.
   * Optional for backward-compat with peers that predate this field.
   */
  cwd?: string;
  /** Replace an existing same-(cwd,name) registration instead of accepting a
   *  broker-assigned `#N`. Use only for stable logical identities; ordinary
   *  multi-agent sessions should leave this false. */
  takeoverExisting?: boolean;
  auditPath?: string;
  /** Per-request default timeout (ms). Override per call if needed. */
  defaultTimeoutMs?: number;
}

const DEFAULT_TIMEOUT_MS = 30_000;
const ACK_TIMEOUT_MS = 5_000;
const FAILOVER_RETRY_MS = 100;

export type AckStatus = "received" | "busy" | "denied" | "timeout";

export interface AckResult {
  status: AckStatus;
  /** The original envelope id that was awaiting ACK. */
  id: string;
  /** Target name reported by broker (when ACK arrived). Undefined on timeout. */
  target?: string;
  error?: `transport_error: ${TransportErrorReason}`;
  reason?: TransportErrorReason;
}

export class MeshTransportError extends Error {
  constructor(
    readonly reason: TransportErrorReason,
    readonly correlationId: string,
  ) {
    super(`transport_error: ${reason}`);
    this.name = "MeshTransportError";
  }
}

interface AckBody {
  type: "ack";
  status: "received" | "busy" | "denied";
  target: string;
}

function hasExactAckType(body: unknown): body is { type: "ack" } {
  return typeof body === "object"
    && body !== null
    && Object.prototype.hasOwnProperty.call(body, "type")
    && (body as { type: unknown }).type === "ack";
}

function expectedAckSender(destination: string): string {
  // Local absolute paths may contain colons; only non-path aliases are remote.
  if (
    destination === "" ||
    !destination.includes(":") ||
    destination.startsWith("/") ||
    /^[A-Za-z]:[\\/]/.test(destination) ||
    destination.startsWith("\\\\")
  ) {
    return "broker";
  }
  const remote = /^([^:]+):.+$/.exec(destination);
  return remote ? `${remote[1]}:broker` : "broker";
}

function asAckBody(body: unknown): AckBody | null {
  if (!hasExactAckType(body)
    || !Object.prototype.hasOwnProperty.call(body, "status")
    || !Object.prototype.hasOwnProperty.call(body, "target")) {
    return null;
  }

  const { status, target } = body as {
    type: "ack";
    status: unknown;
    target: unknown;
  };
  if ((status !== "received" && status !== "busy" && status !== "denied")
    || typeof target !== "string") {
    return null;
  }

  return { type: "ack", status, target };
}

export class SessionPeer {
  private readonly opts: SessionPeerOptions;
  /** Clean leaf name actually assigned by the broker (may carry a `#N`
   *  collision suffix). Used for display + self-filtering. */
  private assignedName: string;
  /** Canonical address assigned by the broker (`[<pc>:]<cwd>@<nome>`, or just
   *  the name for a legacy broker). This is the routing/identity key the mesh
   *  uses; callers ECHO it, never compose it. */
  private assignedAddress: string;
  private role: "leader" | "follower" = "follower";
  private broker: Broker | null = null;
  private socket: Socket | null = null;
  private buf = "";
  /** Map of in-flight request ids → resolver. Used by `request()`. */
  private readonly pending = new Map<string, {
    resolve: (env: Envelope) => void;
    reject: (err: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }>();
  /** Map of in-flight send ids → ACK resolver. Used by `sendWithAck()`. */
  private readonly ackPending = new Map<string, {
    expectedFrom: string;
    resolve: (result: AckResult) => void;
    timer: ReturnType<typeof setTimeout>;
  }>();
  private readonly handlers = new Set<MessageHandler>();
  private readonly reconnectHandlers = new Set<ReconnectHandler>();
  private leftFlag = false;
  private ready = false;
  private pinnedName: string | null = null;
  private connectionGeneration = 0;
  private connectionAttempt: Promise<string> | null = null;
  private rejectRegistration: ((error: Error) => void) | null = null;
  private readonly reconnectRejectedHandlers = new Set<(error: ReconnectNameConflictError) => void>();

  constructor(opts: SessionPeerOptions) {
    this.opts = opts;
    this.assignedName = opts.name;
    this.assignedAddress = opts.name;
  }

  // ── public API ────────────────────────────────────────────────────────────

  /** Joins or leads the session at `sockPath`. Resolves with the assigned name. */
  async start(): Promise<string> {
    return this._joinOrLead();
  }

  /** Returns the clean leaf name as assigned by the broker (after any `#N`). */
  name(): string {
    return this.assignedName;
  }

  /** Keep future registrations on the effective identity the caller now owns. */
  pinAssignedName(): void {
    this.opts.name = this.assignedName;
    this.pinnedName = this.assignedName;
  }

  isConnected(): boolean {
    return this.ready && !this.leftFlag && this.socket !== null && !this.socket.destroyed;
  }

  /** Failure-only signal, after attempt cleanup; handlers may safely close us. */
  onReconnectRejected(handler: (error: ReconnectNameConflictError) => void): () => void {
    this.reconnectRejectedHandlers.add(handler);
    return () => this.reconnectRejectedHandlers.delete(handler);
  }

  /** Returns the canonical address (`[<pc>:]<cwd>@<nome>`) assigned by the
   *  broker — the key the mesh routes on. Equals `name()` against a legacy
   *  broker that returns no address. */
  address(): string {
    return this.assignedAddress;
  }

  /** Returns "leader" or "follower" — current role. */
  currentRole(): "leader" | "follower" {
    return this.role;
  }

  /** Returns the locally-hosted Broker when this peer is the leader, or
   *  null when it's a follower. Wave 25C uses this to attach the
   *  cross-PC router. */
  localBroker(): Broker | null {
    return this.broker;
  }

  /**
   * Fire-and-forget send. Doesn't await a reply.
   *
   * `re` (optional) lets the caller correlate this message as a reply to a
   * previous request — when an LLM peer is *answering* a question from
   * another agent, it must echo the original `id` here so the requester's
   * pending map can resolve. Without `re`, the requester treats this as a
   * new unsolicited message and its `request()` call times out.
   */
  async send(
    to: string | string[],
    body: unknown,
    re: string | null = null,
  ): Promise<void> {
    const env = envelope(this.assignedName, to, body, re);
    await this._writeEnvelope(env);
  }

  /**
   * Unicast send + await broker ACK. Returns the ACK status:
   *   - `received` — peer was idle, envelope delivered, will be processed soon
   *   - `busy`     — peer mid-turn, envelope dropped; sender is owner of retry
   *   - `denied`   — broker/Relay refused delivery (including authorization or envelope failure)
   *   - `timeout`  — no ACK within `timeoutMs`, or trusted Relay says offline
   *
   * Only meaningful for unicast non-broadcast addresses. The peer's body-level
   * reply (if any) is asynchronous and arrives as a normal inbound envelope
   * carrying `re=<this-send-id>` in a future turn — handled by `onMessage`.
   */
  async sendWithAck(
    to: string,
    body: unknown,
    re: string | null = null,
    timeoutMs: number = ACK_TIMEOUT_MS,
  ): Promise<AckResult> {
    const env = envelope(this.assignedName, to, body, re);
    return new Promise<AckResult>((resolve) => {
      const timer = setTimeout(() => {
        this.ackPending.delete(env.id);
        resolve({ status: "timeout", id: env.id });
      }, timeoutMs);
      this.ackPending.set(env.id, {
        expectedFrom: expectedAckSender(to),
        resolve,
        timer,
      });
      this._writeEnvelope(env).catch(() => {
        const slot = this.ackPending.get(env.id);
        if (!slot) return;
        clearTimeout(slot.timer);
        this.ackPending.delete(env.id);
        resolve({ status: "timeout", id: env.id });
      });
    });
  }

  /**
   * Send + await reply. Resolves with the first inbound envelope whose `re`
   * matches the outbound `id`. Rejects on timeout, teardown/write failure, or
   * a trusted Relay transport error.
   */
  async request(
    to: string,
    body: unknown,
    timeoutMs: number = this.opts.defaultTimeoutMs ?? DEFAULT_TIMEOUT_MS,
  ): Promise<Envelope> {
    const env = envelope(this.assignedName, to, body, null);
    return new Promise<Envelope>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(env.id);
        reject(new Error(`request to ${to} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this.pending.set(env.id, { resolve, reject, timer });
      this._writeEnvelope(env).catch((err) => {
        const slot = this.pending.get(env.id);
        if (!slot) return;
        clearTimeout(slot.timer);
        this.pending.delete(env.id);
        reject(err);
      });
    });
  }

  onMessage(handler: MessageHandler): () => void {
    this.handlers.add(handler);
    return () => this.handlers.delete(handler);
  }

  /**
   * Fires after the peer successfully (re)joins following a failover —
   * leader died and we re-elected. NOT called for the initial `start()`,
   * only for post-drop reconnects. Consumers use this to re-query state
   * the broker may have lost in the transition (e.g., peer list).
   */
  onReconnect(handler: ReconnectHandler): () => void {
    this.reconnectHandlers.add(handler);
    return () => this.reconnectHandlers.delete(handler);
  }

  /**
   * Requests a different display name from the broker. Returns the name
   * actually assigned (may carry a #N suffix on collision). Implemented as
   * a soft rejoin: leaves & rejoins with the new name.
   */
  async rename(newName: string): Promise<string> {
    await this._cancelConnectionAttempt();
    if (this.leftFlag) throw new Error("peer left");
    this.opts.name = newName;
    return this._joinOrLead();
  }

  async leave(): Promise<void> {
    this.leftFlag = true;
    await this._cancelConnectionAttempt();
  }

  private async _cancelConnectionAttempt(): Promise<void> {
    this.connectionGeneration += 1;
    const attempt = this.connectionAttempt;
    // Reject registration synchronously before draining its connection attempt.
    const closing = this._teardownConn();
    try { await attempt; } catch { /* canceled/failed attempts still drain */ }
    await closing;
  }

  // Track only connection-producing work, never consumer callbacks. Otherwise a
  // rejection handler that calls leave() would await its own notification.
  private _joinOrLead(): Promise<string> {
    if (this.leftFlag) return Promise.reject(new Error("peer left"));
    if (this.connectionAttempt) return this.connectionAttempt;
    const generation = ++this.connectionGeneration;
    const attempt = this._connectOnce(generation)
      .catch(async (error: unknown) => {
        if (generation === this.connectionGeneration) await this._teardownConn();
        throw error;
      })
      .finally(() => {
        if (this.connectionAttempt === attempt) this.connectionAttempt = null;
      });
    this.connectionAttempt = attempt;
    return attempt;
  }

  private _canConnect(generation: number): boolean {
    return !this.leftFlag && generation === this.connectionGeneration;
  }

  private async _connectOnce(generation: number): Promise<string> {
    const result: ElectionResult = await joinOrLead(this.opts.sockPath);
    if (!this._canConnect(generation)) {
      if (result.role === "follower") result.socket.destroy();
      else await new Promise<void>((resolve) => result.server.close(() => resolve()));
      throw new Error("peer connection canceled");
    }
    this.role = result.role;
    if (result.role === "leader") {
      this.broker = new Broker({ server: result.server, auditPath: this.opts.auditPath });
      return this._registerAsClient(generation);
    }
    this._wireSocket(result.socket);
    return this._registerOver(result.socket);
  }

  private async _registerAsClient(generation: number): Promise<string> {
    const { createConnection } = await import("node:net");
    if (!this._canConnect(generation)) throw new Error("peer connection canceled");
    const sock = createConnection(this.opts.sockPath);
    // Own even a connecting loopback socket so leave() can destroy it.
    this._wireSocket(sock);
    await new Promise<void>((resolve, reject) => {
      const cleanup = () => {
        sock.off("connect", connected);
        sock.off("error", failed);
        sock.off("close", closed);
      };
      const connected = () => { cleanup(); resolve(); };
      const failed = (error: Error) => { cleanup(); reject(error); };
      const closed = () => failed(new Error("peer connection closed"));
      sock.once("connect", connected);
      sock.once("error", failed);
      sock.once("close", closed);
    });
    if (!this._canConnect(generation)) {
      sock.destroy();
      throw new Error("peer connection canceled");
    }
    return this._registerOver(sock);
  }

  private _wireSocket(sock: Socket): void {
    this.socket = sock;
    this.ready = false;
    this.buf = "";
    sock.setEncoding("utf8");
    sock.on("data", (chunk: string) => this._onData(sock, chunk));
    sock.on("close", () => { void this._onSocketClose(sock); });
    sock.on("error", () => { /* close will follow */ });
  }

  private _registerOver(sock: Socket): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      const clearWaiter = () => {
        clearTimeout(wait);
        if (this._preAckListener === receiveAck) this._preAckListener = null;
        if (this.rejectRegistration === fail) this.rejectRegistration = null;
      };
      const fail = (error: Error) => {
        clearWaiter();
        reject(error);
      };
      const wait = setTimeout(() => fail(new Error("register_ack timeout")), 5_000);
      const receiveAck = (raw: unknown) => {
        const ack = raw as { type?: string; name_assigned?: string; address_assigned?: string };
        const name = typeof ack?.name_assigned === "string" ? ack.name_assigned : ack?.address_assigned;
        const address = typeof ack?.address_assigned === "string" ? ack.address_assigned : ack?.name_assigned;
        if (!ack || ack.type !== "register_ack" || typeof name !== "string" || typeof address !== "string") {
          fail(new Error(`expected register_ack, got: ${JSON.stringify(raw)}`));
          return;
        }
        if (this.leftFlag || this.socket !== sock) {
          fail(new Error("peer registration canceled"));
          return;
        }
        // Synchronous acceptance precedes identity publication and any following
        // envelope in the SAME data chunk. No async lock-transfer hook here.
        if (this.pinnedName !== null && name !== this.pinnedName) {
          fail(new ReconnectNameConflictError(this.pinnedName, name));
          return;
        }
        clearWaiter();
        this.assignedName = name;
        this.assignedAddress = address;
        this.ready = true;
        resolve(name);
      };
      this._preAckListener = receiveAck;
      this.rejectRegistration = fail;
      const req = JSON.stringify({
        type: "register",
        name: this.opts.name,
        ...(this.opts.cwd !== undefined ? { cwd: this.opts.cwd } : {}),
        ...(this.opts.takeoverExisting === true ? { takeover: true } : {}),
      }) + "\n";
      try { sock.write(req); } catch (error) {
        fail(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  private _preAckListener: ((raw: unknown) => void) | null = null;

  private _onData(sock: Socket, chunk: string): void {
    if (this.socket !== sock || this.leftFlag) return;
    this.buf += chunk;
    let nl: number;
    while ((nl = this.buf.indexOf("\n")) >= 0) {
      if (this.socket !== sock || (!this.ready && !this._preAckListener)) {
        this.buf = "";
        return;
      }
      const line = this.buf.slice(0, nl);
      this.buf = this.buf.slice(nl + 1);
      if (line) this._handleLine(line);
    }
  }

  private _handleLine(line: string): void {
    // Before register_ack: parse loosely as an ack control message.
    if (this._preAckListener) {
      try {
        const parsed = JSON.parse(line) as unknown;
        this._preAckListener(parsed);
      } catch {
        // Garbage during register window — ignore.
      }
      return;
    }

    // Regular envelope.
    let env: Envelope;
    try {
      env = parse(line);
    } catch (e) {
      if (e instanceof EnvelopeError) return;
      throw e;
    }

    // Reserve every raw transport_error body before either pending map can
    // correlate it. Only exact broker provenance plus a valid body may settle;
    // forged or invalid reserved frames remain ordinary handler messages.
    if (hasTransportErrorType(env.body)) {
      const trusted = env.from === "broker" && env.re !== null
        ? asTransportErrorBody(env.body)
        : null;
      if (trusted && env.re !== null) {
        this._consumeAckTransportError(env.re, trusted.reason);
        this._rejectRequestTransportError(env.re, trusted.reason);
        return;
      }
      this._dispatchToHandlers(env);
      return;
    }

    // Reserve exact broker ACKs before generic correlation or handler dispatch.
    // The sender is bound when the send begins: local sends accept only
    // `broker`, while remote alias sends accept only `<alias>:broker`.
    const fromBroker = env.from === "broker" || env.from.endsWith(":broker");
    if (fromBroker && hasExactAckType(env.body)) {
      const ackBody = asAckBody(env.body);
      if (env.re !== null && ackBody) {
        const slot = this.ackPending.get(env.re);
        if (slot && slot.expectedFrom === env.from) {
          clearTimeout(slot.timer);
          this.ackPending.delete(env.re);
          slot.resolve({ status: ackBody.status, id: env.re, target: ackBody.target });
        }
      }
      return;
    }

    // Correlate replies for `request()`.
    if (env.re) {
      const slot = this.pending.get(env.re);
      if (slot) {
        clearTimeout(slot.timer);
        this.pending.delete(env.re);
        slot.resolve(env);
        return;
      }
    }

    // Otherwise dispatch to subscribers.
    this._dispatchToHandlers(env);
  }

  private _consumeAckTransportError(
    correlationId: string,
    reason: TransportErrorReason,
  ): void {
    const pendingId = correlationId.toLowerCase();
    const slot = this.ackPending.get(pendingId);
    if (!slot) return;
    clearTimeout(slot.timer);
    this.ackPending.delete(pendingId);
    slot.resolve({
      status: reason === "offline" ? "timeout" : "denied",
      id: pendingId,
      error: `transport_error: ${reason}`,
      reason,
    });
  }

  private _rejectRequestTransportError(
    correlationId: string,
    reason: TransportErrorReason,
  ): void {
    const pendingId = correlationId.toLowerCase();
    const slot = this.pending.get(pendingId);
    if (!slot) return;
    clearTimeout(slot.timer);
    this.pending.delete(pendingId);
    slot.reject(new MeshTransportError(reason, pendingId));
  }

  private _dispatchToHandlers(env: Envelope): void {
    for (const h of this.handlers) {
      try { h(env); } catch { /* handler errors don't break peer */ }
    }
  }

  private async _writeEnvelope(env: Envelope): Promise<void> {
    if (!this.socket || this.socket.destroyed || this.leftFlag || (this.pinnedName !== null && !this.ready)) {
      throw new Error("session peer not connected");
    }
    this.socket.write(serialize(env));
  }

  private async _onSocketClose(closedSock: Socket): Promise<void> {
    if (this.socket !== closedSock) return;
    const wasReady = this.ready;
    this.ready = false;
    this.rejectRegistration?.(new Error("peer registration connection closed"));
    if (this.leftFlag || !wasReady) return;
    await delay(FAILOVER_RETRY_MS);
    if (this.leftFlag || this.socket !== closedSock) return;
    try {
      await this._joinOrLead();
      if (!this.isConnected()) return;
      for (const handler of this.reconnectHandlers) {
        try { handler(); } catch { /* handler errors don't break peer */ }
      }
    } catch (error) {
      // The tracked attempt (including resource cleanup) has already settled.
      // A consumer may now close/leave without a self-await cycle.
      if (!this.leftFlag && error instanceof ReconnectNameConflictError) {
        for (const handler of this.reconnectRejectedHandlers) {
          try { handler(error); } catch { /* handler errors don't break peer */ }
        }
      }
    }
  }

  private async _teardownConn(): Promise<void> {
    this.ready = false;
    this.rejectRegistration?.(new Error("peer leaving"));
    for (const [id, slot] of this.pending) {
      clearTimeout(slot.timer);
      this.pending.delete(id);
      slot.reject(new Error("peer leaving"));
    }
    for (const [id, slot] of this.ackPending) {
      clearTimeout(slot.timer);
      this.ackPending.delete(id);
      slot.resolve({ status: "timeout", id });
    }

    if (this.socket) {
      try { this.socket.destroy(); } catch { /* ignored */ }
      this.socket = null;
    }
    const broker = this.broker;
    this.broker = null;
    if (broker) {
      try { await broker.close(); } catch { /* ignored */ }
    }
  }
}
