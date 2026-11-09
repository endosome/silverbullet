import "fake-indexeddb/auto";
import { expect, test, vi } from "vitest";
import { captureDatabaseName, openCaptureStore } from "./capture/store.ts";
import { deleteForeignDatabases, wipeWorkerData } from "./wipe.ts";

const suffix = `_${"a".repeat(64)}`;

test("keeps the worker's capture database and this space's own, deletes foreign ones", async () => {
  const captureName = captureDatabaseName(
    "https://notes.example/service_worker.js",
  );
  const idb = {
    databases: async () => [
      { name: `sb_data${suffix}` },
      { name: captureName },
      { name: `sb_data_${"b".repeat(64)}` },
      { name: "unrelated-app" },
      {},
    ],
    deleteDatabase: vi.fn(),
  };
  await deleteForeignDatabases(idb as any, suffix);
  expect(idb.deleteDatabase.mock.calls.map((c) => c[0])).toEqual([
    `sb_data_${"b".repeat(64)}`,
    "unrelated-app",
  ]);
});

test("does nothing when databases() is unsupported", async () => {
  const idb = { deleteDatabase: vi.fn() };
  await deleteForeignDatabases(idb as any, suffix);
  expect(idb.deleteDatabase).not.toHaveBeenCalled();
});

test("confirms the wipe when the capture store's clear throws", async () => {
  const confirm = vi.fn();
  const wipeSync = vi.fn(async () => {});
  vi.spyOn(console, "warn").mockImplementation(() => {});
  await wipeWorkerData({
    clearCapture: async () => {
      throw new Error("database connection is closing");
    },
    wipeSync,
    confirm,
  });
  expect(wipeSync).toHaveBeenCalled();
  expect(confirm).toHaveBeenCalledTimes(1);
});

test("confirms the wipe when there is no sync engine", async () => {
  const confirm = vi.fn();
  const clearCapture = vi.fn(async () => {});
  vi.spyOn(console, "warn").mockImplementation(() => {});
  await wipeWorkerData({ clearCapture, confirm });
  expect(clearCapture).toHaveBeenCalled();
  expect(confirm).toHaveBeenCalledTimes(1);
});

test("confirms the wipe when the sync wipe throws", async () => {
  const confirm = vi.fn();
  vi.spyOn(console, "warn").mockImplementation(() => {});
  await wipeWorkerData({
    clearCapture: async () => {},
    wipeSync: async () => {
      throw new Error("boom");
    },
    confirm,
  });
  expect(confirm).toHaveBeenCalledTimes(1);
});

test("deleting the capture database closes the connection, so clear() fails", async () => {
  const url = "https://notes.example/service_worker.js";
  const store = await openCaptureStore(url);
  indexedDB.deleteDatabase(captureDatabaseName(url));
  await new Promise((resolve) => setTimeout(resolve, 20));
  await expect(store.clear()).rejects.toThrow();
});
