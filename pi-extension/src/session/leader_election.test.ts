import { describe, expect, test, vi } from "vitest";
import { mkdtempSync, writeFileSync, lstatSync, renameSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { Socket, createServer } from "node:net";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { joinOrLead, probeSocket, removeStaleSock } from "./leader_election.js";
import { ipcAddress } from "./ipc.js";

function tmpSock(): string {
  // Per-test unique IPC address (pipe on Windows; `.sock` file on POSIX). The
  // suffix embeds the unique tmpdir basename so machine-global pipe names don't
  // collide across tests/workers (plan/40).
  const dir = mkdtempSync(join(tmpdir(), "pi-le-"));
  return ipcAddress(`le-${basename(dir)}`, join(dir, "broker.sock"));
}

describe("joinOrLead", () => {
  async function cleanup(results: Array<{ role: string; server?: import("node:net").Server; socket?: import("node:net").Socket }>) {
    // Destroy follower sockets FIRST so the leader's server can close cleanly.
    for (const r of results) {
      if (r.role === "follower" && r.socket) r.socket.destroy();
    }
    for (const r of results) {
      if (r.role === "leader" && r.server) {
        await new Promise<void>((res) => r.server!.close(() => res()));
      }
    }
  }

  test("first caller becomes leader, second becomes follower", async () => {
    const sock = tmpSock();
    const r1 = await joinOrLead(sock);
    expect(r1.role).toBe("leader");

    const r2 = await joinOrLead(sock);
    expect(r2.role).toBe("follower");

    await cleanup([r1, r2] as Parameters<typeof cleanup>[0]);
  });

  test("3 concurrent callers: exactly 1 leader", async () => {
    const sock = tmpSock();
    const results = await Promise.all([
      joinOrLead(sock),
      joinOrLead(sock),
      joinOrLead(sock),
    ]);
    const leaders = results.filter((r) => r.role === "leader");
    const followers = results.filter((r) => r.role === "follower");
    expect(leaders).toHaveLength(1);
    expect(followers).toHaveLength(2);

    await cleanup(results as Parameters<typeof cleanup>[0]);
  });

  test.skipIf(process.platform === "win32").each(["young", "mature"])("reclaims a %s real SIGKILL leftover", async (age) => {
    const path = tmpSock();
    const child = spawn(process.execPath, ["-e", `require('node:net').createServer().listen(process.argv[1], () => process.stdout.write('ready\\n'))`, path]);
    let clock: ReturnType<typeof vi.spyOn> | undefined;
    try {
      await once(child.stdout!, "data");
      child.kill("SIGKILL");
      await once(child, "exit");
      expect(lstatSync(path).isSocket()).toBe(true);
      const created = Number(lstatSync(path, { bigint: true }).ctimeNs / 1_000_000n);
      // Exercise nearly the full two-second wait: election must not burn its
      // bounded attempt budget while a newborn crash-leftover matures.
      clock = vi.spyOn(Date, "now").mockReturnValue(created + (age === "young" ? 1 : 3000));
      let settled = false;
      const pending = joinOrLead(path).then((result) => { settled = true; return result; });
      if (age === "young") {
        await new Promise((resolve) => setTimeout(resolve, 20));
        expect.soft(settled).toBe(false);
        clock.mockReturnValue(created + 2050);
      }
      const result = await pending;
      try { expect(result.role).toBe("leader"); }
      finally { await cleanup([result]); }
    } finally { clock?.mockRestore(); child.kill("SIGKILL"); }
  });

  test.skipIf(process.platform === "win32")("a stalled event loop must not unlink a live leader", async () => {
    const path = tmpSock();
    const owner = await joinOrLead(path);
    const before = lstatSync(path);
    let contender: Awaited<ReturnType<typeof joinOrLead>> | undefined;
    try {
      // Start in the timers phase, then stall past the probe deadline before
      // the poll phase can deliver the real IPC connect callback.
      contender = await new Promise((resolve, reject) => setTimeout(() => {
        const pending = joinOrLead(path);
        const until = Date.now() + 650;
        while (Date.now() < until) { /* deliberate event-loop stall */ }
        pending.then(resolve, reject);
      }, 0));
      expect(contender.role).toBe("follower");
      expect(lstatSync(path).ino).toBe(before.ino);
    } finally { await cleanup(contender ? [contender, owner] : [owner]); }
  });

  test.skipIf(process.platform === "win32")("a timed-out probe retries without removing a live leader", async () => {
    const path = tmpSock();
    const owner = await joinOrLead(path);
    const before = lstatSync(path);
    // Hold the first connect at the OS boundary to deterministically exercise
    // the timeout even on hosts that deliver connect before overdue timers.
    const connect = vi.spyOn(Socket.prototype, "connect").mockImplementationOnce(function (this: Socket) {
      return this;
    });
    let contender: Awaited<ReturnType<typeof joinOrLead>> | undefined;
    try {
      contender = await joinOrLead(path);
      expect(contender.role).toBe("follower");
      expect(connect).toHaveBeenCalledTimes(2);
      expect(lstatSync(path).ino).toBe(before.ino);
    } finally {
      connect.mockRestore();
      await cleanup(contender ? [contender, owner] : [owner]);
    }
  });

  test.skipIf(process.platform === "win32").each(["EAGAIN", "EMFILE", "ENFILE", "EACCES", "ECONNRESET"])("%s never removes a live leader and exhaustion is accurate", async (code) => {
    const path = tmpSock();
    const owner = await joinOrLead(path);
    const before = lstatSync(path);
    // OS-boundary injection avoids exhausting process/system resources or
    // depending on platform-specific backlog and permission behavior.
    const connect = vi.spyOn(Socket.prototype, "connect").mockImplementation(function (this: Socket) {
      queueMicrotask(() => this.emit("error", Object.assign(new Error(code), { code })));
      return this;
    });
    let contender: Awaited<ReturnType<typeof joinOrLead>> | undefined;
    try {
      let error: unknown;
      try { contender = await joinOrLead(path); } catch (e) { error = e; }
      expect(error).toBeInstanceOf(Error);
      expect(String(error)).toMatch(/existing broker socket.*could not be verified/i);
      expect(connect).toHaveBeenCalledTimes(20);
      expect(lstatSync(path).ino).toBe(before.ino);
    } finally {
      connect.mockRestore();
      await cleanup(contender ? [contender, owner] : [owner]);
    }
  });

  test.skipIf(process.platform === "win32")("does not remove a replacement socket after a gone probe", async () => {
    const path = tmpSock();
    const owner = await joinOrLead(path);
    const replacementPath = `${path}.new`;
    const replacement = createServer();
    await new Promise<void>((resolve) => replacement.listen(replacementPath, resolve));
    const identity = lstatSync(replacementPath);
    const original = Socket.prototype.connect;
    const connect = vi.spyOn(Socket.prototype, "connect").mockImplementationOnce(function (this: Socket) {
      // Deterministic interleaving: another contender installs its socket
      // while our old-path probe is in flight, before ECONNREFUSED arrives.
      unlinkSync(path);
      renameSync(replacementPath, path);
      queueMicrotask(() => this.emit("error", Object.assign(new Error("gone"), { code: "ECONNREFUSED" })));
      return this;
    }).mockImplementation(original);
    let result: Awaited<ReturnType<typeof joinOrLead>> | undefined;
    try {
      result = await joinOrLead(path);
      expect(result.role).toBe("follower");
      expect(lstatSync(path).ino).toBe(identity.ino);
    } finally {
      connect.mockRestore();
      await cleanup(result ? [result, owner] : [owner]);
      await new Promise<void>((resolve) => replacement.close(() => resolve()));
    }
  });

  test.skipIf(process.platform === "win32")("a gone probe must not remove a replacement that can reuse the stale inode", async () => {
    const path = tmpSock();
    const child = spawn(process.execPath, ["-e", `require('node:net').createServer().listen(process.argv[1], () => process.stdout.write('ready\\n'))`, path]);
    const replacement = createServer();
    try {
      await once(child.stdout!, "data");
      child.kill("SIGKILL");
      await once(child, "exit");
      const staleProbe = await probeSocket(path);
      expect(staleProbe.status).toBe("gone");

      // Model a second contender reclaiming after our probe. No descriptor or
      // hard link pins the stale inode, so the filesystem is free to reuse it.
      unlinkSync(path);
      await new Promise<void>((resolve) => replacement.listen(path, resolve));
      const identity = lstatSync(path, { bigint: true });
      removeStaleSock(path, staleProbe);
      expect(lstatSync(path, { bigint: true })).toMatchObject({
        dev: identity.dev, ino: identity.ino,
        ctimeNs: identity.ctimeNs, birthtimeNs: identity.birthtimeNs,
      });
      const liveProbe = await probeSocket(path);
      if (liveProbe.status === "live") liveProbe.socket.destroy();
      expect(liveProbe.status).toBe("live");
    } finally {
      child.kill("SIGKILL");
      await new Promise<void>((resolve) => replacement.close(() => resolve()));
    }
  });

  test.skipIf(process.platform === "win32").each(["ctimeNs", "birthtimeNs"] as const)("rejects stale %s even when device and inode match", async (field) => {
    const path = tmpSock();
    const owner = await joinOrLead(path);
    try {
      const stat = lstatSync(path, { bigint: true });
      const identity = {
        dev: stat.dev, ino: stat.ino,
        ctimeNs: stat.ctimeNs, birthtimeNs: stat.birthtimeNs,
      };
      // Deterministic coverage even on filesystems that do not immediately
      // recycle inodes: either differing timestamp alone must veto cleanup.
      identity[field] -= 1n;
      removeStaleSock(path, { status: "gone", identity, probedAtNs: stat.ctimeNs + 3_000_000_000n });
      expect(lstatSync(path, { bigint: true })).toMatchObject(stat);
    } finally { await cleanup([owner]); }
  });

  test.skipIf(process.platform !== "linux")("does not steal a bound-but-not-listening contender's socket", async () => {
    const path = tmpSock();
    // Test-only libuv handle: Node's public Server API combines bind/listen.
    // The child exposes the real kernel state without strace or another runtime.
    const child = spawn(process.execPath, ["-e", `
      const { Pipe, constants } = process.binding('pipe_wrap');
      const pipe = new Pipe(constants.SERVER);
      if (pipe.bind(process.argv[1]) !== 0) throw new Error('bind failed');
      pipe.onconnection = (error, socket) => { if (socket) socket.close(); };
      process.stdout.write('bound\\n');
      process.stdin.once('data', () => {
        if (pipe.listen(128) !== 0) throw new Error('listen failed');
        process.stdout.write('listening\\n');
      });
      process.stdin.resume();
    `, path]);
    let result: Awaited<ReturnType<typeof joinOrLead>> | undefined;
    let clock: ReturnType<typeof vi.spyOn> | undefined;
    try {
      await once(child.stdout!, "data");
      const identity = lstatSync(path, { bigint: true });
      expect((await probeSocket(path)).status).toBe("gone");
      const created = Number(identity.ctimeNs / 1_000_000n);
      clock = vi.spyOn(Date, "now").mockReturnValue(created + 1950);
      const pending = joinOrLead(path);
      await new Promise((resolve) => setTimeout(resolve, 20));
      const listening = once(child.stdout!, "data");
      child.stdin!.write("listen\n");
      await listening;
      clock.mockReturnValue(created + 2050);
      result = await pending;
      expect(result.role).toBe("follower");
      expect(lstatSync(path, { bigint: true }).ino).toBe(identity.ino);
    } finally {
      clock?.mockRestore();
      if (result) await cleanup([result]);
      const exited = once(child, "exit");
      child.kill("SIGKILL");
      await exited;
    }
  });

  test.skipIf(process.platform === "win32")("does not unlink a young same-quantum replacement even if every identity field aliases", async () => {
    const path = tmpSock();
    const replacement = await joinOrLead(path);
    try {
      const stat = lstatSync(path, { bigint: true });
      // An old gone probe and the immediately installed replacement can have
      // identical fields. Supply that aliased snapshot deterministically;
      // the real SIGKILL replacement case above also runs without a delay.
      removeStaleSock(path, {
        status: "gone",
        identity: { dev: stat.dev, ino: stat.ino, ctimeNs: stat.ctimeNs, birthtimeNs: stat.birthtimeNs },
        probedAtNs: stat.ctimeNs + 1_000_000n,
      });
      expect(lstatSync(path, { bigint: true })).toMatchObject(stat);
    } finally { await cleanup([replacement]); }
  });

  test.skipIf(process.platform === "win32")("never removes a regular file", async () => {
    const path = tmpSock();
    writeFileSync(path, "not a socket");
    const before = lstatSync(path);
    await expect(joinOrLead(path)).rejects.toThrow();
    expect(lstatSync(path).ino).toBe(before.ino);
  });
});
