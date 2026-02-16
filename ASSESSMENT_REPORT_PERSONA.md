# Security Assessment Report

**Date**: 2026-02-16
**Assessor**: SECURITY_EXPERT
**Scope**: Full Application — Event Registration System (ASP.NET 4.8 / MVC 5 / SQLite)
**Framework**: OWASP ASVS Level 2, FISMA, FedRAMP, HIPAA
**Classification**: SENSITIVE — For authorized recipients only

---

## Executive Summary

The Event Registration System is an ASP.NET 4.8 MVC application using OWIN cookie authentication, Dapper ORM, and SQLite. The assessment identified **3 critical**, **5 high**, **7 medium**, and **6 low/informational** findings.

The application has a **fundamentally broken account lockout mechanism** that renders it completely vulnerable to brute-force credential attacks. Plaintext credentials are committed to source control alongside the live database file containing password hashes. The application lacks all standard security response headers and runs without TLS.

**Overall Risk Level: CRITICAL**

The application is **not suitable for production deployment** in its current state, particularly in any environment subject to FISMA, FedRAMP, or HIPAA compliance requirements. Critical and high findings must be remediated before any deployment.

---

## Risk Summary

| Severity | Count |
|----------|-------|
| Critical | 3 |
| High | 5 |
| Medium | 7 |
| Low/Info | 6 |

---

## Critical Findings

### VULN-001: Account Lockout Completely Broken — Brute-Force Attack Enabled

**Severity**: Critical
**CVSS**: 9.1 (AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:N)
**Location**: `Identity/SqliteUserStore.cs:241-248` and `Controllers/AccountController.cs:58`

**Description**:
Account lockout is configured in `IdentityConfig.cs` (5 attempts, 5-minute lockout) but is **completely non-functional** due to two independent bugs:

1. `IncrementAccessFailedCountAsync()` **resets** `AccessFailedCount` to `0` instead of incrementing it:
   ```csharp
   public Task<int> IncrementAccessFailedCountAsync(ApplicationUser user)
   {
       user.AccessFailedCount = 0; // BUG: should increment, not reset
       return Task.FromResult(0);
   }
   ```

2. `PasswordSignInAsync` is called with `shouldLockout: false`, independently disabling lockout:
   ```csharp
   var result = await SignInManager.PasswordSignInAsync(model.Email, model.Password, model.RememberMe, shouldLockout: false);
   ```

3. `GetAccessFailedCountAsync()` always returns `0` regardless of actual state (line 261).

4. `SetLockoutEnabledAsync()` always sets `LockoutEnabled = false` regardless of the `enabled` parameter (line 274).

**Impact**:
Unlimited brute-force password attacks are possible with no throttling or lockout. An attacker can automate credential stuffing or dictionary attacks against any account without detection or mitigation.

**Remediation**:
```csharp
public Task<int> IncrementAccessFailedCountAsync(ApplicationUser user)
{
    user.AccessFailedCount++;
    return Task.FromResult(user.AccessFailedCount);
}
```
Change `shouldLockout: false` to `shouldLockout: true` in `AccountController.Login`. Fix `GetAccessFailedCountAsync` to return `user.AccessFailedCount`. Fix `SetLockoutEnabledAsync` to use the `enabled` parameter.

**Compliance**: OWASP ASVS 2.2.1, NIST 800-53 AC-7, FISMA AC-7, HIPAA §164.312(d)

---

### VULN-002: Plaintext Credentials Committed to Source Control

**Severity**: Critical
**CVSS**: 9.0 (AV:N/AC:L/PR:L/UI:N/S:C/C:H/I:H/A:N)
**Location**: `App_Data/notes.txt:1`

**Description**:
Administrator credentials are stored in plaintext within the application directory:
```
admin@demo.com / Str0ngP@ssword
```

This file is tracked in Git and available to anyone with repository access.

**Impact**:
Complete administrative access compromise. Any developer, contractor, or person with repository access has immediate admin credentials. If the repository is ever made public or accessed by an unauthorized party, the system is fully compromised.

