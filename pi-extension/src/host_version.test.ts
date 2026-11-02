import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { detectHostPiVersion, normalizeWindowsShellPath, supportsSessionControlDispatch } from "./host_version.js";

describe("detectHostPiVersion", () => {
  let root: string;
  beforeEach(() => { root = mkdtempSync(join(tmpdir(), "host-version-")); });
  afterEach(() => { rmSync(root, { recursive: true, force: true }); });

  function file(path: string, content = ""): string {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, content);
    return path;
  }

  function host(name = "@earendil-works/pi-coding-agent", version: unknown = "1.5.0"): { dir: string; entry: string } {
    const dir = join(root, "node_modules", name);
    file(join(dir, "package.json"), JSON.stringify({ name, version }));
    return { dir, entry: file(join(dir, "dist", "cli.js")) };
  }

  test("resolves a node_modules/.bin symlink to the host, not the extension package", () => {
    const { entry } = host();
    file(join(root, "package.json"), JSON.stringify({ name: "remote-pi", version: "0.79.10" }));
    const bin = join(root, "node_modules", ".bin", "pi");
    mkdirSync(dirname(bin), { recursive: true });
    symlinkSync(entry, bin);
    expect(detectHostPiVersion(bin)).toBe("1.5.0");
  });

  test("skips nested non-matching manifests", () => {
    const { dir, entry } = host();
    file(join(dir, "dist", "package.json"), JSON.stringify({ name: "remote-pi", version: "0.79.10" }));
    expect(detectHostPiVersion(entry)).toBe("1.5.0");
  });

  test("accepts the legacy @mariozechner package name", () => {
    expect(detectHostPiVersion(host("@mariozechner/pi-coding-agent", "0.84.2").entry)).toBe("0.84.2");
  });

  test("PI_PACKAGE_DIR takes precedence, even without argv[1]", () => {
    const { dir } = host();
    expect(detectHostPiVersion(undefined, dir)).toBe("1.5.0");
    expect(detectHostPiVersion("/missing/entry", dir)).toBe("1.5.0");
    expect(detectHostPiVersion(host().entry, join(root, "missing"))).toBeUndefined();
  });

  test.each(["~", "~/rel"])("expands override %s under the supplied home", (override) => {
    const home = join(root, "home");
    const dir = override === "~" ? home : join(home, "rel");
    file(join(dir, "package.json"), JSON.stringify({ version: "1.5.0" }));
    expect(detectHostPiVersion(undefined, override, home)).toBe("1.5.0");
  });

  test("expands ~/pkg instead of reading a conflicting literal path in cwd", () => {
    const home = join(root, "home");
    const cwd = join(root, "cwd");
    file(join(home, "pkg", "package.json"), JSON.stringify({ version: "1.5.0" }));
    file(join(cwd, "~", "pkg", "package.json"), JSON.stringify({ version: "0.79.10" }));
    const previousCwd = process.cwd();
    try {
      process.chdir(cwd);
      expect(detectHostPiVersion(undefined, "~/pkg", home)).toBe("1.5.0");
      rmSync(join(home, "pkg"), { recursive: true });
      expect(detectHostPiVersion(undefined, "~/pkg", home)).toBeUndefined();
    } finally {
      process.chdir(previousCwd);
    }
  });

  test("decodes a file:// override, including escaped spaces", () => {
    const dir = join(root, "pi package");
    file(join(dir, "package.json"), JSON.stringify({ version: "1.5.0" }));
    expect(detectHostPiVersion(undefined, pathToFileURL(dir).href)).toBe("1.5.0");
  });

  test("an invalid file:// override remains unknown", () => {
    expect(detectHostPiVersion(host().entry, "file:///%ZZ")).toBeUndefined();
  });

  test("does not trim or strip @ from an override", () => {
    const { dir } = host();
    expect(detectHostPiVersion(undefined, ` ${dir} `)).toBeUndefined();
    expect(detectHostPiVersion(undefined, `@${dir}`)).toBeUndefined();
  });

  test("missing argv, missing entrypoint, or no matching package is unknown", () => {
    expect(detectHostPiVersion(undefined)).toBeUndefined();
    expect(detectHostPiVersion(join(root, "missing"))).toBeUndefined();
    const entry = file(join(root, "dist", "cli.js"));
    file(join(root, "package.json"), JSON.stringify({ name: "remote-pi", version: "1.5.0" }));
    expect(detectHostPiVersion(entry)).toBeUndefined();
  });

  test("malformed JSON is unknown, including an override or nested manifest", () => {
    const { dir, entry } = host();
    file(join(dir, "dist", "package.json"), "{");
    expect(detectHostPiVersion(entry)).toBeUndefined();
    file(join(dir, "package.json"), "{");
    expect(detectHostPiVersion(entry, dir)).toBeUndefined();
  });

  test("an unreadable manifest is unknown", () => {
    const { dir, entry } = host();
    mkdirSync(join(dir, "dist", "package.json"));
    expect(detectHostPiVersion(entry)).toBeUndefined();
  });

  test.each([null, 150, {}])("non-string version %j is unknown", (version) => {
    const { dir, entry } = host(undefined, version);
    expect(detectHostPiVersion(entry)).toBeUndefined();
    expect(detectHostPiVersion(entry, dir)).toBeUndefined();
  });

  test("bounds the ancestor walk", () => {
    const { dir } = host();
    const entry = file(join(dir, ...Array<string>(8).fill("nested"), "cli.js"));
    expect(detectHostPiVersion(entry)).toBeUndefined();
  });
});

describe("supportsSessionControlDispatch", () => {
  test.each([undefined, "unknown", "0.0.0", "0.79.10", "0.84.1", "0.84.2-beta.1", "1.4", "1.4.0junk", "1.4.0+", "1.4.0+build..1", "1.4.0-01", "9007199254740992.0.0"])("rejects %s", (version) => {
    expect(supportsSessionControlDispatch(version)).toBe(false);
  });

  test.each(["0.84.2", "0.84.3", "0.85.0", "1.0.0", "1.4.0", "1.5.0", "1.4.0+build.1", "0.85.0-beta.1", "1.4.0-beta.1"])("accepts %s", (version) => {
    expect(supportsSessionControlDispatch(version)).toBe(true);
  });
});

describe("normalizeWindowsShellPath", () => {
  test.each([
    ["/c", "C:\\"],
    ["/c/", "C:\\"],
    ["/c/Users/pi", "C:\\Users\\pi"],
    ["/D/Users/pi", "D:\\Users\\pi"],
    ["/mnt/c/Users/pi", "C:\\Users\\pi"],
    ["/cygdrive/d/Users/pi", "D:\\Users\\pi"],
    ["/MNT/c/pi", "C:\\pi"],
    ["/mnt/c", "C:\\"],
    ["/cygdrive/d", "D:\\"],
  ])("converts %s to %s", (input, expected) => {
    expect(normalizeWindowsShellPath(input)).toBe(expected);
  });

  test.each(["//server/share", "/c/path\\mixed", "/home/pi", "/mnt/share/pi", "C:\\pi", "relative/pi", "~/pi", "file:///C:/pi", " /c/pi", "/1/pi"])("preserves %s", (input) => {
    expect(normalizeWindowsShellPath(input)).toBe(input);
  });
});
