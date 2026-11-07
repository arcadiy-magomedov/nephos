"use strict";
const monitor = document.getElementById("invitation-monitor");
if (monitor) {
  const state = document.getElementById("invitation-state");
  const countdown = document.getElementById("countdown");
  const labels = {pending: "Ожидает сканирования", used: "Устройство подключено", consumed: "Устройство подключено", expired: "Срок действия истёк", cancelled: "Отменено"};
  let terminal = false;
  const tick = () => {
    const remaining = Math.max(0, Math.ceil((Date.parse(monitor.dataset.expires) - Date.now()) / 1000));
    countdown.textContent = remaining ? `Осталось ${Math.floor(remaining / 60)}:${String(remaining % 60).padStart(2, "0")}` : "";
    if (!remaining && !terminal) state.textContent = "Срок по часам устройства истёк. Проверяем состояние сервера…";
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
        state.textContent = "Сессия администратора завершена. Войдите заново для проверки приглашения.";
        return;
      }
      if (!response.ok) throw new Error("status unavailable");
      const invitation = await response.json();
      if (!Object.hasOwn(labels, invitation.status)) throw new Error("invalid status");
      state.textContent = labels[invitation.status];
      terminal = invitation.status !== "pending";
      if (terminal) {
        document.querySelector(".qr")?.remove();
        countdown.textContent = "";
      }
    } catch {
      state.textContent = "Не удалось проверить приглашение. Повторяем запрос; состояние не подтверждено.";
    } finally {
      clearTimeout(timeout);
      if (!terminal) setTimeout(poll, 3000);
    }
  };
  tick();
  const timer = setInterval(() => {if (terminal) clearInterval(timer); else tick();}, 1000);
  poll();
}