**Remediation**:
1. Immediately delete `App_Data/notes.txt` from the repository
2. Purge from Git history using `git filter-branch` or BFG Repo-Cleaner
3. Rotate all credentials immediately
4. Never store credentials in source control — use a secrets manager (Azure Key Vault, HashiCorp Vault)

**Compliance**: OWASP ASVS 2.10.4, NIST 800-53 IA-5, FISMA IA-5, HIPAA §164.312(d), FedRAMP IA-5

---

### VULN-003: Live Database with Password Hashes Committed to Git

**Severity**: Critical
**CVSS**: 9.0 (AV:N/AC:L/PR:L/UI:N/S:C/C:H/I:H/A:N)
**Location**: `_db/EventRegistration.db` (tracked in Git)

**Description**:
The production SQLite database file (`.db`) is committed to version control. The `.gitignore` excludes `*.sqlite` but not `*.db` (line 185: `# *.db` is commented out). This database contains:
- All user password hashes (PBKDF2 via ASP.NET Identity)
- User PII (emails, phone numbers)
- All application data

Additionally, `App_Data/seed-database.sql` contains known password hashes where all seeded users share the same password (`P@ssw0rd1!`).

**Impact**:
Anyone with repository access has the complete database including password hashes for offline cracking. The weak shared seed password means all initial accounts can be compromised trivially.

**Remediation**:
1. Uncomment `*.db` in `.gitignore`
2. Remove `EventRegistration.db` from Git tracking: `git rm --cached _db/EventRegistration.db`
3. Purge database from Git history
4. Rotate all user passwords
5. Remove seed SQL from the repository or use unique, strong passwords per user

**Compliance**: OWASP ASVS 2.10.4, NIST 800-53 SC-28, FISMA SC-28, HIPAA §164.312(a)(1), FedRAMP SC-28

---

## High Findings

### VULN-004: No Security Response Headers

**Severity**: High
**CVSS**: 7.4
**Location**: `Web.config:25-29` (`<system.webServer>`)

**Description**:
The application does not set any security response headers. Missing headers:

| Header | Risk |
|--------|------|
| `X-Frame-Options` | Clickjacking attacks |
| `Content-Security-Policy` | XSS via injected scripts/styles |
| `X-Content-Type-Options` | MIME-type sniffing attacks |
| `Strict-Transport-Security` | Downgrade to HTTP |
| `Referrer-Policy` | Referrer information leakage |
| `Permissions-Policy` | Unnecessary browser feature access |

**Remediation**:
Add to `Web.config` under `<system.webServer>`:
```xml
<httpProtocol>
  <customHeaders>
    <add name="X-Frame-Options" value="DENY" />
    <add name="X-Content-Type-Options" value="nosniff" />
    <add name="Content-Security-Policy" value="default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'" />
    <add name="Referrer-Policy" value="strict-origin-when-cross-origin" />
    <add name="Permissions-Policy" value="camera=(), microphone=(), geolocation=()" />
    <remove name="X-Powered-By" />
  </customHeaders>
</httpProtocol>
```

**Compliance**: OWASP ASVS 14.4.3-14.4.7, NIST 800-53 SC-8, FedRAMP SC-8

---

### VULN-005: Debug Mode Enabled / No Custom Error Pages

**Severity**: High
**CVSS**: 7.5
**Location**: `Web.config:22`, `Web.Release.config`

**Description**:
- `debug="true"` is set in `<compilation>` in the base `Web.config`
- No `<customErrors>` element exists anywhere — default mode is `RemoteOnly` but without a configured error page
- `Web.Release.config` only removes the `debug` attribute — it does not add `<customErrors mode="On">` or harden any other settings

In non-Release configurations, detailed stack traces, file paths, and framework version information are exposed to attackers on every unhandled exception.

**Remediation**:
Add to `Web.config`:
```xml
<customErrors mode="RemoteOnly" defaultRedirect="~/Error" />
```
Add to `Web.Release.config`:
```xml
<customErrors mode="On" defaultRedirect="~/Error"
  xdt:Transform="InsertIfMissing" />
```

