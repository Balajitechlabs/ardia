import { execFileSync, spawnSync } from "node:child_process";
import { constants, copyFileSync, existsSync, statSync, mkdirSync, mkdtempSync, renameSync, rmSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { dirname, resolve, join } from "node:path";

const root = resolve(import.meta.dirname, "..");
const appDir = join(root, "apps/browser");
const rn = join(root, "node_modules/react-native-macos");
const hermesc = join(root, "node_modules/react-native/sdks/hermesc/osx-bin/hermesc");

const targetApp = resolve(process.env.TARGET_APP || (existsSync(resolve(root, "../apps/Ardia.app")) ? resolve(root, "../apps/Ardia.app") : "/Applications/Ardia.app"));
const bundleDest = join(targetApp, "Contents/Resources/main.jsbundle");
const backupDest = `${targetApp}.main.jsbundle.original`;

if (!existsSync(targetApp)) {
  console.error(`Target app not found: ${targetApp}`);
  process.exit(1);
}

const signature = spawnSync("codesign", ["--display", targetApp], { encoding: "utf8" });
const unsigned = !signature.error && signature.status === 1 && signature.stderr.trim() === `${targetApp}: code object is not signed at all`;
if (!unsigned) {
  console.error("Refusing to modify a signed app or an app whose signature could not be inspected. Set TARGET_APP to an unsigned development copy.");
  process.exit(1);
}

if (!existsSync(backupDest) && existsSync(bundleDest)) {
  try {
    copyFileSync(bundleDest, backupDest, constants.COPYFILE_EXCL);
    console.log(`Backed up original bundle to: ${backupDest}`);
  } catch (e) {
    if (e.code !== "EEXIST") throw e;
  }
}

const scratchDir = mkdtempSync(join(tmpdir(), "ardia-update-bundle-"));
const tmpJs = join(scratchDir, "main.js");
const tmpHbc = join(scratchDir, "main.hbc");
const tmpAssets = join(scratchDir, "assets");
const stagedBundle = join(dirname(bundleDest), `.main.jsbundle-${randomUUID()}.tmp`);

try {
  mkdirSync(tmpAssets);
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

  copyFileSync(tmpHbc, stagedBundle, constants.COPYFILE_EXCL);
  renameSync(stagedBundle, bundleDest);

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
