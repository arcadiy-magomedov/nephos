"use strict";

const dialog = document.querySelector("dialog.modal");
if (dialog && typeof dialog.showModal === "function") {
  dialog.close();
  dialog.showModal();
  dialog.querySelector("[data-initial-focus]")?.focus();
  dialog.addEventListener("keydown", (event) => {
    if (event.key !== "Tab" || event.altKey || event.ctrlKey || event.metaKey) return;
    const focusable = [...dialog.querySelectorAll(
      'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
    )].filter((element) => element.getClientRects().length && getComputedStyle(element).visibility !== "hidden");
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  });
  dialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    window.location.assign(dialog.dataset.returnUrl);
  });
} else if (!dialog && window.location.hash) {
  document.getElementById(window.location.hash.slice(1))?.focus();
}

document.querySelectorAll("form[data-pending-label]").forEach((form) => {
  form.addEventListener("submit", (event) => {
    if (form.dataset.submitting === "true") {
      event.preventDefault();
      return;
    }
    const button = event.submitter || form.querySelector("button");
    if (!button) return;
    form.dataset.submitting = "true";
    form.setAttribute("aria-busy", "true");
    button.dataset.originalLabel = button.textContent;
    button.textContent = form.dataset.pendingLabel;
    button.disabled = true;
  });
});

window.addEventListener("pageshow", () => {
  document.querySelectorAll("form[data-submitting=true]").forEach((form) => {
    form.dataset.submitting = "false";
    form.removeAttribute("aria-busy");
    const button = form.querySelector("button[data-original-label]");
    if (button) {
      button.textContent = button.dataset.originalLabel;
      button.disabled = false;
    }
  });
});
