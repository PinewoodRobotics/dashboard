#!/usr/bin/env node
// Converts the raw CAD exports in apps/comp/cad-assets (read in place, never
// modified) into assets/models/{robot,field}.glb that Godot can import, and
// writes models.manifest.json. Godot's glTF importer reads neither
// KHR_draco_mesh_compression nor KHR_mesh_quantization, so the robot is
// decoded and dequantized to float32. Every step is lossless:
//   - every triangle of every part is kept (no simplification, no part culling)
//   - parts are joined per rig node and per material, with their node
//     transforms baked into float32 positions and normals
//   - materials keep their base color, metallic, roughness, alpha mode and
//     double-sidedness; texture coordinates are dropped only because no source
//     material has a texture
// The only content removed is the robot's two wheel-spin animations and the
// field's staged Fuel game pieces (hidden in the web minimap too).
// The outputs are build products (too large for git); the manifest is committed.
//
// Usage (from apps/comp-godot/tools/assets, after `npm ci`):
//   node build_models.mjs          build both models
//   node build_models.mjs --check  rebuild in memory and fail if the outputs on disk differ

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Document, NodeIO } from '@gltf-transform/core';
import { KHRDracoMeshCompression, KHRMeshQuantization } from '@gltf-transform/extensions';
import { dequantize } from '@gltf-transform/functions';
import draco3d from 'draco3dgltf';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const APP = path.resolve(HERE, '../..');
const SRC_DIR = path.resolve(APP, '../comp/cad-assets');
const OUT_DIR = path.join(APP, 'assets/models');
const MANIFEST = path.join(OUT_DIR, 'models.manifest.json');
const GENERATOR = 'comp-godot build_models.mjs';

const ROBOT = {
  source: 'Robot-Full.glb',
  output: 'robot.glb',
  root: 'Bumper',
  bumperMesh: 'Plane',
  bumperNode: 'BumperPlane',
  anchors: ['IndexWristRControl', 'TurretRControl', 'TurretGearRControl', 'ClimberControlInner', 'ClimberControlOuter', 'FrameControl'],
};

const FIELD = {
  source: 'field-2026.glb',
  output: 'field.glb',
  fuelPrefix: 'GE-26900',
  fuelNodes: 456,
};

const IDENTITY = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];


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


async function makeIO() {
  return new NodeIO()
    .registerExtensions([KHRDracoMeshCompression, KHRMeshQuantization])
    .registerDependencies({ 'draco3d.decoder': await draco3d.createDecoderModule() });
}

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

async function readSource(io, file) {
  const srcPath = path.join(SRC_DIR, file);
  const doc = await io.read(srcPath);
  await doc.transform(dequantize());
  const root = doc.getRoot();
  if (root.listTextures().length > 0) throw new Error(`${file} has textures; keep TEXCOORD_* before dropping them`);
  for (const mesh of root.listMeshes())
    for (const prim of mesh.listPrimitives())
      if (prim.getMode() !== 4) throw new Error(`${file}: mesh ${mesh.getName()} has a non-triangle primitive (mode ${prim.getMode()})`);
  return { doc, sha: sha256(readFileSync(srcPath)) };
}

function primitiveTriangles(prim) {
  return (prim.getIndices()?.getCount() ?? prim.getAttribute('POSITION').getCount()) / 3;
}

const geomCache = new Map();
function geometryOf(prim) {
  let g = geomCache.get(prim);
  if (g) return g;
  const pos = prim.getAttribute('POSITION');
  const nrm = prim.getAttribute('NORMAL');
  const count = pos.getCount();
  const positions = new Float64Array(count * 3);
  const normals = new Float64Array(count * 3);
  const el = [0, 0, 0];
  for (let i = 0; i < count; i++) {
    pos.getElement(i, el);
    positions.set(el, i * 3);
    if (nrm) {
      nrm.getElement(i, el);
      normals.set(el, i * 3);
    }
  }
  const idx = prim.getIndices();
  const indices = idx ? Uint32Array.from(idx.getArray()) : Uint32Array.from({ length: count }, (_, i) => i);
  if (!nrm) computeNormals(positions, indices, normals);
  g = { positions, normals, indices, vertices: count };
  geomCache.set(prim, g);
  return g;
}

