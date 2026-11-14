# 3D Robot and Field Asset Conventions

GLB inspection: covered separately in `glb_inventory.md`.

Codebase retrieval note: the Codebase Retrieval MCP was attempted first, per repo instructions, but returned HTTP 402. Manual repository traversal and exact-string search were used instead. No GLB binaries were opened or inspected, and `npx/gltf-transform` was not run.

## 1. `apps/comp/public/cad/robot-rig.json`

### File-level schema

- `version`: currently `1` (`apps/comp/public/cad/robot-rig.json:2`). The application does not branch on this value; no references beyond importing the JSON were found.
- `model`: `"cad/Robot-Full.glb"` (`apps/comp/public/cad/robot-rig.json:3`). `Robot3DTab` and `DriverTab` pass `"/" + rigConfig.model` to the robot viewers (`apps/comp/src/components/touchscreen/tabs/Robot3DTab.tsx:17`, `apps/comp/src/components/touchscreen/tabs/DriverTab.tsx:17`). The minimap does not use this field; it hardcodes `"/cad/Robot-Full.glb"` (`apps/comp/src/components/match/MiniMap3D.tsx:24-25`).
- `bumperNodes`: currently `["Plane"]` (`apps/comp/public/cad/robot-rig.json:4`). The renderers build a `Set` from this list and match it against exact GLB node names (`apps/comp/src/components/robot3d/RobotViewer.tsx:56-63`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:208-215`, `apps/comp/src/components/match/MiniMap3D.tsx:155`).
- `rootTransform`: currently `scale: [1,1,1]`, `position: [0,0,0]` (`apps/comp/public/cad/robot-rig.json:5-8`). NOT FOUND in consuming code. Searches for `rootTransform` only found this JSON definition. Runtime orientation is hardcoded as `clone.rotation.x = -Math.PI / 2` for robot CAD (`apps/comp/src/components/robot3d/RobotViewer.tsx:49-51`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:200-202`, `apps/comp/src/components/match/MiniMap3D.tsx:117-122`).

### Joint schema and semantics

The TypeScript type for rig joints is explicit:

