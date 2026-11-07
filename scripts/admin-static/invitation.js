"use strict";
const monitor = document.getElementById("invitation-monitor");
if (monitor) {
  const state = document.getElementById("invitation-state");
  const countdown = document.getElementById("countdown");
  const cancel = document.getElementById("cancel-invitation");
  const finished = document.getElementById("invitation-finished");
  const finishedActions = document.getElementById("invitation-finished-actions");
  const description = document.getElementById("dialog-description");
  const labels = {pending: "Waiting for scan", used: "Device connected", consumed: "Device connected", expired: "Expired", cancelled: "Cancelled"};
  let terminal = ["used", "consumed", "expired", "cancelled"].includes(monitor.dataset.status);
  const showFinished = () => {
    const returnFocus = cancel.contains(document.activeElement);
    document.getElementById("qr-warning")?.remove();
    cancel.hidden = true;
    finishedActions.hidden = false;
    if (returnFocus) finished.focus();
  };
  const tick = () => {
    const remaining = Math.max(0, Math.ceil((Date.parse(monitor.dataset.expires) - Date.now()) / 1000));
    countdown.textContent = remaining ? `Remaining ${Math.floor(remaining / 60)}:${String(remaining % 60).padStart(2, "0")}` : "";
    if (!remaining && !terminal) {
      state.textContent = "The device clock says this code has expired. Checking the server...";
      state.classList.add("status-warning");
    }
  };
  const poll = async () => {
    if (terminal) return;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000);
    try {
      const response = await fetch(monitor.dataset.url, {credentials: "same-origin", cache: "no-store", redirect: "error", signal: controller.signal});
      if (response.status === 401 || response.status === 403) {
        terminal = true;
        document.querySelector(".qr")?.remove();
        countdown.textContent = "";
        finished.href = "/login";
        finished.textContent = "Sign in";
        showFinished();
        description.textContent = "The invitation status is unavailable.";
        state.textContent = "Your administrator session has ended. Sign in again to check the invitation.";
        state.classList.add("status-warning");
        return;
      }
      if (!response.ok) throw new Error("status unavailable");
      const invitation = await response.json();
      if (!Object.hasOwn(labels, invitation.status)) throw new Error("invalid status");
      state.textContent = labels[invitation.status];
      state.classList.toggle("status-warning", invitation.status === "expired" || invitation.status === "cancelled");
      terminal = invitation.status !== "pending";
      if (terminal) {
        document.querySelector(".qr")?.remove();
        countdown.textContent = "";
        if (invitation.status === "expired" || invitation.status === "cancelled") finished.textContent = "Close";
        showFinished();
        description.textContent = "The invitation can no longer be used.";
      }
    } catch {
      state.textContent = "Could not check the invitation. Retrying; its status is unconfirmed.";
      state.classList.add("status-warning");
    } finally {
      clearTimeout(timeout);
      if (!terminal) setTimeout(poll, 3000);
    }
  };
  if (!terminal) {
    tick();
    const timer = setInterval(() => {if (terminal) clearInterval(timer); else tick();}, 1000);
    poll();
  }
}
