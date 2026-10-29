import { Server, Socket, createServer } from "node:net";
import { existsSync, lstatSync, unlinkSync } from "node:fs";
import { setTimeout as delay } from "node:timers/promises";
import { usesNamedPipe } from "./ipc.js";

const MAX_ATTEMPTS = 20;
const BASE_BACKOFF_MS = 30;
const JITTER_MS = 70;
const PROBE_TIMEOUT_MS = 500;
const MIN_RECLAIM_AGE_NS = 2_000_000_000n;

export type ElectionResult =
  | { role: "leader"; server: Server }
  | { role: "follower"; socket: Socket };

export interface SocketIdentity {
  dev: bigint;
  ino: bigint;
  ctimeNs: bigint;
  birthtimeNs: bigint;
}

export type SocketProbe =
  | { status: "live"; socket: Socket }
  | { status: "gone"; identity: SocketIdentity | null; probedAtNs: bigint }
  | { status: "unknown" };

/**
 * UDS-based leader election. Connect to a live broker, or reclaim a verified
 * crash-leftover socket and bind. Ambiguous probes and lost bind races retry
 * with bounded jittered backoff; neither proves that a socket is stale.
 */
export async function joinOrLead(sockPath: string): Promise<ElectionResult> {
  const pipe = usesNamedPipe();
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    // Named pipes have no file to check or unlink; always probe first.
    if (pipe || existsSync(sockPath)) {
      const probe = await probeSocketForReclaim(sockPath);
      if (probe.status === "live") return { role: "follower", socket: probe.socket };
      if (probe.status === "unknown") {
        await delay(BASE_BACKOFF_MS + Math.random() * JITTER_MS);
        continue;
      }
      removeStaleSock(sockPath, probe);
    }

    const server = await _tryBind(sockPath);
    if (server) return { role: "leader", server };

    await delay(BASE_BACKOFF_MS + Math.random() * JITTER_MS);
  }
  throw new Error(`leader election failed after ${MAX_ATTEMPTS} attempts: existing broker socket could not be verified or acquired: ${sockPath}`);
}

/** Liveness-only compatibility helper. A null result is NOT proof of staleness. */
export async function tryConnect(sockPath: string): Promise<Socket | null> {
  const probe = await probeSocket(sockPath);
  return probe.status === "live" ? probe.socket : null;
}

/**
 * Classify connect outcomes; a gone result still needs age/identity checks
 * before cleanup. Capture the file identity and time immediately before probing.
 */
export function probeSocket(sockPath: string, timeoutMs = PROBE_TIMEOUT_MS): Promise<SocketProbe> {
  const identity = socketIdentity(sockPath);
  const probedAtNs = BigInt(Date.now()) * 1_000_000n;
  return new Promise((resolve) => {
    const sock = new Socket();
    let settled = false;
    const settle = (result: SocketProbe) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (result.status !== "live") sock.destroy();
      resolve(result);
    };
    // Accepted macOS risk: a stalled live listener with a full accept queue
    // (default somaxconn 128) can also return ECONNREFUSED (XNU behavior, not
    // runtime-verified here). For an old socket, the age guard cannot distinguish
    // that case from a crashed owner.
    const onError = (error: NodeJS.ErrnoException) => settle(
      error.code === "ECONNREFUSED" || error.code === "ENOENT"
        ? { status: "gone", identity, probedAtNs }
        : { status: "unknown" },
    );
    const timer = setTimeout(() => settle({ status: "unknown" }), timeoutMs);
    sock.once("connect", () => settle({ status: "live", socket: sock }));
    sock.once("error", onError);
    try { sock.connect({ path: sockPath }); }
    catch (error) { onError(error as NodeJS.ErrnoException); }
  });
}