function computeNormals(positions, indices, normals) {
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
      for (const prim of mesh.listPrimitives()) parts.push({ prim, matrix: rel });
    }
    for (const child of node.listChildren()) visit(child);
  };
  visit(top);
  return parts;
}

function materialKey(m) {
  if (!m) return 'default';
  return JSON.stringify([m.getBaseColorFactor(), m.getMetallicFactor(), m.getRoughnessFactor(), m.getAlphaMode(), m.getAlphaCutoff(), m.getDoubleSided(), m.getEmissiveFactor()]);
}

function copyMaterial(doc, m) {
  const out = doc.createMaterial(m ? m.getName() : 'default');
  if (!m) return out.setBaseColorFactor([1, 1, 1, 1]).setMetallicFactor(1).setRoughnessFactor(1);
  return out
    .setBaseColorFactor(m.getBaseColorFactor())
    .setMetallicFactor(m.getMetallicFactor())
    .setRoughnessFactor(m.getRoughnessFactor())
    .setAlphaMode(m.getAlphaMode())
    .setAlphaCutoff(m.getAlphaCutoff())
    .setDoubleSided(m.getDoubleSided())
    .setEmissiveFactor(m.getEmissiveFactor());
}

// One primitive per distinct material: positions and normals in the frame of
// the rig node the parts hang under, accumulated in float64 and stored as float32.
function joinByMaterial(doc, buffer, mesh, parts, materials) {
  const groups = new Map();
  for (const part of parts) {
    const key = materialKey(part.prim.getMaterial());
    if (!groups.has(key)) groups.set(key, { material: part.prim.getMaterial(), parts: [] });
    groups.get(key).parts.push(part);
  }
  let triangles = 0;
  for (const [key, group] of groups) {
    let vcount = 0, icount = 0;
    for (const p of group.parts) {
      const g = geometryOf(p.prim);
      vcount += g.vertices;
      icount += g.indices.length;
    }
    const positions = new Float32Array(vcount * 3);
    const normals = new Float32Array(vcount * 3);
    const indices = vcount > 65535 ? new Uint32Array(icount) : new Uint16Array(icount);
    let vbase = 0, ibase = 0;
    for (const p of group.parts) {
      const g = geometryOf(p.prim);
      const m = p.matrix;
      const nm = invert(m);
      const flip = det3(m) < 0;
      for (let v = 0; v < g.vertices; v++) {
        const x = g.positions[v * 3], y = g.positions[v * 3 + 1], z = g.positions[v * 3 + 2];
        const w = (vbase + v) * 3;
        positions[w] = m[0] * x + m[4] * y + m[8] * z + m[12];
        positions[w + 1] = m[1] * x + m[5] * y + m[9] * z + m[13];
        positions[w + 2] = m[2] * x + m[6] * y + m[10] * z + m[14];
        const a = g.normals[v * 3], b = g.normals[v * 3 + 1], c = g.normals[v * 3 + 2];
        const nx = nm[0] * a + nm[1] * b + nm[2] * c;
        const ny = nm[4] * a + nm[5] * b + nm[6] * c;
        const nz = nm[8] * a + nm[9] * b + nm[10] * c;
        const l = Math.hypot(nx, ny, nz) || 1;
        normals[w] = nx / l;
        normals[w + 1] = ny / l;
        normals[w + 2] = nz / l;
      }
      for (let t = 0; t < g.indices.length; t += 3) {
        indices[ibase + t] = vbase + g.indices[t];
        indices[ibase + t + 1] = vbase + g.indices[flip ? t + 2 : t + 1];
        indices[ibase + t + 2] = vbase + g.indices[flip ? t + 1 : t + 2];
      }
      vbase += g.vertices;
      ibase += g.indices.length;
    }
    if (!materials.has(key)) materials.set(key, copyMaterial(doc, group.material));
    const pos = doc.createAccessor().setType('VEC3').setArray(positions).setBuffer(buffer);
    const nrm = doc.createAccessor().setType('VEC3').setArray(normals).setBuffer(buffer);
    const idx = doc.createAccessor().setType('SCALAR').setArray(indices).setBuffer(buffer);
    mesh.addPrimitive(doc.createPrimitive().setAttribute('POSITION', pos).setAttribute('NORMAL', nrm).setIndices(idx).setMaterial(materials.get(key)));
    triangles += icount / 3;
  }
  return triangles;
}

