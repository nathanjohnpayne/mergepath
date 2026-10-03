"use strict";

// Transport only. Remove the credential before any await or network call.
const fragment = new URLSearchParams(window.location.hash.slice(1));
let launch = fragment.get("launch");
window.history.replaceState(null, "", "/bootstrap");
fragment.delete("launch");

async function establishSession() {
  const status = document.getElementById("session-status");
  if (!launch) {
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
    window.location.replace("/");
  } catch {
    launch = null;
    status.textContent = "Session unavailable. Relaunch scripts/cockpit.sh to try again.";
  }
}

void establishSession();
