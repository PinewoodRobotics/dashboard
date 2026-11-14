#!/usr/bin/env node
// Builds assets/models/{robot,field}.glb, their light variants
// {robot,field}-lite.glb (what auto quality swaps in on a GPU that cannot hold
// the frame rate) and models.manifest.json from the raw CAD exports in
// apps/comp/cad-assets (read in place, never modified).
//
// Usage (from apps/comp-godot/tools/assets, after `npm ci`):
//   node build_models.mjs                 build both models, exit 1 if a budget is exceeded
//   node build_models.mjs --reference DIR also write unsimplified plain GLBs into DIR (for review)
//   node build_models.mjs --check         rebuild in memory and fail if the committed outputs differ

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Document, NodeIO } from '@gltf-transform/core';
import { KHRDracoMeshCompression, KHRMeshQuantization } from '@gltf-transform/extensions';
import { dequantize } from '@gltf-transform/functions';
import draco3d from 'draco3dgltf';
import { MeshoptSimplifier } from 'meshoptimizer';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const APP = path.resolve(HERE, '../..');
const SRC_DIR = path.resolve(APP, '../comp/cad-assets');
const OUT_DIR = path.join(APP, 'assets/models');
const GENERATOR = 'comp-godot build_models.mjs';

const ROBOT = {
  source: 'Robot-Full.glb',
  output: 'robot.glb',
  root: 'Bumper',
  bumperMesh: 'Plane',
  bumperNode: 'BumperPlane',
  anchors: ['IndexWristRControl', 'TurretRControl', 'TurretGearRControl', 'ClimberControlInner', 'ClimberControlOuter', 'FrameControl'],
  // Error is the absolute meshopt error in meters; it grows by ERROR_GROWTH
  // until the anchor fits its triangle target. minPart drops whole parts whose
  // bounding-box diagonal is below it (fasteners, washers, inserts).
  simplify: {
    FrameControl: { target: 116000, budget: 130000, error: 0.001, minPart: 0.018 },
    IndexWristRControl: { target: 31000, budget: 35000, error: 0.0003, minPart: 0.012 },
    ClimberControlInner: { target: 27000, budget: 30000, error: 0.0003, minPart: 0.015 },
    ClimberControlOuter: { target: 13500, budget: 15000, error: 0.0003, minPart: 0.012 },
    TurretRControl: { target: Infinity, budget: Infinity, error: 0, minPart: 0 },
    TurretGearRControl: { target: Infinity, budget: Infinity, error: 0, minPart: 0 },
  },
  budget: { triangles: 220000, surfaces: 10, bytes: 9 * 1024 * 1024 },
};

const ROBOT_LITE = {
  ...ROBOT,
  output: 'robot-lite.glb',
  simplify: {
    FrameControl: { target: 24000, budget: 26000, error: 0.002, minPart: 0.04 },
    IndexWristRControl: { target: 6000, budget: 7000, error: 0.001, minPart: 0.03 },
    ClimberControlInner: { target: 5000, budget: 6000, error: 0.001, minPart: 0.03 },
    ClimberControlOuter: { target: 3000, budget: 3500, error: 0.001, minPart: 0.03 },
    TurretRControl: { target: 5000, budget: 6000, error: 0.0005, minPart: 0.02 },
    TurretGearRControl: { target: 2500, budget: 3000, error: 0.0005, minPart: 0.02 },
  },
  budget: { triangles: 50000, surfaces: 10, bytes: 2 * 1024 * 1024 },
};

const FIELD = {
  source: 'field-2026.glb',
  output: 'field.glb',
  dropPrefix: 'GE-26900',
  simplify: { target: 110000, budget: 120000, error: 0.002, minPart: 0.03 },
  budget: { triangles: 120000, surfaces: 6, bytes: 5 * 1024 * 1024 },
};

const FIELD_LITE = {
  ...FIELD,
  output: 'field-lite.glb',
  simplify: { target: 25000, budget: 28000, error: 0.006, minPart: 0.08 },
  budget: { triangles: 28000, surfaces: 6, bytes: 1536 * 1024 },
};

const ERROR_GROWTH = 1.2;
const MAX_PASSES = 24;
const BISECT_STEPS = 5;


function mul(a, b) {
  const o = new Array(16).fill(0);
  for (let c = 0; c < 4; c++)
    for (let r = 0; r < 4; r++) {
      let s = 0;
      for (let k = 0; k < 4; k++) s += a[k * 4 + r] * b[c * 4 + k];
      o[c * 4 + r] = s;
    }
  return o;
}

