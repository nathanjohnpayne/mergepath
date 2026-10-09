"use strict";

// Transport only. Remove the credential before any await or network call.
const fragment = new URLSearchParams(window.location.hash.slice(1));
const launching = fragment.has("launch") || fragment.has("scope");
let launch = fragment.get("launch");
let scope = fragment.get("scope");
if (launching) window.history.replaceState(null, "", "/bootstrap");
fragment.delete("launch"); fragment.delete("scope");

const SCOPE = /^[A-Za-z0-9_-]{43}$/;
// localStorage is isolated per origin, port included, unlike the cookie, so a
// sibling port cannot read the namespace this launch stored (#1848).
const STORED_SCOPE = "mergepath.cockpit.scope";

function storage() {
  try { return window.localStorage || null; } catch { return null; }
}
function rawStored() {
  try { return storage()?.getItem(STORED_SCOPE) ?? null; } catch { return null; }
}
function remember(value) {
  try { storage()?.setItem(STORED_SCOPE, value); } catch { /* reopen is a convenience */ }
}
// Remove only the namespace that failed: a launch in another tab may have
// stored a newer one while this probe was in flight.
function forget(expected) {
  try {
    const store = storage();
    if (store && store.getItem(STORED_SCOPE) === expected) store.removeItem(STORED_SCOPE);
  } catch { /* nothing to clear */ }
}

async function establishSession(status) {
  if (!launch || !SCOPE.test(scope || "")) {
    launch = scope = null;
    status.textContent = "Relaunch scripts/cockpit.sh to establish a new local session.";
    return;
  }
  try {
    const response = await fetch("/api/bootstrap", {
      method: "POST",
      credentials: "same-origin",
      headers: { "X-Cockpit-Bootstrap": launch, "X-Cockpit-CSRF": launch },
    });
    launch = null;
    if (!response.ok) throw new Error("session_refused");
    remember(scope);
    const path = `/s/${scope}/`; scope = null;
    window.location.replace(path);
  } catch {
    launch = scope = null;
    status.textContent = "Session unavailable. Relaunch scripts/cockpit.sh to try again.";
  }
}

// The printed base URL reopens the session this browser established, after
// the scoped session route confirms the cookie is still valid. No secret is
// ever printed: the namespace never leaves this origin's storage.
async function reopenSession(status) {
  // Validate and clean up from ONE read: a second read could pick up a valid
  // namespace a concurrent launch stored in between, and then delete it.
  const raw = rawStored();
  let stored = typeof raw === "string" && SCOPE.test(raw) ? raw : null;
  if (!stored) {
    if (raw !== null) forget(raw);
    status.textContent = "No Cockpit session in this browser. Open the Cockpit from the browser scripts/cockpit.sh launched, or relaunch it.";
    return;
  }
  status.textContent = "Reopening the Cockpit…";
  let response;
  try {
    response = await fetch(`/s/${stored}/api/session`, { credentials: "same-origin", cache: "no-store" });
  } catch {
    stored = null;
    status.textContent = "The Cockpit server is not answering. Relaunch scripts/cockpit.sh if it has stopped.";
    return;
  }
  if (response.status === 401 || response.status === 404) {
    // 401: the cookie expired or was cleared. 404: the server restarted with a new namespace.
    forget(stored); stored = null;
    status.textContent = "This Cockpit session has ended. Relaunch scripts/cockpit.sh to start a new one.";
    return;
  }
  if (!response.ok) {
    stored = null;
    status.textContent = "The Cockpit could not confirm the session. Reload this page, or relaunch scripts/cockpit.sh.";
    return;
  }
  const path = `/s/${stored}/`; stored = null;
  window.location.replace(path);
}

const status = document.getElementById("session-status");
void (launching ? establishSession(status) : reopenSession(status));
