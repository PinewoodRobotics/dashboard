# PWRUP dashboards

pnpm workspace for FRC team PWRUP's driver station and pit software.

| Path | What it is |
|---|---|
| `apps/comp-godot` | Native competition dashboard (Godot 4.7.2): match HUD and touchscreen in one process, NetworkTables 4, 3D robot and field, realtime 3D auto previews. See [its README](apps/comp-godot/README.md). |
| `apps/comp` | The Electron/Next.js competition dashboard. Stays the primary dashboard until the Godot one passes its driver-station checklist. |
| `apps/admin` | Admin panel (Next.js + Electron). |
| `packages/shared-core` | NetworkTables connection layer shared by the web apps. |
| `packages/shared-proto` | Generated protobuf types for coprocessor messages (web apps only). |
| `packages/shared-ui` | Shared React UI components. |

## Web apps

Requires Node 20+ and pnpm.

```sh
pnpm install
pnpm dev:admin        # admin panel in Electron
pnpm dev:comp         # web comp dashboard in Electron
pnpm renderer:comp    # web comp dashboard renderer only, http://127.0.0.1:3001
pnpm build:admin      # Windows x64 unpacked build
pnpm dist:comp        # Windows x64 installer
```

## Godot comp dashboard

Requires Godot 4.7.2 on `PATH` as `godot`.

```sh
godot --path apps/comp-godot
godot --path apps/comp-godot -- --nt-host=127.0.0.1 --nt-port=5810   # against a local robot sim
```

Install, launch flags, tests, Windows export and the driver-station checklist
are in [apps/comp-godot/README.md](apps/comp-godot/README.md).

## PathPlanner autos

Both comp dashboards read autos synced from the robot repo
(`~/Developer/FIR/src/2026Rebuilt` by default):

```sh
pnpm sync:pathplanner:dry   # show what would change
pnpm sync:pathplanner       # copy paths and autos
```

The Godot dashboard also needs the precomputed trajectory export; the steps are
in its README under "PathPlanner autos".
