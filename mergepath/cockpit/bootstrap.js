"use strict";

// Transport only. Remove the credential before any await or network call.
const fragment = new URLSearchParams(window.location.hash.slice(1));
let launch = fragment.get("launch");
let scope = fragment.get("scope");
window.history.replaceState(null, "", "/bootstrap");
fragment.delete("launch"); fragment.delete("scope");

async function establishSession() {
  const status = document.getElementById("session-status");
  if (!launch || !/^[A-Za-z0-9_-]{43}$/.test(scope || "")) {
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
    const path = `/s/${scope}/`; scope = null;
    window.location.replace(path);
  } catch {
    launch = scope = null;
    status.textContent = "Session unavailable. Relaunch scripts/cockpit.sh to try again.";
  }
}

void establishSession();