**Compliance**: OWASP ASVS 14.1.3, NIST 800-53 SI-11, FISMA SI-11

---

### VULN-006: Password Hashes Exposed to Admin View Layer

**Severity**: High
**CVSS**: 7.1
**Location**: `Controllers/AdminController.cs:47-52`

**Description**:
The Admin `Users()` action fetches all columns from `AspNetUsers` including `PasswordHash` and `SecurityStamp`, and passes the full `ApplicationUser` objects to the Razor view:
```csharp
users = connection.Query<ApplicationUser>(@"
    SELECT Id, UserName, Email, EmailConfirmed, PasswordHash, SecurityStamp,
           PhoneNumber, PhoneNumberConfirmed, TwoFactorEnabled,
           LockoutEndDateUtc, LockoutEnabled, AccessFailedCount
    FROM AspNetUsers ORDER BY UserName").ToList();
```

Even if the view does not render these fields, they exist in the response pipeline and view model, accessible via debugging tools or a compromised view.

**Remediation**:
Create a dedicated `UserListViewModel` that excludes `PasswordHash` and `SecurityStamp`. Only SELECT the columns needed for display.

**Compliance**: OWASP ASVS 8.3.4, NIST 800-53 AC-4, HIPAA §164.312(a)(1) (minimum necessary)

---

### VULN-007: No TLS — HTTP-Only Transport

**Severity**: High
**CVSS**: 7.5
**Location**: `Dockerfile:36` (`EXPOSE 80`), `Web.config` (no HTTPS redirect or HSTS)

**Description**:
- Docker container exposes only port 80 (HTTP)
- No HTTPS redirect is configured
- No HSTS header is set
- Authentication cookies are transmitted in cleartext
- No `requireSSL="true"` on `<httpCookies>`

All credentials (login forms), session cookies, and PII (user data) are transmitted unencrypted.

**Remediation**:
1. Configure TLS termination (container-level or via reverse proxy)
2. Add `<httpCookies httpOnlyCookies="true" requireSSL="true" />` to `Web.config`
3. Set HSTS header
4. Add HTTPS redirect in `<rewrite>` rules or application startup

**Compliance**: OWASP ASVS 9.1.1, NIST 800-53 SC-8, FISMA SC-8, HIPAA §164.312(e)(1), FedRAMP SC-8

---

### VULN-008: `User.IsInRole()` Authorization Bypass Risk

**Severity**: High
**CVSS**: 8.1
**Location**: `Controllers/EventController.cs:84,104,129,147`

**Description**:
Resource-level authorization checks in `EventController` use `User.IsInRole(Roles.Admin)`:
```csharp
if (eventEntity.CreatedBy != userId && !User.IsInRole(Roles.Admin))
{
    return new HttpStatusCodeResult(System.Net.HttpStatusCode.Forbidden);
}
```

This relies on claims-based role resolution. However, the application uses a **custom role system** (`Roles`/`UserRoles` tables queried by `RoleRepository`) rather than ASP.NET Identity's standard `AspNetRoles`/`AspNetUserRoles`. The `AuthorizeRolesAttribute` correctly queries the database, but `User.IsInRole()` checks the `ClaimsIdentity` — and the custom `SqliteUserStore` does not implement `IUserRoleStore<>`, so role claims may not be populated during `CreateIdentityAsync`.

If role claims are not populated at sign-in time, `User.IsInRole("Admin")` will **always return `false`**, meaning:
- Admin users cannot edit/delete events they didn't create
- The admin bypass is silently broken

Conversely, if claims could be manipulated, non-admins might bypass ownership checks.

**Remediation**:
Replace `User.IsInRole()` calls with the same `IRoleRepository.UserIsInRole()` pattern used by `AuthorizeRolesAttribute`, or implement `IUserRoleStore<ApplicationUser>` on `SqliteUserStore` to populate role claims.

