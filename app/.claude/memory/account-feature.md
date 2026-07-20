---
name: account-feature
description: "AccountFeature module — the account sheet (Profile/Settings/Achievements tabs); consumes achievements + PATCH accounts/me. Notifications matrix + email editing deferred."
metadata:
  type: project
  originSessionId: current
---

The account modal was extracted out of `SidebarFeature` into its own **`AccountFeature`** module (`Modules/AccountFeature/`), a 3-tab sheet:
- **Profile** — read-only identity (name, email + verification, status, member-since, XP, replicant count) + API key (mono) + Log Out.
- **Settings** — editable via `PATCH /v1/accounts/me`: name, timezone, replicant cooperation (`individual`/`shared` — an account-level enum, distinct from the replicant-level `private`/`public`), bobnet channels (comma-separated field). Save is guarded by `hasUnsavedChanges`.
- **Achievements** — merged `GET /v1/accounts/achievements` (earned) + `GET /v1/achievements` (global catalog, `player_count`) via `Achievement.merged(earned:catalog:)`; grouped by category, earned + locked.

Key wiring:
- `Achievement` is a plain (non-`@Table`) struct in `GameModels` — modal-only, fetched fresh, no SQLite/migration.
- `AccountClient` (in the module) does the achievements fetch + PATCH; `AccountFeature` calls `AccountManager.refreshAccount()` after a successful save so `@Shared(.account)` keeps a single writer.
- Presentation lives in **`MainFeature`** (`@Presents var account`), NOT the sidebar: `SidebarFeature` now just emits `.delegate(.accountButtonTapped)` (its old `apiKey`/`isShowingAccount`/`logoutButtonTapped`/`.loggedOut` are gone). Logout bubbles `AccountFeature.delegate.loggedOut` → MainFeature → app root.

**Deferred (explicit, not yet built):** the `message_notify` notification matrix (email+webhook × 11 categories) and email editing (triggers server re-verification). Settings shows a "notifications aren't editable here yet" note.

Note: adding the library to `Modules/Package.swift` products was enough — Xcode auto-linked `AccountFeature` to the app target (pbxproj picked it up), contradicting the older [[pbxproj-link-is-manual]] assumption for this case.
