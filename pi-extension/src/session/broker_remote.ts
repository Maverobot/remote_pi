import type {
  Broker,
  PeerInfo,
  RemoteInjectStatus,
  RemoteRouter,
} from "./broker.js";
import {
  asTransportErrorBody,
  type Envelope,
  envelope,
  isUuid,
  uuidv7,
} from "./envelope.js";
import type { PiForwardClient } from "../transport/pi_forward_client.js";
import {
  canonicalizeEd25519PublicKey,
  decodeEd25519PublicKey,
  encodeEd25519PublicKey,
  publicKeyFingerprint,
} from "../mesh/encoding.js";
import type {
  MeshTopologySnapshot,
  PiRoutingIdentity,
} from "../mesh/siblings.js";

const CACHE_TTL_MS = 5 * 60_000;
const PEERS_REQUEST_TIMEOUT_MS = 2_000;
const REANNOUNCE_INTERVAL_MS = 2 * 60_000;
const BROKER_NAME = "broker";

export interface WirePeerInfo {
  cwd: string;
  name: string;
  address: string;
}

export interface RemotePeerEntry {
  infos: WirePeerInfo[];
  pcPubkey: string;
  ts: number;
}

export interface BrokerRemoteOptions {
  broker: Broker;
  pi: PiForwardClient;
  topology: MeshTopologySnapshot;
  cacheTtlMs?: number;
  reannounceIntervalMs?: number;
  log?: (msg: string) => void;
  /** Defaults true for compatibility; Task 6 bridge construction passes false. */
  activateOnConstruct?: boolean;
}

export interface BrokerRemoteLifecycle {
  activate(): void;
  setTopology(next: MeshTopologySnapshot): void;
}

interface RoutingState {
  readonly self: PiRoutingIdentity;
  readonly siblingByLabel: ReadonlyMap<string, string>;
  /** Canonical standard-padded pubkey → receiver-local alias. */
  readonly siblingByPubkey: ReadonlyMap<string, string>;
}

interface PeersUpdateBody {
  type: "peers_update";
  peers: string[];
  peers_detailed?: WirePeerInfo[];
}

interface PeersRequestBody {
  type: "peers_request";
}

interface AckBody {
  type: "ack";
  status: RemoteInjectStatus;
  target: string;
}

interface PendingFill {
  resolve: () => void;
  timer: ReturnType<typeof setTimeout>;
}

type LifecycleState = "dormant" | "active" | "detached";
type DropReason =
  | "invalid_from_pc"
  | "unknown_from_pc"
  | "invalid_to"
  | "invalid_cross_pc_address"
  | "invalid_relay_error";

