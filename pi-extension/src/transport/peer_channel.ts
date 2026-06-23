import type { ClientMessage, ServerMessage } from "../protocol/types.js";
import type { RelayClient } from "./relay_client.js";

/** Sink for ServerMessage outbound to the remote app. */
export interface PeerChannel {
  send(msg: ServerMessage): void;
}

/**
 * Outer envelope shape forwarded by the relay.
 * { "peer": "<sender_peer_id>", "room"?: "<room_id>", "ct": "<base64 JSON inner>" }
 *
 * Post rollback (plano 06): `ct` is base64(JSON.stringify(inner)) — no cipher,
 * no MAC. Relay continues opaque (never JSON.parses ct).
 *
 * `room` (plano 17): identifies which Pi room sent the envelope. Lets the
 * relay multiplex N peers with the same Ed25519 pubkey but distinct cwds.
 * Optional for backward-compat with single-room relays.
 */
interface OuterEnvelope {
  peer: string;
  room?: string;
  /** Sender room for legacy relays that raw-forward envelopes without rewriting `room`. */
  source_room?: string;
  ct: string;
}

/**
 * Plaintext PeerChannel backed by a RelayClient WebSocket.
 *
 * Usage (after pair_request handshake completes):
 *   const channel = new PlainPeerChannel(relay, appPeerId, myRoomId, onMsg)
 *   channel.send(serverMessage)          // base64-encodes JSON, routes via relay
 *   // incoming relay messages destined for appPeerId are auto-decoded
 *   // and delivered via onMessage callback
 *
 * `myRoomId` is the *local* Pi's room id — sent on every outbound envelope
 * so the app can correlate which Pi sent it (multi-pi support, plano 17).
 */
export class PlainPeerChannel implements PeerChannel {
  private readonly _unsubscribe: () => void;

  constructor(
    private readonly relay: RelayClient,
    private readonly remotePeerId: string,
    /** This Pi's room id. Sent as `source_room` for app-side demux when a
     * legacy relay raw-forwards envelopes instead of rewriting `room`. */
    private readonly myRoomId: string | undefined,
    private readonly onMessage: (msg: ClientMessage) => void,
    /** Called when this specific peer connection is considered lost. */
    _onDisconnect?: () => void,
  ) {
    const listener = (line: string) => this._onLine(line);
    relay.on("message", listener);
    this._unsubscribe = () => relay.off("message", listener);
    void _onDisconnect;
  }

  // ── PeerChannel interface ──────────────────────────────────────────────────

  send(msg: ServerMessage): void {
    const ct = Buffer.from(JSON.stringify(msg)).toString("base64");
    // `room` is the relay destination room and intentionally omitted so the
    // relay defaults to the app's `main` room. `source_room` survives legacy
    // raw-forward relays so updated apps can drop frames from inactive Pi rooms.
    const outer: OuterEnvelope = {
      peer: this.remotePeerId,
      ...(this.myRoomId ? { source_room: this.myRoomId } : {}),
      ct,
    };
    // Best-effort delivery: reconnect + session_sync recover dropped frames;
    // throwing here can kill the pi process from async SDK callbacks.
    try {
      this.relay.send(JSON.stringify(outer));
    } catch {
      /* relay down — drop this frame; reconnect + session_sync will recover */
    }
  }

  /** Detaches from relay (does not close the relay itself). */
  detach(): void {
    this._unsubscribe();
  }

  // ── Incoming line from relay ────────────────────────────────────────────────

  private _onLine(line: string): void {
    let outer: OuterEnvelope;
    try {
      outer = JSON.parse(line) as OuterEnvelope;
    } catch {
      return; // malformed line
    }

    if (outer.peer !== this.remotePeerId) return;
    if (!outer.ct) return;

    let plaintext: string;
    try {
      plaintext = Buffer.from(outer.ct, "base64").toString("utf8");
    } catch {
      return;
    }

    let msg: unknown;
    try {
      msg = JSON.parse(plaintext);
    } catch {
      return;
    }

    if (
      !msg ||
      typeof msg !== "object" ||
      typeof (msg as Record<string, unknown>).type !== "string"
    ) {
      return;
    }

    this.onMessage(msg as ClientMessage);
  }
}