function trs(node) {
  return { translation: node.getTranslation(), rotation: node.getRotation(), scale: node.getScale() };
}

function applyTrs(target, t) {
  return target.setTranslation(t.translation).setRotation(t.rotation).setScale(t.scale);
}

function stats(doc) {
  let surfaces = 0, vertices = 0, triangles = 0;
  for (const mesh of doc.getRoot().listMeshes())
    for (const prim of mesh.listPrimitives()) {
      surfaces++;
      vertices += prim.getAttribute('POSITION').getCount();
      triangles += prim.getIndices().getCount() / 3;
    }
  return { surfaces, vertices, triangles, materials: doc.getRoot().listMaterials().length };
}

async function writeGlb(doc) {
  doc.getRoot().getAsset().generator = GENERATOR;
  doc.getRoot().setDefaultScene(doc.getRoot().listScenes()[0]);
  return Buffer.from(await new NodeIO().writeBinary(doc));
}


async function buildRobot(io) {
  const { doc: src, sha } = await readSource(io, ROBOT.source);
  const scene = src.getRoot().listScenes()[0];
  const root = scene.listChildren().find((n) => n.getName() === ROBOT.root);
  if (!root) throw new Error(`robot root node ${ROBOT.root} not found`);
  if (scene.listChildren().length !== 1) throw new Error('robot scene has content outside the root node');

  const doc = new Document();
  const buffer = doc.createBuffer();
  const materials = new Map();
  const outScene = doc.createScene('Robot');
  const outRoot = applyTrs(doc.createNode(ROBOT.root), trs(root));
  outScene.addChild(outRoot);

  const anchors = {};
  const rest = { [ROBOT.root]: trs(root) };
  let sourceTriangles = 0;
  if (root.getMesh()) throw new Error('robot root node carries a mesh');

  for (const child of root.listChildren()) {
    const name = child.getName();
    const isAnchor = ROBOT.anchors.includes(name);
    const isBumper = !isAnchor && child.getMesh()?.getName() === ROBOT.bumperMesh;
    if (!isAnchor && !isBumper) throw new Error(`unexpected robot root child "${name}"`);
    const outName = isBumper ? ROBOT.bumperNode : name;
    const parts = collectParts(child, child.getWorldMatrix());
    const partTriangles = parts.reduce((s, p) => s + primitiveTriangles(p.prim), 0);
    const outNode = applyTrs(doc.createNode(outName), trs(child));
    const mesh = doc.createMesh(outName);
    const triangles = joinByMaterial(doc, buffer, mesh, parts, materials);
    if (triangles !== partTriangles) throw new Error(`${outName}: ${triangles} triangles out, ${partTriangles} in`);
    outNode.setMesh(mesh);
    outRoot.addChild(outNode);
    sourceTriangles += partTriangles;
    anchors[outName] = { triangles, surfaces: mesh.listPrimitives().length, parts: parts.length };
    rest[outName] = trs(child);
  }
  for (const name of [...ROBOT.anchors, ROBOT.bumperNode]) {
    if (!anchors[name]) throw new Error(`robot node ${name} missing from the source`);
  }
  const bytes = await writeGlb(doc);
  return { bytes, sha, source_triangles: sourceTriangles, ...stats(doc), anchors, rest_transforms: rest };
}