- `nodeName`: exact node name from the GLB (`apps/comp/src/components/robot3d/useRobotJoints.ts:9-12`; rendered as `JointValue.nodeName`, `apps/comp/src/components/robot3d/useRobotJoints.ts:80-84`).
- `type`: `"revolute"` or `"prismatic"` (`apps/comp/src/components/robot3d/useRobotJoints.ts:9-12`).
- `axis`: `[number, number, number]` (`apps/comp/src/components/robot3d/useRobotJoints.ts:9-12`). Renderers normalize this vector before use (`apps/comp/src/components/robot3d/RobotViewer.tsx:102-105`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:310-313`, `apps/comp/src/components/match/MiniMap3D.tsx:242-245`).
- `limits`: `{ min, max }`; every live, manual, fallback, and linked value is clamped with `min <= value <= max` (`apps/comp/src/components/robot3d/useRobotJoints.ts:13`, `apps/comp/src/components/robot3d/useRobotJoints.ts:36-37`, `apps/comp/src/components/robot3d/useRobotJoints.ts:55`, `apps/comp/src/components/robot3d/useRobotJoints.ts:71`, `apps/comp/src/components/robot3d/useRobotJoints.ts:77`).
- `defaultValue`: optional fallback if no live NT value and no manual value exists (`apps/comp/src/components/robot3d/useRobotJoints.ts:14`, `apps/comp/src/components/robot3d/useRobotJoints.ts:70-71`).
- `ntTopic`: optional NetworkTables double topic (`apps/comp/src/components/robot3d/useRobotJoints.ts:16`, `apps/comp/src/components/robot3d/useRobotJoints.ts:110-116`, `apps/comp/src/components/robot3d/useRobotJoints.ts:196-202`).
- `inputWrap`: only supported value is `"signedUnitRotation"` (`apps/comp/src/components/robot3d/useRobotJoints.ts:19`). It maps a raw rotation value into `[-0.5, 0.5)` using `value - floor(value + 0.5)` (`apps/comp/src/components/robot3d/useRobotJoints.ts:40-48`).
- `inputTransform`: optional affine transform applied after `inputWrap`: `nextValue = nextValue * scale + offset` (`apps/comp/src/components/robot3d/useRobotJoints.ts:18`, `apps/comp/src/components/robot3d/useRobotJoints.ts:51-53`).
- `debugSlider`: optional UI slider definition. Joints with this field are `primaryJoints` (`apps/comp/src/components/robot3d/useRobotJoints.ts:32`) and are rendered in the Robot 3D tab with `min`, `max`, `step`, current value, NT status, and reset buttons (`apps/comp/src/components/touchscreen/tabs/Robot3DTab.tsx:20-73`).
- `link`: optional derived joint definition. Linked joints do not read NT or manual values directly; they use `sourceValue * scale + offset`, then clamp (`apps/comp/src/components/robot3d/useRobotJoints.ts:21`, `apps/comp/src/components/robot3d/useRobotJoints.ts:66-78`, `apps/comp/src/components/robot3d/useRobotJoints.ts:239-260`).

### Units and axis conventions

- Revolute joint values are radians; prismatic joint values are meters. This is documented on `JointValue.value` (`apps/comp/src/components/robot3d/RobotViewer.tsx:19-26`).
- Axes are local-space vectors (`apps/comp/src/components/robot3d/RobotViewer.tsx:19-24`). Revolute joints apply a local-axis quaternion by multiplying the rest quaternion by `setFromAxisAngle(axis, value)` (`apps/comp/src/components/robot3d/RobotViewer.tsx:108-110`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:316-318`, `apps/comp/src/components/match/MiniMap3D.tsx:248-250`).
- Prismatic joints apply local-axis translation by copying the rest position and adding `axis * value` (`apps/comp/src/components/robot3d/RobotViewer.tsx:111-112`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:319-320`, `apps/comp/src/components/match/MiniMap3D.tsx:251-252`).
- The robot GLB is treated as CAD Z-up. Standalone robot viewers rotate the cloned scene by `-pi/2` about X (`apps/comp/src/components/robot3d/RobotViewer.tsx:49-51`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:200-202`). The minimap puts the robot GLB inside a wrapper; the inner clone receives the same Z-up to Y-up rotation, while wrapper position and heading stay in field/world space (`apps/comp/src/components/match/MiniMap3D.tsx:63-67`, `apps/comp/src/components/match/MiniMap3D.tsx:117-122`, `apps/comp/src/components/match/MiniMap3D.tsx:225-233`).

### Current joints

| Key | Node | Type | Axis | Limits | Default | Input | Topic/link |
|---|---|---:|---:|---:|---:|---|---|
| `index_wrist` | `IndexWristRControl` | revolute | `[1,0,0]` | `[-2.22, 0.02]` | `0` | `value * -7.368421052631579 + 0.38842105263157894` | NT `/AdvantageKit/RealOutputs/IntakeSubsystem/WristPosition` (`apps/comp/public/cad/robot-rig.json:10-19`) |
| `turret` | `TurretRControl` | revolute | `[0,1,0]` | `[-3.14, 3.14]` | `0` | wrap signed unit rotation, then `value * -6.283185307179586 + 0` | NT `/AdvantageKit/RealOutputs/Turret/PositionRot` (`apps/comp/public/cad/robot-rig.json:21-31`) |
| `turret_gear` | `TurretGearRControl` | revolute | `[0,1,0]` | `[-3.14, 3.14]` | `0` | derived | link source `turret`, scale `-1`, offset `0` (`apps/comp/public/cad/robot-rig.json:33-40`) |
| `climber_inner` | `ClimberControlInner` | prismatic | `[0,0,1]` | `[-0.31, 0]` | `0` | `value * 0.9904153354632587 - 0.31` | NT `/AdvantageKit/RealOutputs/Climber/CurrentHeightMeters` (`apps/comp/public/cad/robot-rig.json:42-51`) |
| `climber_outer` | `ClimberControlOuter` | prismatic | `[0,0,1]` | `[-1.5, 1.5]` | `0` | derived | link source `climber_inner`, scale `-1`, offset `0` (`apps/comp/public/cad/robot-rig.json:53-60`) |

## 2. `apps/comp/src/components/robot3d/`

### GLB loading, cloning, scale, and orientation

