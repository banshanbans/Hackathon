export type CaptureDraft = {
  sessionId: string;
  round: 1 | 2;
  blob: Blob;
  width: number;
  height: number;
  candidateId: string;
  selectionSource: "local_recommended" | "user_selected";
  localScore: number;
  reasons: string[];
  createdAt: number;
  uploadCreateKey: string;
  uploadCompleteKey: string;
  captureKey: string;
  evaluationKey: string;
  networkStep: "consent" | "upload" | "capture" | "evaluate";
  mediaAssetId: string | null;
  captureId: string | null;
};

type StoredCaptureDraft = Omit<CaptureDraft, "blob"> & {
  blobBytes: ArrayBuffer;
  blobType: string;
};

const DATABASE_NAME = "soloshot-live-coach";
const STORE_NAME = "capture-drafts";

function key(sessionId: string, round: 1 | 2): string {
  return `${sessionId}:${round}`;
}

function openDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE_NAME, 1);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(STORE_NAME)) {
        request.result.createObjectStore(STORE_NAME);
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("INDEXEDDB_OPEN_FAILED"));
  });
}

function transaction<T>(
  mode: IDBTransactionMode,
  action: (store: IDBObjectStore) => IDBRequest<T>,
): Promise<T> {
  return openDatabase().then(
    (database) =>
      new Promise<T>((resolve, reject) => {
        const tx = database.transaction(STORE_NAME, mode);
        const request = action(tx.objectStore(STORE_NAME));
        let result: T;
        request.onsuccess = () => {
          result = request.result;
        };
        request.onerror = () => reject(request.error ?? new Error("INDEXEDDB_REQUEST_FAILED"));
        tx.oncomplete = () => {
          database.close();
          resolve(result);
        };
        tx.onerror = () => {
          database.close();
          reject(tx.error ?? new Error("INDEXEDDB_TRANSACTION_FAILED"));
        };
      }),
  );
}

export function createCaptureDraft(
  input: Omit<
    CaptureDraft,
    | "createdAt"
    | "uploadCreateKey"
    | "uploadCompleteKey"
    | "captureKey"
    | "evaluationKey"
    | "networkStep"
    | "mediaAssetId"
    | "captureId"
  >,
): CaptureDraft {
  const random = () =>
    typeof crypto.randomUUID === "function" ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`;
  return {
    ...input,
    createdAt: Date.now(),
    uploadCreateKey: `h5-live-upload-${random()}`,
    uploadCompleteKey: `h5-live-complete-${random()}`,
    captureKey: `h5-live-capture-${random()}`,
    evaluationKey: `h5-live-evaluation-${random()}`,
    networkStep: "consent",
    mediaAssetId: null,
    captureId: null,
  };
}

export function rotateUploadAttempt(draft: CaptureDraft): CaptureDraft {
  const random = () =>
    typeof crypto.randomUUID === "function" ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`;
  return {
    ...draft,
    uploadCreateKey: `h5-live-upload-${random()}`,
    uploadCompleteKey: `h5-live-complete-${random()}`,
  };
}

export async function saveCaptureDraft(draft: CaptureDraft): Promise<void> {
  const { blob, ...metadata } = draft;
  const stored: StoredCaptureDraft = {
    ...metadata,
    blobBytes: await blob.arrayBuffer(),
    blobType: blob.type || "image/jpeg",
  };
  await transaction("readwrite", (store) => store.put(stored, key(draft.sessionId, draft.round)));
}

export async function loadCaptureDraft(
  sessionId: string,
  round: 1 | 2,
): Promise<CaptureDraft | null> {
  const result = await transaction("readonly", (store) => store.get(key(sessionId, round)));
  if (result === undefined) {
    return null;
  }
  const stored = result as StoredCaptureDraft | CaptureDraft;
  if ("blob" in stored) {
    return {
      ...stored,
      selectionSource: stored.selectionSource ?? "local_recommended",
    };
  }
  const { blobBytes, blobType, ...metadata } = stored;
  return {
    ...metadata,
    selectionSource: metadata.selectionSource ?? "local_recommended",
    blob: new Blob([blobBytes], { type: blobType }),
  };
}

export async function deleteCaptureDraft(sessionId: string, round: 1 | 2): Promise<void> {
  await transaction("readwrite", (store) => store.delete(key(sessionId, round)));
}
