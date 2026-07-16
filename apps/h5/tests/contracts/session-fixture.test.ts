import { readdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import Ajv2020, {
  type AnySchemaObject,
  type ValidateFunction,
} from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { describe, expect, expectTypeOf, it } from "vitest";
import type { components } from "../../src/generated/api";

type SoloShotSession = components["schemas"]["SoloShotSession"];

const schemaDirectory = resolve(
  import.meta.dirname,
  "../../../../packages/contracts/schemas",
);
const fixturePath = resolve(
  import.meta.dirname,
  "../../../../packages/contracts/fixtures/session.v1.json",
);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function schemaUrl(filename: string): string {
  return pathToFileURL(resolve(schemaDirectory, filename)).href;
}

function loadSchema(filename: string): AnySchemaObject {
  const parsed: unknown = JSON.parse(
    readFileSync(resolve(schemaDirectory, filename), "utf8"),
  );
  if (!isRecord(parsed)) {
    throw new TypeError(`${filename} must contain a JSON object`);
  }
  return { ...parsed, $id: schemaUrl(filename) };
}

function decodeSessionFixture(): SoloShotSession {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  for (const filename of readdirSync(schemaDirectory).filter((name) =>
    name.endsWith(".schema.json"),
  )) {
    ajv.addSchema(loadSchema(filename));
  }

  const registered = ajv.getSchema<SoloShotSession>(schemaUrl("session.schema.json"));
  if (registered === undefined) {
    throw new Error("Session schema was not registered");
  }
  const validate: ValidateFunction<SoloShotSession> = registered;

  const parsed: unknown = JSON.parse(readFileSync(fixturePath, "utf8"));
  if (!validate(parsed)) {
    throw new TypeError(ajv.errorsText(validate.errors));
  }
  return parsed;
}

describe("canonical session fixture", () => {
  it("decodes through the generated H5 contract", () => {
    const session = decodeSessionFixture();

    expect(session.schema_version).toBe("1.0");
    expect(session.session_id).toBe("ss_w0_fixture");
    expect(session.state).toBe("shot_plan_ready");
    expect(session.shot_plan?.target_layout.center_x).toBe(0.72);
    expectTypeOf(session).toMatchTypeOf<SoloShotSession>();
  });
});