- `RobotViewer.tsx`, `DriverRobotViewer.tsx`, and `MiniMap3D.tsx` all load GLBs with `GLTFLoader` and `DRACOLoader`; the Draco decoder path is `https://www.gstatic.com/draco/versioned/decoders/1.5.7/` (`apps/comp/src/components/robot3d/RobotViewer.tsx:15-17`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:17-19`, `apps/comp/src/components/match/MiniMap3D.tsx:27-29`).
- Loaded scenes are cloned with `gltf.scene.clone(true)` so cached GLTFs can be reused per instance (`apps/comp/src/components/robot3d/RobotViewer.tsx:44-49`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:196-201`, `apps/comp/src/components/match/MiniMap3D.tsx:73-79`).
- No runtime scale is applied to the robot model in these components. The only robot root transform found is the hardcoded X rotation. The `rootTransform.scale` and `rootTransform.position` fields are NOT FOUND in code usage.
- Standalone robot viewers add the rotated clone directly to the Three.js scene (`apps/comp/src/components/robot3d/RobotViewer.tsx:79-83`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:231-235`).
- The minimap wraps robot CAD in a `THREE.Group`; the inner clone gets `rotation.x = -pi/2`, while the wrapper receives field position and heading (`apps/comp/src/components/match/MiniMap3D.tsx:117-122`, `apps/comp/src/components/match/MiniMap3D.tsx:225-233`).

### Joint articulation

- Each cloned scene traversal caches `nodeMap`, rest quaternions, and rest positions by GLB node name (`apps/comp/src/components/robot3d/RobotViewer.tsx:52-61`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:204-213`, `apps/comp/src/components/match/MiniMap3D.tsx:80-89`).
- Every frame, each `JointValue` locates its node by exact `nodeName`; missing nodes are ignored (`apps/comp/src/components/robot3d/RobotViewer.tsx:92-100`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:296-308`, `apps/comp/src/components/match/MiniMap3D.tsx:233-240`).
- Revolute articulation: `node.quaternion = restQuat * quaternion(axis, value)` (`apps/comp/src/components/robot3d/RobotViewer.tsx:108-110`).
- Prismatic articulation: `node.position = restPosition + axis * value` (`apps/comp/src/components/robot3d/RobotViewer.tsx:111-112`).
- `useRobotJointsRef` is optimized for render-only views and updates a ref directly from NT callbacks without React rerenders (`apps/comp/src/components/robot3d/useRobotJoints.ts:92-127`). `useRobotJoints` also updates React state for debug UI (`apps/comp/src/components/robot3d/useRobotJoints.ts:155-217`).

### Alliance bumper colors

- Bumper red is `0xdd1111`; bumper blue is `0x1111dd` (`apps/comp/src/components/robot3d/RobotViewer.tsx:12-13`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:14-15`, `apps/comp/src/components/match/MiniMap3D.tsx:67-68`).
- When a mesh name is in `rigConfig.bumperNodes`, MeshStandardMaterial instances are cloned before recoloring so each model instance owns the material (`apps/comp/src/components/robot3d/RobotViewer.tsx:63-70`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:215-222`, `apps/comp/src/components/match/MiniMap3D.tsx:102-110`).
- If `isRedAlliance` is `null`, model colors are preserved (`apps/comp/src/components/robot3d/RobotViewer.tsx:85-89`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:265-270`, `apps/comp/src/components/match/MiniMap3D.tsx:159-163`).
- Alliance state comes from NT topic `/matchhud/state/is_red_alliance` and returns `null` when disconnected (`apps/comp/src/lib/match/constants.ts:37-41`, `apps/comp/src/lib/match/useMatchState.ts:74-80`).

### Camera, lighting, and viewing conventions

