# Security Assessment: Event Registration System (ASP.NET MVC 5 / .NET 4.8)

**Date:** 2026-02-16
**Application:** Event Registration System
**Stack:** ASP.NET MVC 5, .NET Framework 4.8, SQLite, Dapper, OWIN, ASP.NET Identity 2.2.4

## Executive Summary

This is an ASP.NET MVC 5 web application using SQLite with Dapper, OWIN cookie authentication, and ASP.NET Identity 2.2.4. The application has **strong fundamentals** — all SQL queries are parameterized, CSRF protection is consistently applied, and Razor output encoding prevents XSS. However, there are **critical credential/data exposure issues** and several configuration weaknesses that need immediate attention.

---

## Critical Severity

### 1. Plain-text credentials committed to source control

**File:** `src/EventRegistrationSystem/App_Data/notes.txt`

```
admin@demo.com / Str0ngP@ssword
```

A valid admin credential is stored in plain text and tracked in git history. Even if deleted now, it persists in commit history.

**Remediation:** Delete the file, rotate the password immediately, and use `git filter-branch` or BFG Repo-Cleaner to purge from history.

### 2. Live SQLite database committed to git

**File:** `_db/EventRegistration.db`

The production database containing all user records and password hashes is tracked in version control. Anyone with repo access has the full user database.

**Remediation:** Remove from tracking, add `*.db` to `.gitignore` (currently commented out), and purge from git history.

### 3. Account lockout disabled — brute-force possible

**File:** `src/EventRegistrationSystem/Controllers/AccountController.cs`

```csharp
var result = await SignInManager.PasswordSignInAsync(
    model.Email, model.Password, model.RememberMe, shouldLockout: false);
```

Despite configuring lockout (5 attempts / 5-minute window) in `IdentityConfig.cs`, `shouldLockout: false` is passed at the login call site, completely negating the protection. The login endpoint is open to unlimited brute-force attempts.

**Remediation:** Change to `shouldLockout: true`.

### 4. `.env` file committed to repository

**File:** `src/EventRegistrationSystem/.env`

Contains a developer's local path with username and internal project structure. `.env` is not in `.gitignore`.

**Remediation:** Add `.env` to `.gitignore`, remove from tracking, purge from history.

---

## High Severity

### 5. No HTTPS/TLS anywhere

No TLS configuration exists in Web.config, IIS config, or the Dockerfile (which exposes only port 80). Authentication cookies and credentials are transmitted in cleartext.

**Remediation:** Configure HTTPS, add `RequireHttpsAttribute` as a global filter, set `CookieSecure = CookieSecureOption.Always`.

### 6. No security headers configured

No `X-Frame-Options`, `Content-Security-Policy`, `X-Content-Type-Options`, `Strict-Transport-Security`, or `Referrer-Policy` headers are set anywhere in the application — not in Web.config, OWIN middleware, or global filters.

**Impact:** Vulnerable to clickjacking, MIME-sniffing attacks, and missing defense-in-depth for XSS.

**Remediation:** Add to `Web.config` under `<system.webServer><httpProtocol><customHeaders>`:

```xml
<add name="X-Frame-Options" value="SAMEORIGIN" />
<add name="X-Content-Type-Options" value="nosniff" />
<add name="Content-Security-Policy" value="default-src 'self'" />
<add name="Referrer-Policy" value="strict-origin-when-cross-origin" />
```

### 7. Debug mode and no custom errors in production

`Web.config` has `compilation debug="true"` and no `<customErrors>` element. Stack traces, file paths, and internal details will be exposed to end users on errors.

**Remediation:** Ensure Release transforms set `debug="false"`, add `<customErrors mode="RemoteOnly" />`.

### 8. `User.IsInRole()` likely broken for authorization checks

**File:** `src/EventRegistrationSystem/Controllers/EventController.cs`

Inline checks like `User.IsInRole(Roles.Admin)` rely on role claims in the identity cookie. However, `GenerateUserIdentityAsync` in `IdentityModels.cs` does not add role claims, and roles are stored in a custom SQLite table (not via the standard Identity role store). These checks likely always return `false`, meaning resource-level admin protections in Edit/Delete actions are ineffective.

