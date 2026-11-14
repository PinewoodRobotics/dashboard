// Copies the lucide SVGs the app uses into ui/icons/lucide.json.
// Usage (from this directory): npm ci && node build_icons.mjs
import { readFileSync, writeFileSync, copyFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const app = join(here, "..", "..");
const pkgDir = join(here, "node_modules", "lucide-static");
const version = JSON.parse(readFileSync(join(pkgDir, "package.json"), "utf8")).version;

const ICONS = [
  "circle-minus",
  "scan-eye",
  "circle-gauge",
  "gamepad-2",
];

const icons = {};
for (const name of [...ICONS].sort()) {
  const svg = readFileSync(join(pkgDir, "icons", `${name}.svg`), "utf8")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/\s*class="[^"]*"/, "")
    .replace(/\s+/g, " ")
    .replace(/> </g, "><")
    .trim();
  if (!svg.includes('viewBox="0 0 24 24"') || !svg.includes("currentColor")) {
    throw new Error(`unexpected lucide SVG shape: ${name}`);
  }
  icons[name] = svg;
}

const out = { source: "lucide-static", version, license: "ISC", icons };
writeFileSync(join(app, "ui", "icons", "lucide.json"), JSON.stringify(out, null, 2) + "\n");
copyFileSync(join(pkgDir, "LICENSE"), join(app, "ui", "icons", "LICENSE-lucide.txt"));
console.log(`wrote ${Object.keys(icons).length} icons from lucide-static ${version}`);