- `RobotViewer` uses a camera at `[1.5,1,1.5]`, `fov: 50`, `near: 0.01`, `far: 50`, OrbitControls damping `0.08`, distance `[0.2,6]`, and always renders (`apps/comp/src/components/robot3d/RobotViewer.tsx:34-41`, `apps/comp/src/components/robot3d/RobotViewer.tsx:127-140`).
- `RobotViewer` lighting: ambient `0.7`, directional `[4,8,4]` intensity `1.2`, directional `[-4,2,-4]` intensity `0.3`, plus a `gridHelper` of size `3`, divisions `30`, colors `#333` and `#222` (`apps/comp/src/components/robot3d/RobotViewer.tsx:117-123`).
- `DriverRobotViewer` uses `camera-poses.json` for initial camera position/fov and numbered state transitions (`apps/comp/src/components/robot3d/DriverRobotViewer.tsx:10`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:138-142`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:282-290`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:416-430`).
- `DriverRobotViewer` OrbitControls: pan disabled, damping `0.08`, rotate speed `0.5`, zoom speed `0.8`, polar angle `[0.1, pi/2 - 0.05]`, distance `[0.5,4]` (`apps/comp/src/components/robot3d/DriverRobotViewer.tsx:24-33`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:145-157`).
- `DriverRobotViewer` transitions use spherical interpolation around target, shortest-path angle interpolation, ease-out cubic, 400 ms state transitions, 1000 ms idle timeout, and 600 ms idle return (`apps/comp/src/components/robot3d/DriverRobotViewer.tsx:24-39`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:237-263`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:324-385`).
- `DriverRobotViewer` lighting: ambient `0.3`, directional `[5,8,5]` intensity `1.0`, directional `[-3,4,-2]` intensity `0.4`, spot `[0,6,0]`, angle `0.6`, penumbra `1`, intensity `0.5` (`apps/comp/src/components/robot3d/DriverRobotViewer.tsx:387-394`).
- Minimap camera defaults to `[0,8,0]`, `fov: 50`, `near: 0.1`, `far: 100`, then is positioned every frame by spherical controls around the robot/field (`apps/comp/src/components/match/MiniMap3D.tsx:391-396`, `apps/comp/src/components/match/MiniMap3D.tsx:267-302`).

### WPILib field frame to Three.js world transform

Runtime transform in the minimap:

- `HALF_W = 8.27`, `HALF_H = 4.105` (`apps/comp/src/components/match/MiniMap3D.tsx:166-171`).
- Pose topics are initialized to center `{ x: 8.27, y: 4.105, heading: 0 }` (`apps/comp/src/components/match/MiniMap3D.tsx:325-327`).
- Three.js robot world X is `HALF_W - poseX`; Three.js robot world Z is `poseY - HALF_H` (`apps/comp/src/components/match/MiniMap3D.tsx:221-223`).
- World Y is vertical, and wrapper position is `[robotWorldX, 0, robotWorldZ]` (`apps/comp/src/components/match/MiniMap3D.tsx:225-228`).
- Heading convention in comments: WPILib 2026 heading is CCW-positive, `0` faces `+poseX` toward the blue wall; model default forward is `+worldZ`; wrapper heading is `heading - pi/2` (`apps/comp/src/components/match/MiniMap3D.tsx:166-169`, `apps/comp/src/components/match/MiniMap3D.tsx:225-230`).
- Pose topics consumed: `/matchhud/state/robot_pose_x_m`, `/matchhud/state/robot_pose_y_m`, `/matchhud/state/robot_heading_rad` (`apps/comp/src/lib/match/constants.ts:54-56`, `apps/comp/src/components/match/MiniMap3D.tsx:347-349`).

## 3. `apps/comp/public/cad/field-meta.json`

### Metadata summary

- `name`: `"2026 Field"` (`apps/comp/public/cad/field-meta.json:2`).
- `isFTC`: `false` (`apps/comp/public/cad/field-meta.json:3`).
- `coordinateSystem`: `"wall-blue"` (`apps/comp/public/cad/field-meta.json:4`).
- Field model rotations metadata: one rotation, axis `x`, degrees `90` (`apps/comp/public/cad/field-meta.json:5-10`). Runtime code does not consume this field. The minimap comment says the AdvantageScope field model is already Y-up (`apps/comp/src/components/match/MiniMap3D.tsx:117`).
- Dimensions: `widthInches: 651.220`, `heightInches: 317.677` (`apps/comp/public/cad/field-meta.json:11-12`). Converted exactly, these are `16.540988 m` by `8.0689958 m`. Runtime constants elsewhere use `FIELD_WIDTH_M = 16.54`, `FIELD_HEIGHT_M = 8.21` (`apps/comp/src/lib/match/constants.ts:70-72`), while minimap uses half extents `8.27` and `4.105` (`apps/comp/src/components/match/MiniMap3D.tsx:166-171`).

### Driver stations

Six driver station coordinates are present (`apps/comp/public/cad/field-meta.json:13-38`):