The `AuthorizeRolesAttribute` works correctly (it queries the DB directly), but the inline `IsInRole` checks do not.

**Remediation:** Add role claims in `GenerateUserIdentityAsync`, or replace inline `IsInRole` calls with `RoleRepository.UserIsInRole()`.

---

## Medium Severity

### 9. Auth cookie missing Secure and SameSite flags

**File:** `src/EventRegistrationSystem/App_Start/Startup.Auth.cs`

No `CookieSecure` or `CookieSameSite` properties are set on the cookie authentication options. The cookie will be sent over HTTP and is missing SameSite CSRF defense-in-depth.

**Remediation:** Set `CookieSecure = CookieSecureOption.Always` and add `SameSite = SameSiteMode.Strict` (or `Lax`).

### 10. Admin race condition on first registration

**File:** `src/EventRegistrationSystem/Controllers/AccountController.cs`

The first user to register gets Admin. The check (`COUNT(*) == 1`) runs after user creation. Concurrent registrations on a fresh database could grant Admin to multiple users.

**Remediation:** Use a database transaction with a lock or a separate initialization mechanism for the first admin account.

### 11. Partial views accessible as full URLs

`HomeController` actions `_FeaturedEvents`, `_Stats`, and `_UpcomingEvents` lack `[ChildActionOnly]`. They can be requested directly by unauthenticated users, leaking aggregate statistics and event data.

**Remediation:** Add the `[ChildActionOnly]` attribute to these actions.

### 12. Password reset is non-functional

`ForgotPassword` accepts the form and says "check your email," but the email service is a stub (`return Task.FromResult(0)`). Users have no password recovery path.

**Remediation:** Implement a real email service or clearly disable the password reset UI.

### 13. `DotEnvReader` crashes on missing `.env`

Throws `FileNotFoundException` in `Application_Start` if `.env` is absent, crashing the entire application startup.

**Remediation:** Gracefully skip if the `.env` file does not exist.

---

## Low Severity / Informational

| # | Finding | File/Location | Impact |
|---|---|---|---|
| 14 | No global `[ValidateAntiForgeryToken]` filter | `App_Start/FilterConfig.cs` | Future POST actions could miss the attribute (though all current ones have it) |
| 15 | `javascript:` URI in logout link | `Views/Shared/_LoginPartial.cshtml` | Would break under a strict CSP; code smell |
| 16 | Unused social auth packages (Facebook, Google, Twitter, Microsoft) | `packages.config` | Unnecessary attack surface in dependencies |
| 17 | No `<httpCookies>` directive in Web.config | `Web.config` | Missing belt-and-suspenders cookie protection |
| 18 | Sequential user IDs in seed data | `App_Data/seed-database.sql` | Predictable if applied to production |
| 19 | `EntityFramework` dependency listed but unused for data access | `packages.config` | Unnecessary dependency |

---

## Positive Findings

| Area | Status |
|---|---|
| **SQL Injection** | All 28 SQL queries use Dapper parameterized queries. Zero string concatenation or interpolation found. |
| **XSS** | Zero `@Html.Raw()` usage. All output uses Razor encoding. No `[AllowHtml]` attributes. |
| **CSRF** | All POST forms have `@Html.AntiForgeryToken()`. All POST actions have `[ValidateAntiForgeryToken]`. |
| **Request Validation** | ASP.NET default request validation is active (rejects HTML in form inputs). |
| **Password Policy** | Requires 6+ chars, upper, lower, digit, and special character. |
| **Authorization Architecture** | Clean RBAC with Admin/Organizer/User roles. Custom `AuthorizeRolesAttribute` queries DB directly. |

---

## Priority Remediation Order

1. **Immediate:** Remove credentials from repo, rotate passwords, purge git history (#1, #2, #4)
2. **Immediate:** Fix `shouldLockout: false` to `true` (#3)
3. **Before production:** Configure HTTPS and security headers (#5, #6)
4. **Before production:** Fix `User.IsInRole()` authorization gap (#8)
5. **Before production:** Disable debug mode, add custom errors (#7)
6. **Short-term:** Fix cookie security, race condition, partial view exposure (#9, #10, #11)
7. **Short-term:** Implement or disable password reset, fix `.env` crash (#12, #13)