function invert(m) {
  const inv = new Array(16);
  inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
  inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
  inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
  inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
  inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
  inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
  inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
  inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
  inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
  inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
  inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
  inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
  inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
  inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
  inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
  inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];
  const det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
  return inv.map((v) => v / det);
}

function det3(m) {
  return m[0] * (m[5] * m[10] - m[9] * m[6]) - m[4] * (m[1] * m[10] - m[9] * m[2]) + m[8] * (m[1] * m[6] - m[5] * m[2]);
}

function maxScale(m) {
  const s = (i) => Math.hypot(m[i], m[i + 1], m[i + 2]);
  return Math.max(s(0), s(4), s(8));
}


async function makeIO() {
  return new NodeIO()
    .registerExtensions([KHRDracoMeshCompression, KHRMeshQuantization])
    .registerDependencies({ 'draco3d.decoder': await draco3d.createDecoderModule() });
}

function sha256(file) {
  return createHash('sha256').update(readFileSync(file)).digest('hex');
}

function materialColor(material) {
  if (!material) return { rgba: [0.8, 0.8, 0.8, 1], blend: false };
  const c = material.getBaseColorFactor();
  return { rgba: [c[0], c[1], c[2], c[3]], blend: material.getAlphaMode() === 'BLEND' };
}

function primitiveGeometry(prim) {
  if (prim.getMode() !== 4) return null;
  const pos = prim.getAttribute('POSITION');
  if (!pos) return null;
  const nrm = prim.getAttribute('NORMAL');
  const idxAcc = prim.getIndices();
  const count = pos.getCount();
  const positions = new Float32Array(count * 3);
  const normals = new Float32Array(count * 3);
  const el = [0, 0, 0];
  for (let i = 0; i < count; i++) {
    pos.getElement(i, el);
    positions.set(el, i * 3);
    if (nrm) {
      nrm.getElement(i, el);
      normals.set(el, i * 3);
    }
  }
  let indices;
  if (idxAcc) indices = Uint32Array.from(idxAcc.getArray());
  else indices = Uint32Array.from({ length: count }, (_, i) => i);
  if (!nrm) computeNormals(positions, indices, normals);
  return { positions, normals, indices };
}

function computeNormals(positions, indices, normals) {
  normals.fill(0);
  for (let t = 0; t < indices.length; t += 3) {
    const a = indices[t] * 3, b = indices[t + 1] * 3, c = indices[t + 2] * 3;
    const ux = positions[b] - positions[a], uy = positions[b + 1] - positions[a + 1], uz = positions[b + 2] - positions[a + 2];
    const vx = positions[c] - positions[a], vy = positions[c + 1] - positions[a + 1], vz = positions[c + 2] - positions[a + 2];
    const nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    for (const v of [a, b, c]) {
      normals[v] += nx;
      normals[v + 1] += ny;
      normals[v + 2] += nz;
    }
  }
  for (let i = 0; i < normals.length; i += 3) {
    const l = Math.hypot(normals[i], normals[i + 1], normals[i + 2]) || 1;
    normals[i] /= l;
    normals[i + 1] /= l;
    normals[i + 2] /= l;
  }
}

function collectParts(top, frameWorld, skip) {
  const inv = invert(frameWorld);
  const parts = [];
  const visit = (node) => {
    if (skip && skip(node)) return;
    const mesh = node.getMesh();
    if (mesh) {
      const rel = mul(inv, node.getWorldMatrix());
      for (const prim of mesh.listPrimitives()) parts.push({ node, prim, matrix: rel });
    }
    for (const child of node.listChildren()) visit(child);
  };
  visit(top);
  return parts;
}


const geomCache = new Map();
function geometryOf(prim) {
  let g = geomCache.get(prim);
  if (g === undefined) {
    g = primitiveGeometry(prim);
    geomCache.set(prim, g);
  }
  return g;
}

const simplifyCache = new Map();
function simplifiedIndices(prim, geom, errorLocal) {
  if (errorLocal <= 0) return geom.indices;
  let byErr = simplifyCache.get(prim);
  if (!byErr) {
    byErr = new Map();
    simplifyCache.set(prim, byErr);
  }
  const key = errorLocal.toPrecision(8);
  let out = byErr.get(key);
  if (!out) {
    [out] = MeshoptSimplifier.simplify(geom.indices, geom.positions, 3, 0, errorLocal, ['ErrorAbsolute', 'Prune', 'Permissive']);
    byErr.set(key, out);
  }
  return out;
}