function compareAscii(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function validateAlias(alias: unknown, field: string): string {
  if (
    typeof alias !== "string" ||
    alias.length === 0 ||
    alias.includes(":")
  ) {
    throw new Error(`mesh: ${field} is not a valid routing alias`);
  }
  return alias;
}

function buildRoutingState(
  topology: MeshTopologySnapshot,
  expectedSelfPubkey?: string,
): RoutingState {
  const selfLabel = validateAlias(topology.self?.pcLabel, "self.pcLabel");
  const selfPubkey = canonicalizeEd25519PublicKey(
    topology.self?.pcPubkey,
    "self public key",
  );
  if (expectedSelfPubkey && selfPubkey !== expectedSelfPubkey) {
    throw new Error("mesh: self public key cannot change");
  }

  const normalizedSiblings = topology.siblings
    .map((sibling, index) => ({
      pcLabel: validateAlias(
        sibling?.pcLabel,
        `siblings[${index}].pcLabel`,
      ),
      pcPubkey: canonicalizeEd25519PublicKey(
        sibling?.pcPubkey,
        `siblings[${index}].pcPubkey`,
      ),
    }))
    .filter((sibling) => sibling.pcPubkey !== selfPubkey)
    .sort((left, right) => compareAscii(left.pcPubkey, right.pcPubkey));

  const siblingByLabel = new Map<string, string>();
  const siblingByPubkey = new Map<string, string>();
  for (const sibling of normalizedSiblings) {
    if (sibling.pcLabel === selfLabel) {
      throw new Error("mesh: sibling routing alias conflicts with self");
    }
    if (siblingByPubkey.has(sibling.pcPubkey)) {
      throw new Error("mesh: duplicate sibling public key");
    }
    if (siblingByLabel.has(sibling.pcLabel)) {
      throw new Error("mesh: duplicate sibling routing alias");
    }
    siblingByLabel.set(sibling.pcLabel, sibling.pcPubkey);
    siblingByPubkey.set(sibling.pcPubkey, sibling.pcLabel);
  }

  return {
    self: Object.freeze({
      pcLabel: selfLabel,
      pcPubkey: selfPubkey,
    }),
    siblingByLabel,
    siblingByPubkey,
  };
}

export class BrokerRemote implements RemoteRouter, BrokerRemoteLifecycle {
  private readonly broker: Broker;
  private readonly pi: PiForwardClient;
  private readonly technicalSelfPubkey: string;
  private readonly cacheTtlMs: number;
  private readonly reannounceIntervalMs: number;
  private readonly log: (msg: string) => void;
  private routing: RoutingState;

  /** Canonical sibling pubkey → cached local roster. */
  private readonly remotePeers = new Map<string, RemotePeerEntry>();
  /** Canonical sibling pubkeys whose active topology refresh must be retried. */
  private readonly topologyRefreshNeeded = new Set<string>();
  /** Canonical sibling pubkey → in-flight roster fills. */
  private readonly pendingFills = new Map<string, Set<PendingFill>>();

  private readonly onIncoming: (env: Envelope, fromPc: string) => void;
  private reannounceTimer: ReturnType<typeof setInterval> | null = null;
  private lifecycle: LifecycleState = "dormant";

  constructor(opts: BrokerRemoteOptions) {
    this.broker = opts.broker;
    this.pi = opts.pi;
    this.routing = buildRoutingState(opts.topology);
    this.technicalSelfPubkey = this.routing.self.pcPubkey;
    this.cacheTtlMs = opts.cacheTtlMs ?? CACHE_TTL_MS;
    this.reannounceIntervalMs =
      opts.reannounceIntervalMs ?? REANNOUNCE_INTERVAL_MS;
    this.log = opts.log ?? ((message) => console.error(message));
    this.onIncoming = (env, fromPc) => this.handleIncoming(env, fromPc);

    if (opts.activateOnConstruct !== false) this.activate();
  }

  activate(): void {
    if (this.lifecycle === "active") return;
    if (this.lifecycle === "detached") {
      throw new Error("mesh: BrokerRemote is detached");
    }

    try {
      this.pi.on("envelope", this.onIncoming);
      this.broker.setRemoteRouter(this);
      this._bootstrapWithSiblings();
      this.topologyRefreshNeeded.clear();
      if (this.reannounceIntervalMs > 0) {
        this.reannounceTimer = setInterval(() => {
          if (
            this.lifecycle !== "active" ||
            this.routing.siblingByPubkey.size === 0
          ) {
            return;
          }
          try {
            this._bootstrapWithSiblings();
            this.topologyRefreshNeeded.clear();
          } catch {
            this._logMetadataOnly(
              "[broker_remote] event=reannounce_failed reason=send_failure",
            );
          }
        }, this.reannounceIntervalMs);
        this.reannounceTimer.unref?.();
      }
      this.lifecycle = "active";
    } catch (error) {
      if (this.reannounceTimer) {
        clearInterval(this.reannounceTimer);
        this.reannounceTimer = null;
      }
      try {
        this.pi.off("envelope", this.onIncoming);
      } catch {
        // best-effort rollback
      }
      try {
        this.broker.clearRemoteRouter(this);
      } catch {
        // preserve the activation error
      }
      this.lifecycle = "detached";
      throw error;
    }
  }

  detach(): void {
    if (this.lifecycle === "detached") return;
    const wasActive = this.lifecycle === "active";
    this.lifecycle = "detached";
    if (this.reannounceTimer) {
      clearInterval(this.reannounceTimer);
      this.reannounceTimer = null;
    }
    this._clearAllPendingFills();
    this.topologyRefreshNeeded.clear();
    if (!wasActive) return;
    this.pi.off("envelope", this.onIncoming);
    this.broker.clearRemoteRouter(this);
  }

  setTopology(next: MeshTopologySnapshot): void {
    if (this.lifecycle === "detached") {
      throw new Error("mesh: BrokerRemote is detached");
    }
    const previous = this.routing;
    const replacement = buildRoutingState(next, this.technicalSelfPubkey);

    for (const pcPubkey of [...this.remotePeers.keys()]) {
      if (!replacement.siblingByPubkey.has(pcPubkey)) {
        this.remotePeers.delete(pcPubkey);
      }
    }
    for (const pcPubkey of [...this.pendingFills.keys()]) {
      if (!replacement.siblingByPubkey.has(pcPubkey)) {
        this._clearPendingFills(pcPubkey);
      }
    }
    for (const pcPubkey of [...this.topologyRefreshNeeded]) {
      if (!replacement.siblingByPubkey.has(pcPubkey)) {
        this.topologyRefreshNeeded.delete(pcPubkey);
      }
    }
    this.routing = replacement;

    if (this.lifecycle !== "active") return;
    const refreshKeys = new Set(this.topologyRefreshNeeded);
    for (const [pcPubkey, alias] of replacement.siblingByPubkey) {
      if (previous.siblingByPubkey.get(pcPubkey) !== alias) {
        refreshKeys.add(pcPubkey);
      }
    }
    if (previous.self.pcLabel !== replacement.self.pcLabel) {
      for (const pcPubkey of replacement.siblingByPubkey.keys()) {
        refreshKeys.add(pcPubkey);
      }
    }
    if (refreshKeys.size === 0) return;

    let body: PeersUpdateBody;
    try {
      body = this._localPeersBody();
    } catch {
      for (const pcPubkey of refreshKeys) {
        this.topologyRefreshNeeded.add(pcPubkey);
      }
      this._logMetadataOnly(
        "[broker_remote] event=topology_refresh_failed reason=inventory_failure",
      );
      return;
    }
    for (const pcPubkey of refreshKeys) {
      let failed = false;
      try {
        this._sendControlEnvelope(pcPubkey, { type: "peers_request" });
      } catch {
        failed = true;
      }
      try {
        this._sendControlEnvelope(pcPubkey, body);
      } catch {
        failed = true;
      }
      if (failed) {
        this.topologyRefreshNeeded.add(pcPubkey);
        this._logMetadataOnly(
          "[broker_remote] event=topology_refresh_failed reason=send_failure",
        );
      } else {
        this.topologyRefreshNeeded.delete(pcPubkey);
      }
    }
  }

  private _bootstrapWithSiblings(): void {
    const body = this._localPeersBody();
    for (const pcPubkey of this.routing.siblingByPubkey.keys()) {
      this._sendControlEnvelope(pcPubkey, { type: "peers_request" });
      this._sendControlEnvelope(pcPubkey, body);
    }
  }

  private _localPeersBody(): PeersUpdateBody {
    const detailed = this.broker.localPeerInfos();
    return {
      type: "peers_update",
      peers: detailed.map((peer) => peer.address),
      peers_detailed: detailed.map((peer) => ({
        cwd: peer.cwd,
        name: peer.name,
        address: peer.address,
      })),
    };
  }

  private _remoteInfosByPubkey(pcPubkey: string): WirePeerInfo[] {
    const entry = this.remotePeers.get(pcPubkey);
    if (!entry) return [];
    if (Date.now() - entry.ts > this.cacheTtlMs) return [];
    return entry.infos;
  }

  getRemotePeers(pcLabel: string): string[] {
    const pcPubkey = this.routing.siblingByLabel.get(pcLabel);
    return pcPubkey
      ? this._remoteInfosByPubkey(pcPubkey).map((info) => info.address)
      : [];
  }

  getAllRemote(): Record<string, string[]> {
    const entries: Array<[string, string[]]> = [];
    for (const [pcPubkey, pcLabel] of this.routing.siblingByPubkey) {
      const peers = this._remoteInfosByPubkey(pcPubkey).map(
        (info) => info.address,
      );
      if (peers.length > 0) entries.push([pcLabel, peers]);
    }
    return Object.fromEntries(entries);
  }

  listRemotePeers(): string[] {
    const output: string[] = [];
    for (const [pcPubkey, pcLabel] of this.routing.siblingByPubkey) {
      for (const info of this._remoteInfosByPubkey(pcPubkey)) {
        output.push(`${pcLabel}:${info.address}`);
      }
    }
    return output;
  }

  listRemotePeerInfos(): PeerInfo[] {
    const output: PeerInfo[] = [];
    for (const [pcPubkey, pcLabel] of this.routing.siblingByPubkey) {
      for (const info of this._remoteInfosByPubkey(pcPubkey)) {
        output.push({
          pc: pcLabel,
          cwd: info.cwd,
          name: info.name,
          address: `${pcLabel}:${info.address}`,
        });
      }
    }
    return output;
  }

  onLocalPeersChanged(_peers: string[]): void {
    if (
      this.lifecycle !== "active" ||
      this.routing.siblingByPubkey.size === 0
    ) {
      return;
    }
    const body = this._localPeersBody();
    for (const pcPubkey of this.routing.siblingByPubkey.keys()) {
      this._sendControlEnvelope(pcPubkey, body);
    }
  }

  tryRouteOutbound(env: Envelope): boolean {
    if (this.lifecycle !== "active" || typeof env.to !== "string") {
      return false;
    }
    const parsed = parseAddress(env.to);
    if (!parsed) return false;
    const siblingKey = this.routing.siblingByLabel.get(parsed.pcLabel);
    if (siblingKey) return this._routeToCanonicalSibling(siblingKey, env);
    if (parsed.pcLabel === this.routing.self.pcLabel) return false;
    return false;
  }

  private _routeToCanonicalSibling(
    siblingKey: string,
    env: Envelope,
  ): boolean {
    const rewritten: Envelope = {
      ...env,
      from: `${this.routing.self.pcLabel}:${env.from}`,
    };
    this.pi.sendEnvelopeToPi(siblingKey, rewritten);
    if (!this.remotePeers.has(siblingKey)) {
      this._sendControlEnvelope(siblingKey, { type: "peers_request" });
      void this._awaitPeersFill(siblingKey, PEERS_REQUEST_TIMEOUT_MS);
    }
    return true;
  }

  handleIncoming(env: Envelope, fromPc: string): void {
    if (this.lifecycle !== "active") return;
    if (fromPc === "_relay") {
      this._propagateTransportError(env);
      return;
    }

    let canonicalFromPc: string;
    let fromPcBytes: Uint8Array;
    try {
      fromPcBytes = decodeEd25519PublicKey(fromPc, "from_pc");
      canonicalFromPc = encodeEd25519PublicKey(fromPcBytes);
    } catch {
      this._dropMetadataOnly("invalid_from_pc");
      return;
    }
    const localAlias = this.routing.siblingByPubkey.get(canonicalFromPc);
    if (!localAlias) {
      this._dropMetadataOnly(
        "unknown_from_pc",
        publicKeyFingerprint(fromPcBytes),
      );
      return;
    }
    if (typeof env.to !== "string") {
      this._dropMetadataOnly("invalid_to");
      return;
    }
    const senderLocalAddress = stripRequiredPcPrefix(env.from);
    const targetLocalAddress = stripRequiredPcPrefix(env.to);
    if (!senderLocalAddress || !targetLocalAddress) {
      this._dropMetadataOnly("invalid_cross_pc_address");
      return;
    }

    const normalized: Envelope = {
      ...env,
      from: `${localAlias}:${senderLocalAddress}`,
      to: targetLocalAddress,
    };
    const body = normalized.body as { type?: unknown } | null;
    const bodyType = body && typeof body === "object" ? body.type : undefined;

    if (bodyType === "peers_update") {
      this._setRemoteCache(
        canonicalFromPc,
        _parsePeersUpdate(body as PeersUpdateBody),
      );
      return;
    }
    if (bodyType === "peers_request") {
      this._sendControlEnvelope(canonicalFromPc, this._localPeersBody());
      return;
    }

    const status = this.broker.injectFromRemote(normalized);
    if (bodyType === "ack") return;

    const ackBody: AckBody = {
      type: "ack",
      status,
      target: normalized.to as string,
    };
    const ackEnv: Envelope = {
      from: `${this.routing.self.pcLabel}:${BROKER_NAME}`,
      to: normalized.from,
      id: uuidv7(),
      re: normalized.id,
      body: ackBody,
    };
    this.pi.sendEnvelopeToPi(canonicalFromPc, ackEnv);
  }

  private _setRemoteCache(
    pcPubkey: string,
    infos: WirePeerInfo[],
  ): void {
    this.remotePeers.set(pcPubkey, {
      infos,
      pcPubkey,
      ts: Date.now(),
    });
    this._clearPendingFills(pcPubkey);
  }

  private _awaitPeersFill(
    pcPubkey: string,
    timeoutMs: number,
  ): Promise<void> {
    return new Promise<void>((resolve) => {
      const slot: PendingFill = {
        resolve,
        timer: setTimeout(() => {
          const pending = this.pendingFills.get(pcPubkey);
          pending?.delete(slot);
          if (pending?.size === 0) this.pendingFills.delete(pcPubkey);
          resolve();
        }, timeoutMs),
      };
      const pending = this.pendingFills.get(pcPubkey) ?? new Set<PendingFill>();
      pending.add(slot);
      this.pendingFills.set(pcPubkey, pending);
    });
  }

  private _clearPendingFills(pcPubkey: string): void {
    const pending = this.pendingFills.get(pcPubkey);
    if (!pending) return;
    for (const slot of pending) {
      clearTimeout(slot.timer);
      slot.resolve();
    }
    this.pendingFills.delete(pcPubkey);
  }

  private _clearAllPendingFills(): void {
    for (const pcPubkey of [...this.pendingFills.keys()]) {
      this._clearPendingFills(pcPubkey);
    }
  }

  private _propagateTransportError(env: Envelope): void {
    const body = asTransportErrorBody(env.body);
    const target = typeof env.to === "string"
      ? stripRequiredPcPrefix(env.to)
      : null;
    if (
      env.from !== "_relay" ||
      !isUuid(env.id) ||
      !isUuid(env.re) ||
      !target ||
      target === "broadcast" ||
      !body
    ) {
      this._dropMetadataOnly("invalid_relay_error");
      return;
    }
    this.broker.injectFromRemote({
      ...env,
      from: BROKER_NAME,
      to: target,
      body,
    });
  }

  private _sendControlEnvelope(
    toPc: string,
    body: PeersUpdateBody | PeersRequestBody,
  ): void {
    const env: Envelope = envelope(
      `${this.routing.self.pcLabel}:_broker_remote`,
      `${this._labelForPubkey(toPc) ?? "?"}:_broker_remote`,
      body,
      null,
    );
    this.pi.sendEnvelopeToPi(toPc, env);
  }

  private _labelForPubkey(pcPubkey: string): string | undefined {
    return this.routing.siblingByPubkey.get(pcPubkey);
  }

  private _dropMetadataOnly(
    reason: DropReason,
    fingerprint?: string,
  ): void {
    this._logMetadataOnly(
      `[broker_remote] event=drop reason=${reason}` +
        (fingerprint ? ` fingerprint=${fingerprint}` : ""),
    );
  }

  private _logMetadataOnly(message: string): void {
    try {
      this.log(message);
    } catch {
      // Diagnostics are best-effort and must not break routing or timers.
    }
  }
}

export function parseAddress(
  to: string,
): { pcLabel: string; peerName: string } | null {
  const separator = to.indexOf(":");
  if (separator <= 0 || separator === to.length - 1) return null;
  return {
    pcLabel: to.slice(0, separator),
    peerName: to.slice(separator + 1),
  };
}

function stripRequiredPcPrefix(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const separator = value.indexOf(":");
  if (separator <= 0 || separator === value.length - 1) return null;
  return value.slice(separator + 1);
}

function _parsePeersUpdate(body: PeersUpdateBody): WirePeerInfo[] {
  const detailed = body.peers_detailed;
  if (Array.isArray(detailed)) {
    return detailed.filter(
      (entry): entry is WirePeerInfo =>
        !!entry &&
        typeof entry === "object" &&
        typeof (entry as WirePeerInfo).cwd === "string" &&
        typeof (entry as WirePeerInfo).name === "string" &&
        typeof (entry as WirePeerInfo).address === "string",
    );
  }
  const peers = Array.isArray(body.peers) ? body.peers : [];
  return peers
    .filter((peer): peer is string => typeof peer === "string")
    .map((address) => ({ cwd: "", name: address, address }));
}
