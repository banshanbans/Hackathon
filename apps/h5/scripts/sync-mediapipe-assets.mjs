import { createHash } from "node:crypto";
import { copyFile, mkdir, readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const appRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repositoryRoot = path.resolve(appRoot, "../..");
const runtimeVersion = "0.10.35";
const source = path.join(repositoryRoot, "node_modules/@mediapipe/tasks-vision/wasm");
const destination = path.join(appRoot, `public/mediapipe/${runtimeVersion}/wasm`);
const model = path.join(appRoot, "public/models/mediapipe/pose-landmarker-lite-v1.task");
const expectedModelSha256 = "59929e1d1ee95287735ddd833b19cf4ac46d29bc7afddbbf6753c459690d574a";

await mkdir(destination, { recursive: true });
for (const filename of await readdir(source)) {
  if (filename.endsWith(".js") || filename.endsWith(".wasm")) {
    await copyFile(path.join(source, filename), path.join(destination, filename));
  }
}

const digest = createHash("sha256").update(await readFile(model)).digest("hex");
if (digest !== expectedModelSha256) {
  throw new Error(`Pose model checksum mismatch: ${digest}`);
}
