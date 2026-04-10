import { test } from "node:test";
import assert from "node:assert/strict";
import * as bridgeExports from "../index.js";

test("bridge package no longer exports RelayTransport", () => {
  assert.equal("RelayTransport" in bridgeExports, false);
});