function partBounds(geom, m) {
  const min = [Infinity, Infinity, Infinity];
  const max = [-Infinity, -Infinity, -Infinity];
  const p = geom.positions;
  for (let i = 0; i < p.length; i += 3) {
    const x = p[i], y = p[i + 1], z = p[i + 2];
    const v = [m[0] * x + m[4] * y + m[8] * z + m[12], m[1] * x + m[5] * y + m[9] * z + m[13], m[2] * x + m[6] * y + m[10] * z + m[14]];
    for (let k = 0; k < 3; k++) {
      if (v[k] < min[k]) min[k] = v[k];
      if (v[k] > max[k]) max[k] = v[k];
    }
  }
  return { min, max, diag: Math.hypot(max[0] - min[0], max[1] - min[1], max[2] - min[2]) };
}

function bakeGroup(parts, errorMeters) {
  const groups = { opaque: [], blend: [] };
  for (const part of parts) {
    const geom = part.geom;
    const idx = simplifiedIndices(part.prim, geom, errorMeters / part.scale);
    if (idx.length === 0) continue;
    (part.color.blend ? groups.blend : groups.opaque).push({ part, geom, idx });
  }
  const out = {};
  for (const [name, list] of Object.entries(groups)) {
    if (list.length === 0) continue;
    let vcount = 0, icount = 0;
    const remaps = [];
    for (const { geom, idx } of list) {
      const remap = new Int32Array(geom.positions.length / 3).fill(-1);
      let n = 0;
      for (const i of idx) if (remap[i] < 0) remap[i] = n++;
      remaps.push({ remap, n });
      vcount += n;
      icount += idx.length;
    }
    const positions = new Float32Array(vcount * 3);
    const normals = new Float32Array(vcount * 3);
    const colors = new Uint8Array(vcount * 4);
    const indices = new Uint32Array(icount);
    let vbase = 0, ibase = 0;
    list.forEach(({ part, geom, idx }, li) => {
      const { remap, n } = remaps[li];
      const m = part.matrix;
      const nm = invert(m); // normals use transpose(inverse(m)); the transpose is folded into the indexing below
      const flip = det3(m) < 0;
      const rgba = part.color.rgba.map((c) => Math.round(Math.min(1, Math.max(0, c)) * 255));
      for (let v = 0; v < remap.length; v++) {
        const o = remap[v];
        if (o < 0) continue;
        const x = geom.positions[v * 3], y = geom.positions[v * 3 + 1], z = geom.positions[v * 3 + 2];
        const w = (vbase + o) * 3;
        positions[w] = m[0] * x + m[4] * y + m[8] * z + m[12];
        positions[w + 1] = m[1] * x + m[5] * y + m[9] * z + m[13];
        positions[w + 2] = m[2] * x + m[6] * y + m[10] * z + m[14];
        const a = geom.normals[v * 3], b = geom.normals[v * 3 + 1], c = geom.normals[v * 3 + 2];
        let nx = nm[0] * a + nm[1] * b + nm[2] * c;
        let ny = nm[4] * a + nm[5] * b + nm[6] * c;
        let nz = nm[8] * a + nm[9] * b + nm[10] * c;
        const l = Math.hypot(nx, ny, nz) || 1;
        normals[w] = nx / l;
        normals[w + 1] = ny / l;
        normals[w + 2] = nz / l;
        colors.set(rgba, (vbase + o) * 4);
      }
      for (let t = 0; t < idx.length; t += 3) {
        const i0 = vbase + remap[idx[t]], i1 = vbase + remap[idx[t + 1]], i2 = vbase + remap[idx[t + 2]];
        indices[ibase + t] = i0;
        indices[ibase + t + 1] = flip ? i2 : i1;
        indices[ibase + t + 2] = flip ? i1 : i2;
      }
      vbase += n;
      ibase += idx.length;
    });
    out[name] = { positions, normals, colors, indices, triangles: icount / 3, vertices: vcount };
  }
  return out;
}

function prepareParts(rawParts, minPart) {
  const kept = [];
  let dropped = 0;
  for (const p of rawParts) {
    const geom = geometryOf(p.prim);
    if (!geom || geom.indices.length === 0) continue;
    if (minPart > 0 && partBounds(geom, p.matrix).diag < minPart) {
      dropped++;
      continue;
    }
    kept.push({ ...p, geom, scale: maxScale(p.matrix), color: materialColor(p.prim.getMaterial()) });
  }
  return { kept, dropped };
}

