#!/usr/bin/env python3
"""Exercise the real Russian console with mouse, keyboard and mobile reflow."""

import os
import uuid

from playwright.sync_api import sync_playwright, expect
import smoke


def main():
    base = os.environ.get("NEPHOS_ADMIN_BASE_URL", "http://localhost:18082")
    username = "ux-" + uuid.uuid4().hex
    subject = None
    admin_url = smoke.IDENTITY + "/admin/realms/nephos/users"
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch()
            page = browser.new_page()
            errors = []
            page.on("pageerror", lambda error: errors.append(type(error).__name__))
            page.goto(base)
            page.get_by_role("link", name="Войти", exact=True).click()
            page.locator("#username").fill("admin")
            page.locator("#password").fill(smoke.ENV["KEYCLOAK_ADMIN_PASSWORD"])
            page.locator("#kc-login").click()
            page.wait_for_url(base + "/users")
            page.get_by_role("link", name="Создать пользователя", exact=True).click()
            page.get_by_label("Имя", exact=True).fill("UX qualification")
            page.get_by_label("Логин", exact=True).fill(username)
            page.get_by_role("button", name="Создать", exact=True).click()
            expect(page.get_by_text("Готово", exact=True)).to_be_visible(timeout=30000)
            records = smoke.request(admin_url + "?exact=true&username=" + username, token=smoke.admin_token())
            subject = records[0]["id"]
            page.get_by_role("link", name="Открыть пользователя", exact=True).click()
            expect(page.get_by_role("heading", name="UX qualification", exact=True)).to_be_visible()
            page.get_by_role("link", name="Изменить профиль", exact=True).click()
            page.get_by_label("Имя", exact=True).fill("Updated UX qualification")
            page.get_by_role("button", name="Сохранить", exact=True).click()
            for _ in range(30):
                if page.get_by_text("Готово", exact=True).is_visible():
                    break
                page.get_by_role("link", name="Обновить состояние", exact=True).click()
                page.wait_for_timeout(500)
            expect(page.get_by_text("Готово", exact=True)).to_be_visible()
            page.get_by_role("link", name="Открыть пользователя", exact=True).click()
            expect(page.get_by_role("heading", name="Updated UX qualification", exact=True)).to_be_visible()
            page.reload()
            expect(page.get_by_role("heading", name="Updated UX qualification", exact=True)).to_be_visible()
            for path, title in (
                ("/overview", "Обзор"),
                ("/users", "Пользователи"),
                ("/libraries", "Медиатеки"),
                ("/services", "Состояние сервисов"),
            ):
                page.goto(base + path)
                expect(page.get_by_role("heading", name=title, exact=True)).to_be_visible()
                page.set_viewport_size({"width": 390, "height": 844})
                assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth"), path
                expect(page.get_by_role("navigation", name="Основные разделы")).to_be_visible()
                page.set_viewport_size({"width": 1280, "height": 900})
            page.goto(base + "/users?search=definitely-no-matches-" + username)
            expect(page.get_by_role("heading", name="Совпадений нет", exact=True)).to_be_visible()
            page.get_by_role("link", name="Сбросить", exact=True).focus()
            page.keyboard.press("Enter")
            expect(page.get_by_role("heading", name="Пользователи", exact=True)).to_be_visible()
            page.get_by_role("button", name="Выйти", exact=True).click()
            expect(page.get_by_role("link", name="Войти", exact=True)).to_be_visible()
            assert not errors, errors
            browser.close()
        print("PASS: real browser create/profile/reload/navigation/search, keyboard controls and mobile reflow")
    finally:
        if subject:
            smoke.sql(
                """
                CREATE TEMP TABLE fixture_libraries AS SELECT library_id FROM library_members WHERE subject=:'subject';
                DELETE FROM administration_events WHERE operation_id IN(SELECT id FROM administration_operations WHERE subject=:'subject');
                DELETE FROM administration_operations WHERE subject=:'subject';
                DELETE FROM library_members WHERE subject=:'subject';
                DELETE FROM personal_libraries WHERE subject=:'subject';
                UPDATE libraries SET owner_subject=NULL WHERE owner_subject=:'subject';
                DELETE FROM principals WHERE subject=:'subject';
                DELETE FROM libraries WHERE id IN(SELECT library_id FROM fixture_libraries);
                """,
                subject=subject,
            )
            smoke.request(admin_url + "/" + subject, method="DELETE", token=smoke.admin_token(), expected=204)


if __name__ == "__main__":
    main()
