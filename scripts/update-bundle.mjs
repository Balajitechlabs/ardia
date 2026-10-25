import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, statSync, mkdirSync, mkdtempSync, renameSync, rmSync, cpSync, readdirSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { tmpdir, homedir } from "node:os";
import { dirname, resolve, join } from "node:path";

const root = resolve(import.meta.dirname, "..");
const appDir = join(root, "apps/browser");
const rn = join(root, "node_modules/react-native-macos");
const hermesc = join(root, "node_modules/react-native/sdks/hermesc/osx-bin/hermesc");

const targetApp = resolve(process.env.TARGET_APP || (existsSync(resolve(root, "../apps/Ardia.app")) ? resolve(root, "../apps/Ardia.app") : "/Applications/Ardia.app"));
const resourcesDir = join(targetApp, "Contents/Resources");
const bundleDest = join(resourcesDir, "main.jsbundle");
const backupDir = join(homedir(), ".cache/ardia-bundle-backups");
const backupDest = join(backupDir, `${encodeURIComponent(targetApp)}.main.jsbundle.original`);

if (!existsSync(targetApp)) {
  console.error(`Target app not found: ${targetApp}`);
  process.exit(1);
}

if (!existsSync(backupDest) && existsSync(bundleDest)) {
  try {
    mkdirSync(backupDir, { recursive: true });
    copyFileSync(bundleDest, backupDest);
    console.log(`Backed up original bundle outside app to: ${backupDest}`);
  } catch (e) {
    if (e.code !== "EEXIST") console.warn("Notice: could not backup bundle:", e.message);
  }
}

const scratchDir = mkdtempSync(join(tmpdir(), "ardia-update-bundle-"));
const tmpJs = join(scratchDir, "main.js");
const tmpHbc = join(scratchDir, "main.hbc");
const tmpAssets = join(scratchDir, "assets");
const stagedBundle = join(dirname(bundleDest), `.main.jsbundle-${randomUUID()}.tmp`);

try {
  mkdirSync(tmpAssets, { recursive: true });
  console.log("Bundling React Native UI...");
  execFileSync(
    process.execPath,
    [
      join(rn, "scripts/bundle.js"),
      "bundle",
      "--entry-file", "index.js",
      "--platform", "macos",
      "--dev", "false",
      "--minify", "false",
      "--bundle-output", tmpJs,
      "--assets-dest", tmpAssets,
    ],
    { cwd: appDir, stdio: "inherit" }
  );

  console.log("Compiling Hermes bytecode v96...");
  execFileSync(hermesc, ["-emit-binary", "-max-diagnostic-width=80", "-O", "-out", tmpHbc, tmpJs], {
    stdio: "inherit",
  });

  // Copy any bundled assets into Contents/Resources
  if (existsSync(tmpAssets) && readdirSync(tmpAssets).length > 0) {
    cpSync(tmpAssets, resourcesDir, { recursive: true });
  }

  // Atomically replace bundleDest
  copyFileSync(tmpHbc, stagedBundle);
  renameSync(stagedBundle, bundleDest);

  // Re-sign ad-hoc preserving entitlements and metadata so team Keychain groups remain valid
  try {
    execFileSync("codesign", ["--force", "--deep", "--preserve-metadata=identifier,entitlements,flags,runtime", "--sign", "-", targetApp], { stdio: "ignore" });
  } catch {}

  const sizeMb = (statSync(bundleDest).size / (1024 * 1024)).toFixed(2);
  console.log(`\n Successfully updated ${targetApp}!`);
  console.log(` Bundle size: ${sizeMb} MB`);
  console.log(` Test with: open -a "${targetApp}" "https://news.ycombinator.com"\n`);
} catch (e) {
  if (e.code === "EBUSY" || e.code === "EPERM" || String(e).includes("permitted")) {
    console.error("\n [!] Ardia is currently running or locked. Please quit Ardia (⌘Q) and try again.\n");
    process.exitCode = 1;
  } else {
    throw e;
  }
} finally {
  rmSync(stagedBundle, { force: true });
  rmSync(scratchDir, { recursive: true, force: true });
}