// Grows the error until the merged groups fit `target` triangles, then bisects
// between the last two errors to use as much of the target as possible.
function fitToTarget(label, parts, cfg) {
  const tris = (b) => Object.values(b).reduce((s, g) => s + g.triangles, 0);
  let error = cfg.error;
  let baked = bakeGroup(parts, error);
  let passes = 1;
  if (tris(baked) <= cfg.target) {
    console.log(`  ${label}: ${tris(baked)} tris, error ${(error * 1000).toFixed(3)} mm, 1 pass`);
    return { baked, error, triangles: tris(baked) };
  }
  let lo = error;
  while (tris(baked) > cfg.target && passes < MAX_PASSES) {
    lo = error;
    error *= ERROR_GROWTH;
    baked = bakeGroup(parts, error);
    passes++;
  }
  let hi = error;
  for (let i = 0; i < BISECT_STEPS && passes < MAX_PASSES + BISECT_STEPS; i++) {
    const mid = (lo + hi) / 2;
    const b = bakeGroup(parts, mid);
    passes++;
    if (tris(b) <= cfg.target) {
      hi = mid;
      baked = b;
      error = mid;
    } else {
      lo = mid;
    }
  }
  console.log(`  ${label}: ${tris(baked)} tris, error ${(error * 1000).toFixed(3)} mm, ${passes} passes`);
  return { baked, error, triangles: tris(baked) };
}


function addPrimitive(doc, buffer, mesh, group, material) {
  const pos = doc.createAccessor().setType('VEC3').setArray(group.positions).setBuffer(buffer);
  const nrm = doc.createAccessor().setType('VEC3').setArray(group.normals).setBuffer(buffer);
  const col = doc.createAccessor().setType('VEC4').setArray(group.colors).setNormalized(true).setBuffer(buffer);
  const idxArray = group.vertices <= 65535 ? Uint16Array.from(group.indices) : group.indices;
  const idx = doc.createAccessor().setType('SCALAR').setArray(idxArray).setBuffer(buffer);
  const prim = doc.createPrimitive().setAttribute('POSITION', pos).setAttribute('NORMAL', nrm).setAttribute('COLOR_0', col).setIndices(idx).setMaterial(material);
  mesh.addPrimitive(prim);
}

function createMaterials(doc) {
  return {
    opaque: doc.createMaterial('cad_opaque').setBaseColorFactor([1, 1, 1, 1]).setMetallicFactor(0).setRoughnessFactor(1).setDoubleSided(true),
    blend: doc.createMaterial('cad_blend').setBaseColorFactor([1, 1, 1, 1]).setMetallicFactor(0).setRoughnessFactor(1).setDoubleSided(true).setAlphaMode('BLEND'),
    bumper: doc.createMaterial('bumper').setBaseColorFactor([1, 1, 1, 1]).setMetallicFactor(0).setRoughnessFactor(1).setDoubleSided(true),
  };
}

function trs(node) {
  return { translation: node.getTranslation(), rotation: node.getRotation(), scale: node.getScale() };
}

function applyTrs(target, t) {
  return target.setTranslation(t.translation).setRotation(t.rotation).setScale(t.scale);
}

function countSurfaces(doc) {
  return doc.getRoot().listMeshes().reduce((s, m) => s + m.listPrimitives().length, 0);
}

async function writeGlb(io, doc) {
  doc.getRoot().getAsset().generator = GENERATOR;
  doc.getRoot().setDefaultScene(doc.getRoot().listScenes()[0]);
  return Buffer.from(await io.writeBinary(doc));
}