**Compliance**: OWASP ASVS 4.1.2, NIST 800-53 AC-3

---

## Medium Findings

### VULN-009: `.env` File Committed to Git with Developer Information

**Severity**: Medium
**CVSS**: 5.3
**Location**: `src/EventRegistrationSystem/.env`

**Description**:
The `.env` file is tracked in Git and contains a developer's local Windows path including their username:
```
DatabasePath=C:\Users\carlosbaptiste\source\repos\CVP-projects\franklin-dev-niaid\use-case1\aspnet48-sample\_db\EventRegistration.db
```
`.env` is not listed in `.gitignore`.

**Impact**: Information disclosure of developer identity, internal project structure, and organization naming conventions. The path reveals this is a CVP/NIAID government project.

**Remediation**: Add `.env` to `.gitignore`. Remove from Git tracking. Use environment variables or a secrets manager for deployment configuration.

**Compliance**: OWASP ASVS 14.3.3, NIST 800-53 SC-28

---

### VULN-010: Authentication Cookies Not Secured

**Severity**: Medium
**CVSS**: 5.4
**Location**: `App_Start/Startup.Auth.cs`, `Web.config`

**Description**:
- No `<httpCookies httpOnlyCookies="true" requireSSL="true" />` in `Web.config`
- OWIN cookie configuration does not explicitly set `CookieSecure = CookieSecureOption.Always`
- Authentication cookies can be transmitted over HTTP and may be vulnerable to interception

**Remediation**:
Add to `Web.config`:
```xml
<httpCookies httpOnlyCookies="true" requireSSL="true" />
```
In `Startup.Auth.cs`, add `CookieSecure = CookieSecureOption.Always` to the cookie authentication options.

**Compliance**: OWASP ASVS 3.4.1, NIST 800-53 SC-23, HIPAA §164.312(e)(1)

---

### VULN-011: Weak Minimum Password Length

**Severity**: Medium
**CVSS**: 5.3
**Location**: `App_Start/IdentityConfig.cs`

**Description**:
Minimum password length is set to 6 characters. Current NIST SP 800-63B guidelines recommend a minimum of 8 characters, with 12+ preferred for privileged accounts.

**Remediation**: Increase `RequiredLength` to at least 8 (12+ recommended). Consider adding checks against known breached password lists.

**Compliance**: OWASP ASVS 2.1.1, NIST 800-63B §5.1.1, FISMA IA-5

---

### VULN-012: Security Stamp Validation Interval Too Long

**Severity**: Medium
**CVSS**: 5.0
**Location**: `App_Start/Startup.Auth.cs`

**Description**:
The security stamp validation interval is 30 minutes. If an account is compromised and the password is changed, the attacker's existing session remains valid for up to 30 minutes.

**Remediation**: Reduce to 5 minutes or less for applications handling sensitive data: `validateInterval: TimeSpan.FromMinutes(5)`.

**Compliance**: OWASP ASVS 3.3.1, NIST 800-53 AC-12

---

### VULN-013: No Rate Limiting on Authentication Endpoints

**Severity**: Medium
**CVSS**: 5.3
**Location**: `Controllers/AccountController.cs` — `/Account/Login`, `/Account/Register`

**Description**:
There is no rate limiting on login or registration endpoints. Combined with the broken lockout (VULN-001), this allows unlimited automated attack attempts.

**Remediation**: Implement rate limiting via middleware, IIS Dynamic IP Restrictions, or an application-level throttle (e.g., per-IP attempt tracking with exponential backoff).

**Compliance**: OWASP ASVS 2.2.1, NIST 800-53 AC-7, SC-5

---

### VULN-014: First-User Admin Race Condition

**Severity**: Medium
**CVSS**: 6.2
**Location**: `Controllers/AccountController.cs:140-153`

**Description**:
The first registered user is automatically elevated to Admin. The check uses `GetUserCountAsync() == 1` after the user is already created. Two simultaneous registrations could both see `count == 1` (TOCTOU race condition), resulting in two admin accounts.

