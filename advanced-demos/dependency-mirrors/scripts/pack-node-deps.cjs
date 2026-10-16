const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const project = process.argv[2];
const destination = process.argv[3];
const cache = process.argv[4];
const listing = spawnSync("npm", ["ls", "--all", "--parseable", "--omit=dev"], {
  cwd: project,
  encoding: "utf8",
});

if (listing.status !== 0) {
  process.stderr.write(listing.stderr);
  process.exit(listing.status || 1);
}

const lockfile = JSON.parse(
  fs.readFileSync(path.join(project, "package-lock.json"), "utf8"),
);
const locked = new Map();
for (const [key, dependency] of Object.entries(lockfile.packages)) {
  const name = key.split("node_modules/").at(-1);
  if (name && dependency.version && dependency.resolved) {
    locked.set(`${name}@${dependency.version}`, dependency.resolved);
  }
}

const published = new Set();
for (const directory of listing.stdout.trim().split(/\r?\n/).slice(1)) {
  const manifest = path.join(directory, "package.json");
  if (!fs.existsSync(manifest)) continue;

  const { name, version } = JSON.parse(fs.readFileSync(manifest, "utf8"));
  if (!name || !version || published.has(`${name}@${version}`)) continue;
  const resolved = locked.get(`${name}@${version}`);
  if (!resolved) {
    console.error(`No lockfile tarball URL found for ${name}@${version}`);
    process.exit(1);
  }

  const result = spawnSync(
    "npm",
    [
      "pack",
      resolved,
      "--offline",
      "--cache",
      cache,
      "--pack-destination",
      destination,
      "--ignore-scripts",
    ],
    { cwd: project, stdio: "ignore" },
  );
  if (result.status !== 0) {
    console.error(`npm pack failed for ${name}@${version}`);
    process.exit(result.status || 1);
  }
  published.add(`${name}@${version}`);
}

if (published.size === 0) {
  console.error("No installed npm dependencies were found to seed Verdaccio.");
  process.exit(1);
}
console.log(`Packed ${published.size} lockfile tarballs for Verdaccio from npm's cache.`);
