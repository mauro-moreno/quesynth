import test from "node:test";
import assert from "node:assert/strict";
import { daemonFixture } from "./support/daemon.mjs";
import { skip, startClient } from "./support/client.mjs";

const errorOf = response => {
  assert.equal(response.result.isError, true);
  return JSON.parse(response.result.content[0].text);
};

test("refusals, timeouts and broken frames never replay mutations and a later call reconnects", {skip}, async t => {
  let behavior = "refuse";
  const daemon = await daemonFixture(t, (command, peer) => {
    if (behavior === "refuse") return "err out_of_range value out of range";
    if (behavior === "hang") return undefined;
    if (behavior === "disconnect") { peer.end(); return undefined; }
    if (behavior === "malformed") { peer.write(Buffer.from([1, 0, 0, 0, 0])); return undefined; }
    if (behavior === "oversized") { peer.write(Buffer.from([1, 0, 1, 0])); return undefined; }
    return "ok value=17 revision=2";
  });
  const client = startClient(t, { args: ["--socket", daemon.socket, "--timeout-ms", "60"] });
  await client.initialize();
  const refused = errorOf(await client.call("parameter_set", { id: "filter.cutoff", value: 200 }));
  assert.deepEqual(refused, { code: "out_of_range", message: "value out of range" });
  for (behavior of ["hang", "disconnect", "malformed", "oversized"]) {
    const expected = behavior;
    const started = Date.now();
    const error = errorOf(await client.call("patch_load", { slot: 0 }));
    assert.equal(error.code, "daemon_unavailable");
    if (behavior === "hang") {
      assert.match(error.message, /within 60 ms/);
      assert.ok(Date.now() - started < 1500);
    } else assert.match(error.message, /closed|malformed|oversized/);
    behavior = "ok";
    const read = await client.call("parameter_get", { id: "filter.cutoff" });
    assert.equal(read.result.structuredContent.fields, "value=17 revision=2", expected);
  }
  assert.equal(daemon.commands.filter(c => c === "patch.load 0").length, 4);
  assert.equal(daemon.commands.filter(c => c.startsWith("parameter.set")).length, 1);
});