Additionally, the registration endpoint is public (`[AllowAnonymous]`) with no CAPTCHA or human verification, making automated registration possible.

**Remediation**:
1. Use a database-level lock or transaction to ensure atomicity
2. Consider a dedicated admin setup process rather than auto-elevation
3. Add CAPTCHA to registration

**Compliance**: OWASP ASVS 4.1.1, NIST 800-53 AC-6

---

### VULN-015: `DotEnvReader` Fragile Parsing

**Severity**: Medium
**CVSS**: 4.3
**Location**: `Utils/DotEnvReader.cs`

**Description**:
The `.env` file parser splits lines on `=` into exactly 2 parts. Values containing `=` (e.g., base64-encoded secrets, connection strings with parameters) will be silently truncated, potentially leading to misconfiguration or broken functionality.

**Remediation**: Split only on the first `=` occurrence: `line.Split(new[] { '=' }, 2)`.

**Compliance**: OWASP ASVS 14.2.1

---

## Low / Informational Findings

### VULN-016: Outdated Dependencies
**Severity**: Low | **Location**: `packages.config`

ASP.NET Identity 2.2.4 (last updated ~2015), Modernizr 2.8.3 (2013), and WebGrease 1.6.0 (2014) are outdated. While no specific CVEs were identified during this assessment, unmaintained libraries pose ongoing risk. EF 6.5.1 is referenced but unused — unnecessary attack surface.

**Compliance**: OWASP ASVS 14.2.1, NIST 800-53 SI-2

---

### VULN-017: Partial View Actions Directly Accessible
**Severity**: Info | **Location**: `Controllers/HomeController.cs`

`_FeaturedEvents`, `_Stats`, and `_UpcomingEvents` are intended as partial views but are accessible as standalone HTTP endpoints, returning fragment HTML.

**Remediation**: Add `[ChildActionOnly]` attribute to partial view actions.

---

### VULN-018: `X-Powered-By` Header Not Removed
**Severity**: Low | **Location**: IIS default configuration

IIS sends `X-Powered-By: ASP.NET` by default, disclosing the server technology stack.

**Remediation**: Add `<remove name="X-Powered-By" />` to `<customHeaders>` in `Web.config`.

---

### VULN-019: No Audit Logging
**Severity**: Low | **Location**: Application-wide

No audit trail exists for authentication events (login, failed login, password change, role changes) or administrative actions. This is a FISMA and HIPAA requirement.

**Compliance**: NIST 800-53 AU-2, AU-3, FISMA AU-2, HIPAA §164.312(b)

---

### VULN-020: No Input Sanitization on Event Content
**Severity**: Low | **Location**: `Controllers/EventController.cs`

Event descriptions and titles are stored and rendered without explicit output encoding verification. ASP.NET MVC Razor provides default HTML encoding, but rich-text scenarios or `Html.Raw()` usage in views could introduce XSS. Anti-forgery tokens are correctly applied on all POST actions.

---

### VULN-021: Unused External OAuth Provider Packages
**Severity**: Info | **Location**: `packages.config`

Facebook, Twitter, Google, and Microsoft OAuth NuGet packages are included but the providers are commented out in `Startup.Auth.cs`. Unused packages increase the attack surface.

**Remediation**: Remove unused OAuth packages from `packages.config` and the project.

---

## Remediation Priority

