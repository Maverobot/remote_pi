import { afterEach, describe, expect, test, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { createServer, type Socket } from "node:net";
import { SessionPeer } from "./peer.js";
import { envelope, serialize } from "./envelope.js";
import * as election from "./leader_election.js";
import { ipcAddress } from "./ipc.js";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  vi.restoreAllMocks();
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

async function wireBroker() {
  const dir = mkdtempSync(join(tmpdir(), "pi-peer-wire-"));
  const sockPath = ipcAddress(`peer-wire-${basename(dir)}`, join(dir, "broker.sock"));
  const sockets = new Set<Socket>();
  const messages: unknown[] = [];
  type Registration = { socket: Socket; name: string };
  const queued: Registration[] = [];
  const waiters: Array<(registration: Registration) => void> = [];
  const server = createServer((socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("error", () => undefined);
    socket.setEncoding("utf8");
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk;
      let nl: number;
      while ((nl = buffer.indexOf("\n")) >= 0) {
        const message = JSON.parse(buffer.slice(0, nl)) as { type?: string; name?: string };
        buffer = buffer.slice(nl + 1);
        if (message.type === "register") {
          const registration = { socket, name: message.name! };
          const waiter = waiters.shift();
          if (waiter) waiter(registration); else queued.push(registration);
        } else messages.push(message);
      }
    });
  });
  await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(sockPath, resolve); });
  cleanups.push(async () => {
    for (const socket of sockets) socket.destroy();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    rmSync(dir, { recursive: true, force: true });
  });
  return {
    sockPath, messages, sockets,
    nextRegistration: () => queued.length
      ? Promise.resolve(queued.shift()!)
      : new Promise<Registration>((resolve) => waiters.push(resolve)),
    ack: (socket: Socket, name: string, tail = "") => socket.write(
      JSON.stringify({ type: "register_ack", name_assigned: name, address_assigned: name }) + "\n" + tail,
    ),
  };
}

describe("SessionPeer pinned reconnect contract", () => {
  test("changed ACK cannot publish identity, deliver same-chunk messages, or send application traffic", async () => {
    const broker = await wireBroker();
    const peer = new SessionPeer({ sockPath: broker.sockPath, name: "Owned" });
    cleanups.push(() => peer.leave());
    const delivered = vi.fn();
    const reconnected = vi.fn();
    let rejectionClose: Promise<void> | undefined;
    const rejected = vi.fn(() => { rejectionClose = peer.leave(); });
    peer.onReconnectRejected(rejected);
    peer.onMessage(delivered);
    peer.onReconnect(reconnected);
    const starting = peer.start();
    const first = await broker.nextRegistration();
    broker.ack(first.socket, "Owned");
    await starting;
    peer.pinAssignedName();
    first.socket.destroy();
    const second = await broker.nextRegistration();
    expect(second.name).toBe("Owned");
    await expect.soft(peer.send("other", { phase: "before ACK" })).rejects.toThrow();
    broker.ack(second.socket, "Unowned", serialize(envelope("other", "Unowned", { text: "must not deliver" })));
    // Observe either rejection/closure or the buggy successful reconnect, not a
    // guessed delay between writing the ACK and the client parsing it.
    await vi.waitFor(() => expect(second.socket.destroyed || reconnected.mock.calls.length > 0).toBe(true));
    expect.soft(peer.name()).toBe("Owned");
    expect.soft(delivered).not.toHaveBeenCalled();
    expect.soft(reconnected).not.toHaveBeenCalled();
    expect(rejected).toHaveBeenCalledWith(expect.objectContaining({ expectedName: "Owned", assignedName: "Unowned" }));
    await expect(peer.request("other", {})).rejects.toThrow();
    await expect(peer.sendWithAck("other", {})).resolves.toMatchObject({ status: "timeout" });
    await expect.soft(peer.send("other", { phase: "after ACK" })).rejects.toThrow();
    expect(broker.messages).toEqual([]);
    await rejectionClose; // A close from the failure signal must not await itself.
  });

  test.each(["initial", "reconnect"])("leave drains a pending %s registration without late success", async (phase) => {
    const broker = await wireBroker();
    const peer = new SessionPeer({ sockPath: broker.sockPath, name: "Owned" });
    cleanups.push(() => peer.leave());
    const reconnected = vi.fn();
    const rejected = vi.fn();
    peer.onReconnect(reconnected);
    peer.onReconnectRejected(rejected);
    const starting = peer.start().then(() => "accepted", () => "rejected");
    let registration = await broker.nextRegistration();
    if (phase === "reconnect") {
      broker.ack(registration.socket, "Owned");
      expect(await starting).toBe("accepted");
      peer.pinAssignedName();
      registration.socket.destroy();
      registration = await broker.nextRegistration();
    }
    await peer.leave();
    if (phase === "initial") expect(await starting).toBe("rejected");
    await vi.waitFor(() => expect(registration.socket.destroyed).toBe(true));
    expect(reconnected).not.toHaveBeenCalled();
    expect(rejected).not.toHaveBeenCalled();
    await expect(peer.send("other", {})).rejects.toThrow();
  });

  test.each(["leader", "follower"])("leave drains and disposes a late %s election result", async (role) => {
    const broker = role === "follower" ? await wireBroker() : null;
    const dir = mkdtempSync(join(tmpdir(), "pi-peer-election-"));
    const sockPath = broker?.sockPath ?? ipcAddress(`peer-election-${basename(dir)}`, join(dir, "broker.sock"));
    cleanups.push(async () => { rmSync(dir, { recursive: true, force: true }); });
    const acquired = deferred<void>();
    const resume = deferred<void>();
    const joinOrLead = election.joinOrLead;
    vi.spyOn(election, "joinOrLead").mockImplementationOnce(async (path) => {
      const result = await joinOrLead(path);
      expect(result.role).toBe(role);
      acquired.resolve();
      await resume.promise;
      return result;
    });
    const peer = new SessionPeer({ sockPath, name: "Owned" });
    cleanups.push(() => peer.leave());
    const starting = peer.start().then(() => "accepted", () => "rejected");
    let leaving: Promise<void> | undefined;
    try {
      await acquired.promise;
      let left = false;
      leaving = peer.leave().then(() => { left = true; });
      await new Promise<void>((resolve) => setImmediate(resolve));
      expect.soft(left).toBe(false);
      resume.resolve();
      await leaving;
      expect(await starting).toBe("rejected");
      if (broker) await vi.waitFor(() => expect(broker.sockets.size).toBe(0));
      else expect(await election.tryConnect(sockPath)).toBeNull();
    } finally {
      resume.resolve();
      await leaving;
      await starting;
    }
  });
});