| Index | Position |
|---:|---:|
| 1 | `[8.2775425, -3.07975]` (`apps/comp/public/cad/field-meta.json:14-17`) |
| 2 | `[8.2775425, -1.25095]` (`apps/comp/public/cad/field-meta.json:18-21`) |
| 3 | `[8.2775425, 1.8288]` (`apps/comp/public/cad/field-meta.json:22-25`) |
| 4 | `[-8.2775425, 3.07975]` (`apps/comp/public/cad/field-meta.json:26-29`) |
| 5 | `[-8.2775425, 1.25095]` (`apps/comp/public/cad/field-meta.json:30-33`) |
| 6 | `[-8.2775425, -1.8288]` (`apps/comp/public/cad/field-meta.json:34-37`) |

Runtime consumption: NOT FOUND. Searches for `driverStations` found only the JSON copies.

### AprilTag poses

All AprilTags use variant `"36h11-6.5in"` (`apps/comp/public/cad/field-meta.json:41`, repeated through the tag list).

| ID | Rotation(s) | Position | Citation |
|---:|---|---|---|
| 1 | `z 0.0 deg` | `[-3.607, -3.39, 0.889]` | `apps/comp/public/cad/field-meta.json:40-54` |
| 2 | `z 270.0 deg` | `[-3.645, -0.604, 1.124]` | `apps/comp/public/cad/field-meta.json:55-69` |
| 3 | `z 0.0 deg` | `[-3.041, -0.356, 1.124]` | `apps/comp/public/cad/field-meta.json:70-84` |
| 4 | `z 0.0 deg` | `[-3.041, -0.0, 1.124]` | `apps/comp/public/cad/field-meta.json:85-99` |
| 5 | `z 90.0 deg` | `[-3.645, 0.604, 1.124]` | `apps/comp/public/cad/field-meta.json:100-114` |
| 6 | `z 0.0 deg` | `[-3.607, 3.39, 0.889]` | `apps/comp/public/cad/field-meta.json:115-129` |
| 7 | `z 180.0 deg` | `[-3.683, 3.39, 0.889]` | `apps/comp/public/cad/field-meta.json:130-144` |
| 8 | `z 90.0 deg` | `[-4.001, 0.604, 1.124]` | `apps/comp/public/cad/field-meta.json:145-159` |
| 9 | `z 180.0 deg` | `[-4.249, 0.355, 1.124]` | `apps/comp/public/cad/field-meta.json:160-174` |
| 10 | `z 180.0 deg` | `[-4.249, -0.0, 1.124]` | `apps/comp/public/cad/field-meta.json:175-189` |
| 11 | `z 270.0 deg` | `[-4.001, -0.604, 1.124]` | `apps/comp/public/cad/field-meta.json:190-204` |
| 12 | `z 180.0 deg` | `[-3.683, -3.39, 0.889]` | `apps/comp/public/cad/field-meta.json:205-219` |
| 13 | `z 0.0 deg` | `[-8.262, -3.369, 0.552]` | `apps/comp/public/cad/field-meta.json:220-234` |
| 14 | `z 0.0 deg` | `[-8.262, -2.937, 0.552]` | `apps/comp/public/cad/field-meta.json:235-249` |
| 15 | `z 0.0 deg` | `[-8.262, -0.289, 0.552]` | `apps/comp/public/cad/field-meta.json:250-264` |
| 16 | `z 0.0 deg` | `[-8.262, 0.143, 0.552]` | `apps/comp/public/cad/field-meta.json:265-279` |
| 17 | `z 180.0 deg` | `[3.607, 3.39, 0.889]` | `apps/comp/public/cad/field-meta.json:280-294` |
| 18 | `z 90.0 deg` | `[3.645, 0.604, 1.124]` | `apps/comp/public/cad/field-meta.json:295-309` |
| 19 | `z 180.0 deg` | `[3.041, 0.355, 1.124]` | `apps/comp/public/cad/field-meta.json:310-324` |
| 20 | `z 180.0 deg` | `[3.041, -0.0, 1.124]` | `apps/comp/public/cad/field-meta.json:325-339` |
| 21 | `z 270.0 deg` | `[3.645, -0.604, 1.124]` | `apps/comp/public/cad/field-meta.json:340-354` |
| 22 | `z 180.0 deg` | `[3.607, -3.39, 0.889]` | `apps/comp/public/cad/field-meta.json:355-369` |
| 23 | `z 0.0 deg` | `[3.683, -3.39, 0.889]` | `apps/comp/public/cad/field-meta.json:370-384` |
| 24 | `z 270.0 deg` | `[4.0, -0.604, 1.124]` | `apps/comp/public/cad/field-meta.json:385-399` |
| 25 | `z 0.0 deg` | `[4.249, -0.356, 1.124]` | `apps/comp/public/cad/field-meta.json:400-414` |
| 26 | `z 0.0 deg` | `[4.249, -0.0, 1.124]` | `apps/comp/public/cad/field-meta.json:415-429` |
| 27 | `z 90.0 deg` | `[4.0, 0.604, 1.124]` | `apps/comp/public/cad/field-meta.json:430-444` |
| 28 | `z 0.0 deg` | `[3.683, 3.39, 0.889]` | `apps/comp/public/cad/field-meta.json:445-459` |
| 29 | `z 180.0 deg` | `[8.262, 3.369, 0.552]` | `apps/comp/public/cad/field-meta.json:460-474` |
| 30 | `z 180.0 deg` | `[8.262, 2.937, 0.552]` | `apps/comp/public/cad/field-meta.json:475-489` |
| 31 | `z 180.0 deg` | `[8.262, 0.289, 0.552]` | `apps/comp/public/cad/field-meta.json:490-504` |
| 32 | `z 180.0 deg` | `[8.262, -0.143, 0.552]` | `apps/comp/public/cad/field-meta.json:505-519` |

