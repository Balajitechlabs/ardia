import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, statSync, unlinkSync, mkdirSync } from "node:fs";
import { resolve, join } from "node:path";

const root = resolve(import.meta.dirname, "..");
const appDir = join(root, "apps/browser");
const rn = join(root, "node_modules/react-native-macos");
const hermesc = join(root, "node_modules/react-native/sdks/hermesc/osx-bin/hermesc");

const targetApp = process.env.TARGET_APP || (existsSync(resolve(root, "../apps/Ardia.app")) ? resolve(root, "../apps/Ardia.app") : "/Applications/Ardia.app");
const bundleDest = join(targetApp, "Contents/Resources/main.jsbundle");
const backupDest = join(targetApp, "Contents/Resources/main.jsbundle.original");

if (!existsSync(targetApp)) {
  console.error(`Target app not found: ${targetApp}`);
  process.exit(1);
}

if (!existsSync(backupDest) && existsSync(bundleDest)) {
  copyFileSync(bundleDest, backupDest);
  console.log(`Backed up original bundle to: ${backupDest}`);
}

const tmpJs = "/tmp/ardia-main.js";
const tmpHbc = "/tmp/ardia-main.hbc";
const tmpAssets = "/tmp/ardia-assets";
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

try {
  try { unlinkSync(bundleDest); } catch {}
  copyFileSync(tmpHbc, bundleDest);
} catch (e) {
  if (e.code === "EBUSY" || e.code === "EPERM" || String(e).includes("permitted")) {
    console.error("\n [!] Ardia is currently running or locked. Please quit Ardia (⌘Q) and try again.\n");
    process.exit(1);
  }
  throw e;
}

try { unlinkSync(tmpJs); unlinkSync(tmpHbc); } catch {}

const sizeMb = (statSync(bundleDest).size / (1024 * 1024)).toFixed(2);
console.log(`\n Successfully updated ${targetApp}!`);
console.log(` Bundle size: ${sizeMb} MB`);
console.log(` Test with: open -a "${targetApp}" "https://news.ycombinator.com"\n`);