async function buildRobot(io, ROBOT) {
  const srcPath = path.join(SRC_DIR, ROBOT.source);
  const src = await io.read(srcPath);
  await src.transform(dequantize());
  const scene = src.getRoot().listScenes()[0];
  const root = scene.listChildren().find((n) => n.getName() === ROBOT.root);
  if (!root) throw new Error(`robot root node ${ROBOT.root} not found`);
  const children = root.listChildren();

  const doc = new Document();
  const buffer = doc.createBuffer();
  const mats = createMaterials(doc);
  const outScene = doc.createScene('Robot');
  const outRoot = applyTrs(doc.createNode(ROBOT.root), trs(root));
  outScene.addChild(outRoot);

  const manifest = { anchors: {}, rest: {} };
  manifest.rest[ROBOT.root] = trs(root);
  let total = 0;

  for (const child of children) {
    const name = child.getName();
    const isAnchor = ROBOT.anchors.includes(name);
    const isBumper = !isAnchor && child.getMesh()?.getName() === ROBOT.bumperMesh;
    if (!isAnchor && !isBumper) {
      console.log(`  skipping unexpected root child "${name}"`);
      continue;
    }
    const outName = isBumper ? ROBOT.bumperNode : name;
    const cfg = isBumper ? { target: Infinity, error: 0, minPart: 0 } : ROBOT.simplify[name];
    const { kept, dropped } = prepareParts(collectParts(child, child.getWorldMatrix()), cfg.minPart);
    const { baked, error, triangles } = fitToTarget(outName, kept, cfg);
    const outNode = applyTrs(doc.createNode(outName), trs(child));
    const mesh = doc.createMesh(outName);
    if (baked.opaque) addPrimitive(doc, buffer, mesh, baked.opaque, isBumper ? mats.bumper : mats.opaque);
    if (baked.blend) addPrimitive(doc, buffer, mesh, baked.blend, mats.blend);
    outNode.setMesh(mesh);
    outRoot.addChild(outNode);
    total += triangles;
    manifest.anchors[outName] = {
      triangles,
      budget: Number.isFinite(cfg.budget ?? Infinity) ? cfg.budget : null,
      surfaces: mesh.listPrimitives().length,
      parts_kept: kept.length,
      parts_dropped: dropped,
      error_mm: +(error * 1000).toFixed(4),
    };
    manifest.rest[outName] = trs(child);
  }

  for (const name of [...ROBOT.anchors, ROBOT.bumperNode]) {
    if (!manifest.anchors[name]) throw new Error(`robot node ${name} missing from the source`);
  }
  for (const m of doc.getRoot().listMaterials()) {
    if (!doc.getRoot().listMeshes().some((mesh) => mesh.listPrimitives().some((p) => p.getMaterial() === m))) m.dispose();
  }
  const bytes = await writeGlb(io, doc);
  return { bytes, triangles: total, surfaces: countSurfaces(doc), sha: sha256(srcPath), ...manifest };
}


async function buildField(io, FIELD) {
  const srcPath = path.join(SRC_DIR, FIELD.source);
  const src = await io.read(srcPath);
  await src.transform(dequantize());
  const scene = src.getRoot().listScenes()[0];
  const identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  let fuel = 0;
  const skip = (n) => {
    if (n.getName().startsWith(FIELD.dropPrefix)) {
      fuel++;
      return true;
    }
    return false;
  };
  const raw = [];
  for (const top of scene.listChildren()) raw.push(...collectParts(top, identity, skip));
  const { kept, dropped } = prepareParts(raw, FIELD.simplify.minPart);
  const { baked, error, triangles } = fitToTarget('Field', kept, FIELD.simplify);

  const doc = new Document();
  const buffer = doc.createBuffer();
  const mats = createMaterials(doc);
  const outScene = doc.createScene('Field');
  const node = doc.createNode('FieldMesh');
  const mesh = doc.createMesh('FieldMesh');
  if (baked.opaque) addPrimitive(doc, buffer, mesh, baked.opaque, mats.opaque);
  if (baked.blend) addPrimitive(doc, buffer, mesh, baked.blend, mats.blend);
  node.setMesh(mesh);
  outScene.addChild(node);
  for (const m of doc.getRoot().listMaterials()) {
    if (!mesh.listPrimitives().some((p) => p.getMaterial() === m)) m.dispose();
  }
  const bytes = await writeGlb(io, doc);
  return {
    bytes,
    triangles,
    surfaces: countSurfaces(doc),
    sha: sha256(srcPath),
    fuel_nodes_dropped: fuel,
    parts_kept: kept.length,
    parts_dropped: dropped,
    error_mm: +(error * 1000).toFixed(4),
  };
}


async function writeReference(io, dir) {
  mkdirSync(dir, { recursive: true });
  const plain = new NodeIO();
  for (const [file, out] of [[ROBOT.source, 'robot-reference.glb'], [FIELD.source, 'field-reference.glb']]) {
    const doc = await io.read(path.join(SRC_DIR, file));
    await doc.transform(dequantize());
    for (const ext of doc.getRoot().listExtensionsUsed()) ext.dispose();
    for (const anim of doc.getRoot().listAnimations()) anim.dispose();
    writeFileSync(path.join(dir, out), Buffer.from(await plain.writeBinary(doc)));
    console.log(`reference ${out} written`);
  }
}