Runtime consumption: NOT FOUND. Searches for `aprilTags` found only the JSON copies and protobuf message names unrelated to this metadata.

### Game pieces

- One game piece entry exists: `name: "Fuel"`, `rotations: []`, `position: [0,0,0]` (`apps/comp/public/cad/field-meta.json:521-529`).
- `stagedObjects` contains GLB node names `GE-26900_Fuel` through `GE-26900_Fuel_455` (`apps/comp/public/cad/field-meta.json:530-986`).
- Runtime consumption: the minimap flattens all `fieldMeta.gamePieces[].stagedObjects` into `GAME_PIECE_NODES` and hides matching field GLB nodes by setting `obj.visible = false` (`apps/comp/src/components/match/MiniMap3D.tsx:18-21`, `apps/comp/src/components/match/MiniMap3D.tsx:123-127`).

## 4. `apps/comp/public/cad/camera-poses.json`

### Confirmed use: orbit-viewer presets, not robot camera mounts

`camera-poses.json` contains viewer camera presets:

- `version: 1` (`apps/comp/public/cad/camera-poses.json:2`).
- Initial viewer pose: `position [1.38,0.45,1.38]`, `target [0,0.25,0]`, `fov 50` (`apps/comp/public/cad/camera-poses.json:3-7`).
- State 0 `"Overview"`: `position [1.38,0.45,1.38]`, `target [0,0.25,0]`, `fov 50` (`apps/comp/public/cad/camera-poses.json:8-14`).
- State 1 `"Intake"`: `position [0.23,0.25,1.23]`, `target [0,0.15,0.3]`, `fov 50` (`apps/comp/public/cad/camera-poses.json:15-20`).
- State 2 `"Turret"`: `position [-0.92,0.6,0.62]`, `target [0,0.4,0]`, `fov 50` (`apps/comp/public/cad/camera-poses.json:21-26`).
- State 3 `"Side"`: `position [1.54,0.2,0]`, `target [0,0.25,0]`, `fov 50` (`apps/comp/public/cad/camera-poses.json:27-32`).