| Priority | Finding | Severity | Timeline |
|----------|---------|----------|----------|
| 1 | VULN-001 — Broken Account Lockout | Critical | **Immediate** |
| 2 | VULN-002 — Plaintext Credentials in Git | Critical | **Immediate** |
| 3 | VULN-003 — Database in Git | Critical | **Immediate** |
| 4 | VULN-007 — No TLS | High | **Before deployment** |
| 5 | VULN-008 — IsInRole() Bypass | High | **Before deployment** |
| 6 | VULN-004 — No Security Headers | High | **Before deployment** |
| 7 | VULN-005 — Debug Mode / Error Pages | High | **Before deployment** |
| 8 | VULN-006 — PasswordHash in View | High | **Before deployment** |
| 9 | VULN-009 — .env in Git | Medium | **Next sprint** |
| 10 | VULN-010 — Cookie Security | Medium | **Next sprint** |
| 11 | VULN-011 — Weak Password Length | Medium | **Next sprint** |
| 12 | VULN-012 — Stamp Validation Interval | Medium | **Next sprint** |
| 13 | VULN-013 — No Rate Limiting | Medium | **Next sprint** |
| 14 | VULN-014 — Admin Race Condition | Medium | **Next sprint** |
| 15 | VULN-015 — DotEnvReader Parsing | Medium | **Next sprint** |
| 16-21 | Low/Info findings | Low/Info | **Backlog** |

---

## Compliance Status

### FISMA

| Control | Status | Finding |
|---------|--------|---------|
| AC-3 (Access Enforcement) | **FAIL** | VULN-008: Authorization bypass risk |
| AC-7 (Unsuccessful Logon Attempts) | **FAIL** | VULN-001: Lockout broken |
| AC-12 (Session Termination) | **PARTIAL** | VULN-012: 30-min stamp validation |
| AU-2 (Audit Events) | **FAIL** | VULN-019: No audit logging |
| IA-5 (Authenticator Management) | **FAIL** | VULN-002, VULN-011: Plaintext creds, weak policy |
| SC-8 (Transmission Confidentiality) | **FAIL** | VULN-007: HTTP only |
| SC-28 (Protection of Information at Rest) | **FAIL** | VULN-003: DB in Git |
| SI-2 (Flaw Remediation) | **PARTIAL** | VULN-016: Outdated deps |
| SI-11 (Error Handling) | **FAIL** | VULN-005: Debug mode, verbose errors |

### FedRAMP

| Control | Status | Finding |
|---------|--------|---------|
| AC-7 | **FAIL** | VULN-001 |
| IA-5 | **FAIL** | VULN-002 |
| SC-8 | **FAIL** | VULN-007 |
| SC-28 | **FAIL** | VULN-003 |

### HIPAA Security Rule

| Requirement | Status | Finding |
|-------------|--------|---------|
| §164.312(a)(1) Access Control | **FAIL** | VULN-006, VULN-008 |
| §164.312(b) Audit Controls | **FAIL** | VULN-019 |
| §164.312(d) Authentication | **FAIL** | VULN-001, VULN-002 |
| §164.312(e)(1) Transmission Security | **FAIL** | VULN-007, VULN-010 |

---

## Positive Findings

The following security practices were correctly implemented:

1. **Anti-forgery tokens**: `[ValidateAntiForgeryToken]` is applied to all POST actions across all controllers
2. **Parameterized queries**: All Dapper queries use parameterized parameters — no SQL injection vectors found
3. **Open redirect prevention**: `Url.IsLocalUrl()` is correctly used in `RedirectToLocal()`
4. **User enumeration prevention**: `ForgotPassword` and `ResetPassword` do not reveal whether a user exists
5. **Role-based access control**: `AuthorizeRolesAttribute` correctly queries the database for role membership
6. **Resource ownership checks**: Event edit/delete operations verify creator ownership
7. **Last-admin protection**: `AdminController.RemoveFromRole` prevents removing the last administrator
8. **Password hashing**: ASP.NET Identity PBKDF2 hashing is used (not plaintext or weak hashing)
9. **Model validation**: Data annotations are used for input validation on all view models

---

## Methodology

This assessment was conducted using:
- **OWASP ASVS Level 2** — Standard security verification
- **OWASP Top 10 2021** — Common web application risks
- **STRIDE Threat Modeling** — Threat identification
- **NIST SP 800-53 Rev 5** — Security controls (FISMA/FedRAMP)
- **HIPAA Security Rule** — Healthcare data protection requirements

Assessment type: Static code review and configuration analysis (no dynamic/runtime testing performed).

---

*Report prepared by SECURITY_EXPERT. Full remediation guidance available upon request.*
