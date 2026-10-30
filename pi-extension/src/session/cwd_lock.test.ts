import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { mkdtempSync, rmSync, mkdirSync, lstatSync, unlinkSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import { Socket, createServer } from "node:net";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { dirname, join } from "node:path";
import { acquireCwdLock, lockPathForCwd, lockPathFor } from "./cwd_lock.js";

/** A fresh tmp cwd per test — each gets a unique room hash, so tests in
 *  parallel don't fight over the same lock socket. */
function tmpCwd(): string {
  return mkdtempSync(join(tmpdir(), "pi-cwdlock-"));
}

/** Redirect the lock dir away from the developer's real `~/.pi/remote/locks`
 *  so running the suite never binds sockets in the live mesh's directory.
 *
 *  Base it on a SHORT root (`/tmp`), NOT `os.tmpdir()`: the lock socket nests
 *  `<home>/.pi/remote/locks/<12-char>.sock`, and on macOS `os.tmpdir()` is a
 *  deep `/var/folders/…/T/` path that pushes the socket past the ~104-char UDS
 *  path limit → `bind` fails → `acquireCwdLock` returns `ok:false` and these
 *  tests fail (and break `prepublishOnly`). `/tmp` keeps the full path short. */
let testHome: string;

beforeEach(() => {
  testHome = mkdtempSync("/tmp/rp-cwdlock-");
  process.env["REMOTE_PI_HOME"] = testHome;
});

afterEach(() => {
  delete process.env["REMOTE_PI_HOME"];
  try { rmSync(testHome, { recursive: true, force: true }); } catch { /* best-effort */ }
});

describe("acquireCwdLock", () => {
  test("first call acquires; second call (same cwd) is refused", async () => {
    const cwd = tmpCwd();

    const first = await acquireCwdLock(cwd);
    expect(first.ok).toBe(true);

    const second = await acquireCwdLock(cwd);
    expect(second.ok).toBe(false);
    if (!second.ok) {
      expect(second.lockPath).toBe(lockPathForCwd(cwd));
      expect(second).toMatchObject({ reason: "held" });
    }

    if (first.ok) first.release();
  });

  test("releasing the lock allows a fresh acquire", async () => {
    const cwd = tmpCwd();

    const first = await acquireCwdLock(cwd);
    expect(first.ok).toBe(true);
    if (first.ok) first.release();

    // Some platforms keep the socket file around after close — the lock
    // primitive must self-heal via the stale-detect-then-unlink path.
    const second = await acquireCwdLock(cwd);
    expect(second.ok).toBe(true);
    if (second.ok) second.release();
  });

  test("different cwds get independent locks", async () => {
    const cwdA = tmpCwd();
    const cwdB = tmpCwd();

    const a = await acquireCwdLock(cwdA);
    const b = await acquireCwdLock(cwdB);

    expect(a.ok).toBe(true);
    expect(b.ok).toBe(true);
    expect(lockPathForCwd(cwdA)).not.toBe(lockPathForCwd(cwdB));

    if (a.ok) a.release();
    if (b.ok) b.release();
  });

  test("same cwd, DIFFERENT names → independent locks (multi-agent per folder)", async () => {
    const cwd = tmpCwd();
    const a = await acquireCwdLock(cwd, "backend");
    const b = await acquireCwdLock(cwd, "frontend");

    expect(a.ok).toBe(true);
    expect(b.ok).toBe(true); // different name in the same folder is allowed
    expect(lockPathFor(cwd, "backend")).not.toBe(lockPathFor(cwd, "frontend"));

    if (a.ok) a.release();
    if (b.ok) b.release();
  });

  test("same cwd, SAME name → refused (per-(cwd,name) singleton)", async () => {
    const cwd = tmpCwd();
    const first = await acquireCwdLock(cwd, "backend");
    expect(first.ok).toBe(true);

    const second = await acquireCwdLock(cwd, "backend");
    expect(second.ok).toBe(false);
    if (!second.ok) expect(second.lockPath).toBe(lockPathFor(cwd, "backend"));

    if (first.ok) first.release();
  });

  test("named lock is independent from the legacy cwd-only lock", async () => {
    const cwd = tmpCwd();
    const named = await acquireCwdLock(cwd, "backend");
    const legacy = await acquireCwdLock(cwd); // no name → old room-id lock
    expect(named.ok).toBe(true);
    expect(legacy.ok).toBe(true);
    expect(lockPathFor(cwd, "backend")).not.toBe(lockPathForCwd(cwd));
    if (named.ok) named.release();
    if (legacy.ok) legacy.release();
  });

  test("refused result includes the canonical lockPath", async () => {
    const cwd = tmpCwd();
    const held = await acquireCwdLock(cwd);
    expect(held.ok).toBe(true);

    const refused = await acquireCwdLock(cwd);
    expect(refused.ok).toBe(false);
    if (!refused.ok) {
      // Same hash → same path, regardless of which call computes it.
      expect(refused.lockPath).toBe(lockPathForCwd(cwd));
    }

    if (held.ok) held.release();
  });
});

describe.skipIf(process.platform === "win32")("acquireCwdLock socket safety", () => {
  test.each(["EAGAIN", "timeout"])("refuses after bounded %s probes without unlinking", async (mode) => {
    const cwd = tmpCwd();
    const owner = await acquireCwdLock(cwd);
    const path = lockPathForCwd(cwd);
    const before = lstatSync(path);
    const connect = vi.spyOn(Socket.prototype, "connect").mockImplementation(function (this: Socket) {
      if (mode !== "timeout") queueMicrotask(() => this.emit("error", Object.assign(new Error(mode), { code: mode })));
      return this;
    });
    let contender: Awaited<ReturnType<typeof acquireCwdLock>> | undefined;
    try {
      contender = await acquireCwdLock(cwd);
      expect(contender.ok).toBe(false);
      expect(contender).toMatchObject({ reason: "unverified" });
      expect(connect.mock.calls.length).toBeGreaterThan(1);
      expect(connect.mock.calls.length).toBeLessThanOrEqual(5);
      expect(lstatSync(path).ino).toBe(before.ino);
    } finally {
      connect.mockRestore();
      if (contender?.ok) contender.release();
      if (owner.ok) owner.release();
    }
  });

  test("re-probes a transient unknown result and refuses a live owner", async () => {
    const cwd = tmpCwd();
    const owner = await acquireCwdLock(cwd);
    const path = lockPathForCwd(cwd);
    const before = lstatSync(path);
    const connect = vi.spyOn(Socket.prototype, "connect").mockImplementationOnce(function (this: Socket) {
      queueMicrotask(() => this.emit("error", Object.assign(new Error("busy"), { code: "EAGAIN" })));
      return this;
    });
    let contender: Awaited<ReturnType<typeof acquireCwdLock>> | undefined;
    try {
      contender = await acquireCwdLock(cwd);
      expect(contender.ok).toBe(false);
      expect(contender).toMatchObject({ reason: "held" });
      expect(connect).toHaveBeenCalledTimes(2);
      expect(lstatSync(path).ino).toBe(before.ino);
    } finally {
      connect.mockRestore();
      if (contender?.ok) contender.release();
      if (owner.ok) owner.release();
    }
  });

  test("does not unlink a replacement installed during a gone probe", async () => {
    const cwd = tmpCwd();
    const owner = await acquireCwdLock(cwd);
    const path = lockPathForCwd(cwd);
    const replacement = createServer();
    await new Promise<void>((resolve) => replacement.listen(`${path}.new`, resolve));
    const identity = lstatSync(`${path}.new`);
    const connect = vi.spyOn(Socket.prototype, "connect").mockImplementationOnce(function (this: Socket) {
      unlinkSync(path);
      renameSync(`${path}.new`, path);
      queueMicrotask(() => this.emit("error", Object.assign(new Error("gone"), { code: "ECONNREFUSED" })));
      return this;
    });
    let contender: Awaited<ReturnType<typeof acquireCwdLock>> | undefined;
    try {
      contender = await acquireCwdLock(cwd);
      expect(contender.ok).toBe(false);
      expect(lstatSync(path).ino).toBe(identity.ino);
    } finally {
      connect.mockRestore();
      if (contender?.ok) contender.release();
      if (owner.ok) owner.release();
      await new Promise<void>((resolve) => replacement.close(() => resolve()));
    }
  });

  test("a failed second bind after a gone probe leaves ownership unverified", async () => {
    const cwd = tmpCwd();
    const path = lockPathForCwd(cwd);
    mkdirSync(path, { recursive: true });
    const connect = vi.spyOn(Socket.prototype, "connect").mockImplementation(function (this: Socket) {
      queueMicrotask(() => this.emit("error", Object.assign(new Error("gone"), { code: "ENOENT" })));
      return this;
    });
    try {
      expect(await acquireCwdLock(cwd)).toEqual({ ok: false, lockPath: path, reason: "unverified" });
      expect(lstatSync(path).isDirectory()).toBe(true);
    } finally { connect.mockRestore(); }
  });

  test.each(["young", "mature", "future"])("handles a %s real SIGKILL leftover without unsafe cleanup", async (age) => {
    const cwd = tmpCwd();
    const path = lockPathForCwd(cwd);
    mkdirSync(dirname(path), { recursive: true });
    const child = spawn(process.execPath, ["-e", `require('node:net').createServer().listen(process.argv[1], () => process.stdout.write('ready\\n'))`, path]);
    let clock: ReturnType<typeof vi.spyOn> | undefined;
    try {
      await once(child.stdout!, "data");
      child.kill("SIGKILL");
      await once(child, "exit");
      expect(lstatSync(path).isSocket()).toBe(true);
      const created = Number(lstatSync(path, { bigint: true }).ctimeNs / 1_000_000n);
      clock = vi.spyOn(Date, "now").mockReturnValue(created + (age === "young" ? 1950 : age === "future" ? -60_000 : 3000));
      let settled = false;
      const pending = acquireCwdLock(cwd).then((result) => { settled = true; return result; });
      if (age === "young") {
        await new Promise((resolve) => setTimeout(resolve, 20));
        expect.soft(settled).toBe(false);
        clock.mockReturnValue(created + 2050);
      }
      const result = await pending;
      try {
        expect(result.ok).toBe(age !== "future");
        if (age === "future") {
          expect(result).toMatchObject({ reason: "unverified" });
          expect(lstatSync(path).isSocket()).toBe(true);
        }
      } finally { if (result.ok) result.release(); }
    } finally { clock?.mockRestore(); child.kill("SIGKILL"); }
  });
});