async function buildField(io) {
  const { doc: src, sha } = await readSource(io, FIELD.source);
  const scene = src.getRoot().listScenes()[0];
  let fuelNodes = 0, fuelTriangles = 0;
  const skip = (n) => {
    if (!n.getName().startsWith(FIELD.fuelPrefix)) return false;
    fuelNodes++;
    n.traverse((x) => {
      for (const p of x.getMesh()?.listPrimitives() ?? []) fuelTriangles += primitiveTriangles(p);
    });
    return true;
  };
  const parts = [];
  for (const top of scene.listChildren()) parts.push(...collectParts(top, IDENTITY, skip));
  if (fuelNodes !== FIELD.fuelNodes) throw new Error(`expected ${FIELD.fuelNodes} Fuel nodes, found ${fuelNodes}`);
  let sourceTriangles = 0;
  for (const n of src.getRoot().listNodes())
    for (const p of n.getMesh()?.listPrimitives() ?? []) sourceTriangles += primitiveTriangles(p);

  const doc = new Document();
  const buffer = doc.createBuffer();
  const outScene = doc.createScene('Field');
  const node = doc.createNode('FieldMesh');
  const mesh = doc.createMesh('FieldMesh');
  const triangles = joinByMaterial(doc, buffer, mesh, parts, new Map());
  if (triangles + fuelTriangles !== sourceTriangles) throw new Error(`field: ${triangles} + ${fuelTriangles} Fuel triangles != ${sourceTriangles} in the source`);
  node.setMesh(mesh);
  outScene.addChild(node);
  const bytes = await writeGlb(doc);
  return { bytes, sha, source_triangles: sourceTriangles, ...stats(doc), parts: parts.length, fuel_nodes_dropped: fuelNodes, fuel_triangles_dropped: fuelTriangles };
}


function packageVersion(name) {
  return JSON.parse(readFileSync(path.join(HERE, 'node_modules', name, 'package.json'), 'utf8')).version;
}

async function main() {
  const check = process.argv.includes('--check');
  const io = await makeIO();
  const specs = [
    { key: 'robot', spec: ROBOT, build: buildRobot },
    { key: 'field', spec: FIELD, build: buildField },
  ];
  const manifest = {
    version: 2,
    generator: GENERATOR,
    lossless: true,
    tools: Object.fromEntries(['@gltf-transform/core', '@gltf-transform/extensions', '@gltf-transform/functions', 'draco3dgltf'].map((n) => [n, packageVersion(n)])),
  };
  const failures = [];
  const outputs = [];
  for (const { key, spec, build } of specs) {
    const t0 = Date.now();
    const { bytes, sha, ...r } = await build(io);
    geomCache.clear();
    console.log(`${key}: ${r.triangles} triangles, ${r.vertices} vertices, ${r.surfaces} surfaces, ${(bytes.length / 1048576).toFixed(1)} MiB, ${((Date.now() - t0) / 1000).toFixed(1)} s`);
    manifest[key] = {
      source: `apps/comp/cad-assets/${spec.source}`,
      source_sha256: sha,
      output: `assets/models/${spec.output}`,
      output_sha256: sha256(bytes),
      bytes: bytes.length,
      ...r,
    };
    outputs.push([path.join(OUT_DIR, spec.output), bytes]);
  }
  outputs.push([MANIFEST, JSON.stringify(manifest, null, 2) + '\n']);

  if (check) {
    const same = (file, data) => existsSync(file) && Buffer.compare(readFileSync(file), Buffer.from(data)) === 0;
    for (const [f] of outputs.filter(([f, d]) => !same(f, d))) failures.push(`stale output: ${path.relative(APP, f)}`);
  } else {
    mkdirSync(OUT_DIR, { recursive: true });
    for (const [f, d] of outputs) writeFileSync(f, d);
  }
  if (failures.length) {
    for (const f of failures) console.error('CHECK FAILED: ' + f);
    process.exit(1);
  }
  console.log(check ? 'outputs up to date' : 'ok');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