The only import of `camera-poses.json` in `apps/comp` is `DriverRobotViewer.tsx` (`apps/comp/src/components/robot3d/DriverRobotViewer.tsx:10`). That component uses the values as Three.js camera `position`, OrbitControls `target`, and perspective `fov` for visual state buttons (`apps/comp/src/components/robot3d/DriverRobotViewer.tsx:138-142`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:158-160`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:282-290`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:416-430`). The buttons simply select indices `0..3` (`apps/comp/src/components/touchscreen/tabs/DriverTab.tsx:24-39`).

### Robot camera mount extrinsics

NOT FOUND. Searches covered `apps/comp/src`, `apps/comp/public/cad`, `apps/comp/electron`, and repo-wide non-GLB files for `extrinsic`, `intrinsic`, `mount`, `robotToCamera`, `cameraToRobot`, `Transform3d`, `Pose3d`, `camera-poses`, `field-meta`, `aprilTags`, and related transform terms. The only camera-related runtime data found is:

- HUD camera video topic string `/matchhud/state/camera_topic` (`apps/comp/src/lib/match/constants.ts:63`, `apps/comp/src/lib/match/useMatchState.ts:190-194`).
- Default Autobahn video topic `"camera/front_left/video"` for the auto-align overlay (`apps/comp/src/lib/match/constants.ts:83-84`, `apps/comp/src/lib/match/useAutoAlignCamera.ts:27-31`).
- Decoded video image payloads drawn to a canvas; no pose/extrinsic data is used (`apps/comp/src/lib/match/useAutoAlignCamera.ts:36-43`, `apps/comp/src/lib/match/useAutoAlignCamera.ts:82-94`).

## 5. Field GLB and robot GLB relationship

- Field URL in minimap: `"/cad/field-2026.glb?v=2"` (`apps/comp/src/components/match/MiniMap3D.tsx:24`).
- Robot URL in minimap: `"/cad/Robot-Full.glb"` (`apps/comp/src/components/match/MiniMap3D.tsx:25`).
- Visual settings cache refresh fetches both `"/cad/Robot-Full.glb"` and `"/cad/field-2026.glb?v=2"` (`apps/comp/src/components/touchscreen/tabs/VisualTab.tsx:9`, `apps/comp/src/components/touchscreen/tabs/VisualTab.tsx:47-53`).
- Field GLB is loaded as static scene with no wrapper and no runtime orientation transform; game piece nodes from `field-meta.json` are hidden (`apps/comp/src/components/match/MiniMap3D.tsx:117-127`, `apps/comp/src/components/match/MiniMap3D.tsx:151-155`).
- Robot GLB is loaded separately, wrapped, Z-up to Y-up rotated internally, then positioned over the field using live NT pose topics (`apps/comp/src/components/match/MiniMap3D.tsx:151-155`, `apps/comp/src/components/match/MiniMap3D.tsx:221-230`, `apps/comp/src/components/match/MiniMap3D.tsx:347-349`).
- Alliance-colored duplication: there is no separate red/blue robot GLB. The same robot model is instanced/cloned and bumper materials are recolored at runtime from `isRedAlliance` (`apps/comp/src/components/match/MiniMap3D.tsx:102-110`, `apps/comp/src/components/match/MiniMap3D.tsx:159-164`).
- Multiple robot placement: NOT FOUND. The minimap renders one robot driven by `/matchhud/state/robot_pose_x_m`, `/matchhud/state/robot_pose_y_m`, and `/matchhud/state/robot_heading_rad` (`apps/comp/src/components/match/MiniMap3D.tsx:317-363`). No code was found that positions alliance partners/opponents or duplicates robot models on the field.

## 6. Other simulator-reuse details

### Color palette

- Bumper red/blue: `0xdd1111`, `0x1111dd` (`apps/comp/src/components/robot3d/RobotViewer.tsx:12-13`).
- HUD colors: green `#70cd35`, orange `#ff9d00`, yellow `#ffd900` (`apps/comp/src/lib/match/constants.ts:78-81`).
- Auto-align close-distance red uses `#ef4444` (`apps/comp/src/components/match/CameraOverlay.tsx:29-37`).
- Visual settings page uses dark gray `#272727` and green `#70cd35` for controls (`apps/comp/src/components/touchscreen/tabs/VisualTab.tsx:75-98`).

### HUD and map conventions

- Match timing constants: auto `20 s`, teleop `140 s`, total `160 s`; teleop transition ends at `130`, shifts end at `105`, `80`, `55`, `30`, and endgame at `0` (`apps/comp/src/lib/match/constants.ts:1-26`).
- Hub manual scoring buffer is `3 s`; each alliance shift is `25 s` (`apps/comp/src/lib/match/constants.ts:28-32`).
- Match phase integer mapping: `0 pre_match`, `1 autonomous`, `2 transition`, `3 shift1`, `4 shift2`, `5 shift3`, `6 shift4`, `7 endgame`, `8 post_match` (`apps/comp/src/lib/match/useMatchState.ts:8-30`).
- Hub status integer mapping: `0 none`, `1 both`, `2 active`, `3 warning`, `4 inactive` (`apps/comp/src/lib/match/useMatchState.ts:32-46`).
- Header color integer mapping: `0 hidden`, `1 green`, `2 yellow`, `3 purple` (`apps/comp/src/lib/match/useMatchState.ts:48-60`).
- Aim mode integer mapping: `0 shooter_disabled`, `1 gps_auto`, `2 manual_aiming` (`apps/comp/src/lib/match/useMatchState.ts:62-72`).
- Minimap display constants: `MINIMAP_W = 840`, `MINIMAP_H = 600` (`apps/comp/src/lib/match/constants.ts:74-76`). The actual CSS placement is fixed: left `28.125vw`, top `44.44vh`, width `43.75vw`, bottom `-1vw`, rounded top corners `30% 30% 0 0`, inset vignette `inset 0 0 5vw 3.5vw black` (`apps/comp/src/components/match/MiniMap3D.tsx:366-412`).
- Minimap camera settings: `ZOOM_NEAR = 2`, `ZOOM_FAR = 11.05`, `POLAR_TOP = 0.08`, `POLAR_LOW = 1.35`, position lerp `0.15`, theta lerp `0.10` (`apps/comp/src/components/match/MiniMap3D.tsx:34-44`).
- Minimap pose smoothing: teleport threshold `1.5 m`, minimum lerp `0.15`, distance scale `1.4`; heading uses shortest-path angular lerp (`apps/comp/src/components/match/MiniMap3D.tsx:200-219`).

### Telemetry topics consumed for simulator parity

Joint topics, all subscribed as NT doubles:

- `/AdvantageKit/RealOutputs/IntakeSubsystem/WristPosition` (`apps/comp/public/cad/robot-rig.json:16`, `apps/comp/src/components/robot3d/useRobotJoints.ts:110-120`).
- `/AdvantageKit/RealOutputs/Turret/PositionRot` (`apps/comp/public/cad/robot-rig.json:27`, `apps/comp/src/components/robot3d/useRobotJoints.ts:110-120`).
- `/AdvantageKit/RealOutputs/Climber/CurrentHeightMeters` (`apps/comp/public/cad/robot-rig.json:48`, `apps/comp/src/components/robot3d/useRobotJoints.ts:110-120`).

Match/HUD topics:

- Root is `/matchhud/state` (`apps/comp/src/lib/match/constants.ts:34-35`).
- Sequence, connection, alliance, enabled/autonomous, game-specific message, phase, hub status, header color, timers, shift/buffer flags, robot pose, auto-align, driver override, aim mode, and camera topic are enumerated in `NT` (`apps/comp/src/lib/match/constants.ts:37-64`).
- `useMatchState` subscribes with explicit NT types: booleans for alliance/enabled/autonomous/show flags/auto-align ready/driver override; integers for sequence/phase/hub/header/aim mode; doubles for time, pose-adjacent values, and distances; strings for game-specific message and camera topic (`apps/comp/src/lib/match/useMatchState.ts:83-194`).
- Minimap pose subscriptions use only `MATCH_HUD_POSE_X`, `MATCH_HUD_POSE_Y`, and `MATCH_HUD_HEADING` (`apps/comp/src/components/match/MiniMap3D.tsx:335-349`).
- Auto-align camera overlay consumes decoded image payloads from the selected HUD camera topic or default `"camera/front_left/video"` (`apps/comp/src/components/match/CameraOverlay.tsx:46-50`, `apps/comp/src/lib/match/useAutoAlignCamera.ts:27-31`).

### Render/material conventions

- Minimap material normalization: for all loaded meshes, MeshStandardMaterial `metalness = 0`, `roughness = 1`; transparent materials set `depthWrite = false` (`apps/comp/src/components/match/MiniMap3D.tsx:91-101`).
- Canvas DPR is `visualSettings.renderScale * window.devicePixelRatio` in robot viewers and minimap (`apps/comp/src/components/robot3d/RobotViewer.tsx:130-135`, `apps/comp/src/components/robot3d/DriverRobotViewer.tsx:416-426`, `apps/comp/src/components/match/MiniMap3D.tsx:391-396`).
- Minimap can enable `logarithmicDepthBuffer` from visual settings (`apps/comp/src/components/match/MiniMap3D.tsx:391-394`). Visual settings expose `logarithmicDepthBuffer`, `backdropBlur`, and `renderScale` (`apps/comp/src/components/touchscreen/tabs/VisualTab.tsx:60-68`, `apps/comp/src/components/touchscreen/tabs/VisualTab.tsx:99-118`).
