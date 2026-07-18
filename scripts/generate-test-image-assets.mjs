import { mkdir, readFile, stat } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "..");
const datasetRoot = join(repositoryRoot, "packages/evals/test-image-v1");
const manifestPath = join(datasetRoot, "manifest.json");
const outputRoot = join(repositoryRoot, "apps/h5/public/presets/test-image-v1");

const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
const publicCases = manifest.cases.filter((item) => item.public_preset === true);

await mkdir(outputRoot, { recursive: true });

for (const item of publicCases) {
  const source = join(datasetRoot, item.source_path);
  const outputs = [
    {
      kind: "thumb",
      path: join(outputRoot, `${item.case_id}-thumb.webp`),
      resize: { width: 320, withoutEnlargement: true },
      byteBudget: 80 * 1024,
    },
    {
      kind: "detail",
      path: join(outputRoot, `${item.case_id}-detail.webp`),
      resize: { width: 960, height: 960, fit: "inside", withoutEnlargement: true },
      byteBudget: 300 * 1024,
    },
  ];

  for (const output of outputs) {
    await sharp(source)
      .rotate()
      .resize(output.resize)
      .webp({ quality: 82, effort: 5 })
      .toFile(output.path);
    const file = await stat(output.path);
    if (file.size > output.byteBudget) {
      throw new Error(`${item.case_id} ${output.kind} exceeds ${output.byteBudget} bytes`);
    }
  }
}

console.log(`Generated ${publicCases.length * 2} Test Image v1 WebP assets in ${outputRoot}`);
