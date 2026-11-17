#!/usr/bin/env node
// Godot's GLTFDocument reads neither KHR_draco_mesh_compression nor
// KHR_mesh_quantization, which Robot-Full.glb requires. This writes a copy with
// both decoded to plain float32 accessors and nothing else changed: same nodes,
// meshes, materials and transforms.
//
// Usage (from apps/comp-gpui/tools/models, after `npm ci`):
//   node decode.mjs [source.glb] [output.glb]
// Defaults: apps/comp/cad-assets/Robot-Full.glb -> apps/comp-gpui/models/Robot-Full.glb

import { mkdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { NodeIO } from '@gltf-transform/core';
import { KHRDracoMeshCompression, KHRMeshQuantization } from '@gltf-transform/extensions';
import { dequantize } from '@gltf-transform/functions';
import draco3d from 'draco3dgltf';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const APP = path.resolve(HERE, '../..');
const source = path.resolve(process.argv[2] ?? path.join(APP, '../comp/cad-assets/Robot-Full.glb'));
const output = path.resolve(process.argv[3] ?? path.join(APP, 'models/Robot-Full.glb'));

const t0 = Date.now();
const io = new NodeIO()
  .registerExtensions([KHRDracoMeshCompression, KHRMeshQuantization])
  .registerDependencies({ 'draco3d.decoder': await draco3d.createDecoderModule() });
const doc = await io.read(source);
await doc.transform(dequantize());
for (const ext of doc.getRoot().listExtensionsUsed()) {
  if (ext.extensionName === KHRDracoMeshCompression.EXTENSION_NAME || ext.extensionName === KHRMeshQuantization.EXTENSION_NAME) {
    ext.dispose();
  }
}
mkdirSync(path.dirname(output), { recursive: true });
await new NodeIO().write(output, doc);
const mib = (statSync(output).size / 1048576).toFixed(1);
console.log(`${path.basename(source)} -> ${output} (${mib} MiB, ${((Date.now() - t0) / 1000).toFixed(1)} s)`);