function checkBudget(label, result, budget, failures) {
  if (result.triangles > budget.triangles) failures.push(`${label}: ${result.triangles} triangles > ${budget.triangles}`);
  if (result.surfaces > budget.surfaces) failures.push(`${label}: ${result.surfaces} surfaces > ${budget.surfaces}`);
  if (result.bytes.length > budget.bytes) failures.push(`${label}: ${result.bytes.length} bytes > ${budget.bytes}`);
}

function packageVersion(name) {
  return JSON.parse(readFileSync(path.join(HERE, 'node_modules', name, 'package.json'), 'utf8')).version;
}

async function main() {
  const args = process.argv.slice(2);
  const refIdx = args.indexOf('--reference');
  const check = args.includes('--check');
  await MeshoptSimplifier.ready;
  const io = await makeIO();

  const specs = [
    { key: 'robot', spec: ROBOT, build: buildRobot },
    { key: 'robot_lite', spec: ROBOT_LITE, build: buildRobot },
    { key: 'field', spec: FIELD, build: buildField },
    { key: 'field_lite', spec: FIELD_LITE, build: buildField },
  ];
  const built = {};
  for (const { key, spec, build } of specs) {
    console.log(`${key}:`);
    built[key] = await build(io, spec);
  }

  const failures = [];
  for (const { key, spec } of specs) {
    const r = built[key];
    checkBudget(key, r, spec.budget, failures);
    for (const [name, a] of Object.entries(r.anchors ?? {})) {
      if (a.budget !== null && a.triangles > a.budget) failures.push(`${key} ${name}: ${a.triangles} triangles > ${a.budget}`);
    }
    const json = JSON.parse(r.bytes.subarray(20, 20 + r.bytes.readUInt32LE(12)).toString('utf8'));
    if ((json.extensionsRequired ?? []).length || (json.extensionsUsed ?? []).length) failures.push(`${key}: output declares extensions`);
    if (r.fuel_nodes_dropped !== undefined && r.fuel_nodes_dropped !== 456) failures.push(`${key}: expected 456 Fuel nodes, dropped ${r.fuel_nodes_dropped}`);
  }

  const manifest = {
    version: 1,
    generator: GENERATOR,
    tools: Object.fromEntries(['@gltf-transform/core', '@gltf-transform/functions', 'draco3dgltf', 'meshoptimizer'].map((n) => [n, packageVersion(n)])),
  };
  for (const { key, spec } of specs) {
    const r = built[key];
    const entry = {
      source: `apps/comp/cad-assets/${spec.source}`,
      source_sha256: r.sha,
      output: `assets/models/${spec.output}`,
      output_sha256: createHash('sha256').update(r.bytes).digest('hex'),
      bytes: r.bytes.length,
      triangles: r.triangles,
      surfaces: r.surfaces,
      budget: spec.budget,
    };
    if (r.anchors) Object.assign(entry, { anchors: r.anchors, rest_transforms: r.rest });
    else Object.assign(entry, { fuel_nodes_dropped: r.fuel_nodes_dropped, parts_kept: r.parts_kept, parts_dropped: r.parts_dropped, error_mm: r.error_mm });
    manifest[key] = entry;
  }
  const manifestText = JSON.stringify(manifest, null, 2) + '\n';

  for (const { key } of specs) {
    const r = built[key];
    console.log(`${key}: ${r.triangles} tris, ${r.surfaces} surfaces, ${(r.bytes.length / 1048576).toFixed(2)} MiB`);
  }

  const outputs = [
    ...specs.map(({ key, spec }) => [path.join(OUT_DIR, spec.output), built[key].bytes]),
    [path.join(OUT_DIR, 'models.manifest.json'), manifestText],
  ];
  if (check) {
    const same = (file, data) => existsSync(file) && Buffer.compare(readFileSync(file), Buffer.from(data)) === 0;
    for (const [f] of outputs.filter(([f, d]) => !same(f, d))) failures.push(`stale output: ${path.relative(APP, f)}`);
  } else {
    mkdirSync(OUT_DIR, { recursive: true });
    for (const [f, d] of outputs) writeFileSync(f, d);
  }
  if (refIdx >= 0) await writeReference(io, path.resolve(args[refIdx + 1]));

  if (failures.length) {
    for (const f of failures) console.error('BUDGET/CHECK FAILED: ' + f);
    process.exit(1);
  }
  console.log(check ? 'outputs up to date' : 'ok');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