/** Milliseconds until safe to re-probe; null means an unverified future ctime. */
function reclaimDelayMs(probe: SocketProbe): number | null {
  if (probe.status !== "gone" || !probe.identity) return 0;
  const ageNs = probe.probedAtNs - probe.identity.ctimeNs;
  if (ageNs < 0n) return null;
  if (ageNs >= MIN_RECLAIM_AGE_NS) return 0;
  return Number((MIN_RECLAIM_AGE_NS - ageNs + 999_999n) / 1_000_000n);
}

/** One bounded maturity wait, without spending the caller's retry budget. */
async function probeSocketForReclaim(sockPath: string, timeoutMs = PROBE_TIMEOUT_MS): Promise<SocketProbe> {
  let probe = await probeSocket(sockPath, timeoutMs);
  const waitMs = reclaimDelayMs(probe);
  if (waitMs === null) return { status: "unknown" };
  if (waitMs === 0) return probe;
  // A new socket can be between bind/listen, or alias a just-unlinked inode's
  // timestamps. Wait at most two seconds, then re-read AND re-probe. If the
  // path changed again or the clock moved backwards, let bounded retries decide.
  await delay(waitMs);
  probe = await probeSocket(sockPath, timeoutMs);
  return reclaimDelayMs(probe) === 0 ? probe : { status: "unknown" };
}

/** Short bounded retry for callers that refuse ownership on persistent doubt. */
export async function probeSocketWithRetry(sockPath: string, timeoutMs = PROBE_TIMEOUT_MS): Promise<SocketProbe> {
  for (let attempt = 0; ; attempt++) {
    const probe = await probeSocketForReclaim(sockPath, timeoutMs);
    if (probe.status !== "unknown" || attempt === 2) return probe;
    await delay(BASE_BACKOFF_MS);
  }
}

/**
 * Attempts to bind a UDS server on `sockPath`. Returns the live server on
 * success, null when the path is already held (EADDRINUSE) or any other
 * bind error. Caller is responsible for verified stale-socket cleanup.
 */
export function tryBind(sockPath: string): Promise<Server | null> {
  return _tryBind(sockPath);
}

/** Remove only the unchanged socket that was already mature at a gone probe. */
export function removeStaleSock(sockPath: string, probe: SocketProbe): void {
  if (probe.status === "gone" && reclaimDelayMs(probe) === 0) {
    removeSocketIfSame(sockPath, probe.identity);
  }
}

export function socketIdentity(sockPath: string): SocketIdentity | null {
  if (usesNamedPipe()) return null;
  try {
    const stat = lstatSync(sockPath, { bigint: true });
    return stat.isSocket()
      ? { dev: stat.dev, ino: stat.ino, ctimeNs: stat.ctimeNs, birthtimeNs: stat.birthtimeNs }
      : null;
  } catch {
    return null;
  }
}

/**
 * Age plus timestamps reduce rapid inode/timestamp reuse and bind/listen races;
 * they cannot exclude a bind/listen stall beyond the minimum age. The final
 * lstat and unlink are separate syscalls, leaving a tiny replacement window.
 * This is not an atomic ownership primitive.
 */
function removeSocketIfSame(sockPath: string, identity: SocketIdentity | null): void {
  if (!identity || usesNamedPipe()) return;
  const current = socketIdentity(sockPath);
  if (!current || current.dev !== identity.dev || current.ino !== identity.ino ||
      current.ctimeNs !== identity.ctimeNs || current.birthtimeNs !== identity.birthtimeNs) return;
  try { unlinkSync(sockPath); } catch { /* Already removed or inaccessible. */ }
}

function _tryBind(sockPath: string): Promise<Server | null> {
  return new Promise((resolve) => {
    const server = createServer();
    let settled = false;
    const settle = (val: Server | null) => {
      if (settled) return;
      settled = true;
      if (!val) {
        try { server.close(); } catch { /* ignored */ }
      }
      resolve(val);
    };
    server.once("error", () => settle(null));
    server.listen(sockPath, () => settle(server));
  });
}
