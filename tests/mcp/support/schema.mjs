// The part of JSON Schema the tools' output schemas use, and nothing else:
// type, properties, required, additionalProperties, items, minimum, maximum and
// oneOf. It exists so a test can ask what a client library would ask of
// structuredContent without adding a dependency. A keyword it does not know is
// an error, not a pass, so a schema that grows past it fails loudly here.

const KNOWN = new Set(["type", "properties", "required", "additionalProperties", "items", "minimum", "maximum",
  "oneOf", "description", "minLength", "maxLength", "minItems", "maxItems", "pattern"]);
const UNSUPPORTED_CHECKS = new Set(["minLength", "maxLength", "minItems", "maxItems", "pattern"]);

function typeOf(value) {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  if (Number.isInteger(value)) return "integer";
  return typeof value;
}

// The reasons `value` does not satisfy `schema`; empty when it does.
export function problems(schema, value, path = "$") {
  for (const key of Object.keys(schema)) {
    if (!KNOWN.has(key)) throw new Error(`schema keyword not supported by the test validator: ${key}`);
    if (UNSUPPORTED_CHECKS.has(key)) throw new Error(`schema keyword not checked by the test validator: ${key}`);
  }
  const found = [];
  const actual = typeOf(value);
  if (schema.type !== undefined) {
    const ok = schema.type === actual || (schema.type === "number" && actual === "integer");
    if (!ok) return [`${path}: expected ${schema.type}, got ${actual}`];
  }
  if (typeof value === "number") {
    if (schema.minimum !== undefined && value < schema.minimum) found.push(`${path}: below ${schema.minimum}`);
    if (schema.maximum !== undefined && value > schema.maximum) found.push(`${path}: above ${schema.maximum}`);
  }
  if (actual === "object") {
    for (const name of schema.required ?? []) {
      if (!Object.hasOwn(value, name)) found.push(`${path}: missing ${name}`);
    }
    const properties = schema.properties ?? {};
    for (const [name, member] of Object.entries(value)) {
      if (Object.hasOwn(properties, name)) found.push(...problems(properties[name], member, `${path}.${name}`));
      else if (schema.additionalProperties === false) found.push(`${path}: unexpected ${name}`);
    }
  }
  if (actual === "array" && schema.items !== undefined) {
    value.forEach((item, i) => found.push(...problems(schema.items, item, `${path}[${i}]`)));
  }
  if (schema.oneOf !== undefined) {
    const matching = schema.oneOf.filter(branch => problems(branch, value, path).length === 0).length;
    if (matching !== 1) found.push(`${path}: matches ${matching} of ${schema.oneOf.length} oneOf branches, not exactly one`);
  }
  return found;
}

export const accepts = (schema, value) => problems(schema, value).length === 0;
