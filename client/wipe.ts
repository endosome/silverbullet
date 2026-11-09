import { captureDatabaseName } from "./capture/store.ts";

/**
 * Deletes the IndexedDB databases that don't belong to this space. The service
 * worker's capture database is left alone: the worker clears it itself on
 * "wipe-data", and deleting it closes the connection that clear needs.
 */
export async function deleteForeignDatabases(
  idb: Pick<IDBFactory, "databases" | "deleteDatabase">,
  suffix: string,
): Promise<void> {
  if (!idb.databases) return;
  const capturePrefix = captureDatabaseName("");
  for (const db of await idb.databases()) {
    if (!db.name || db.name.endsWith(suffix)) continue;
    if (db.name.startsWith(capturePrefix)) continue;
    console.log("Deleting database", db.name);
    idb.deleteDatabase(db.name);
  }
}

/**
 * Handles the service worker's "wipe-data" message. The client waits for the
 * confirmation, so it is sent even when one of the clears fails.
 */
export async function wipeWorkerData(steps: {
  clearCapture: () => Promise<void>;
  wipeSync?: () => Promise<void>;
  confirm: () => void;
}): Promise<void> {
  try {
    try {
      await steps.clearCapture();
    } catch (e) {
      console.warn("Could not clear the capture store", e);
    }
    if (steps.wipeSync) {
      try {
        await steps.wipeSync();
      } catch (e) {
        console.warn("Could not wipe the sync data", e);
      }
    } else {
      console.warn("Not performing sync data wipe, sync engine not started");
    }
  } finally {
    steps.confirm();
  }
}
