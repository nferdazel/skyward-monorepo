# Security Policy

Last reviewed on `2026-07-22`.

## Reporting a Vulnerability

If you discover a security vulnerability in Skyward, please report it responsibly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

Instead, please email: fredinix@proton.me

### What to include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### Response timeline:
- Acknowledgment within 48 hours
- Assessment within 1 week
- Fix or mitigation within 2 weeks (depending on severity)

## Current Security Posture

Skyward has undergone progressive security hardening (Phases 1-6):

- **Phase 1-3:** Supabase Auth cutover with synthetic emails, username-only UX
- **Phase 4:** Auth-bound gameplay RPC wrappers using `auth.uid()` — client no longer supplies `p_user_id`
- **Phase 5:** RLS enabled on app-facing read surfaces; auth-bound wrappers converted to SECURITY DEFINER
- **Phase 6:** Legacy custom-session functions and `sessions` table removed

All gameplay RPCs use auth-bound wrappers. Inner SECURITY DEFINER overloads
(with explicit `p_user_id`) have `REVOKE EXECUTE` from PUBLIC/anon; only the
auth-bound wrappers are granted to the `authenticated` role.

## Scope

This policy covers:
- The Flutter application code
- Supabase Auth integration
- Supabase database functions, triggers, and RLS policies
- Edge functions
- Scheduler / operational SQL surfaces that affect the live runtime
- CI/CD pipeline configuration

## Out of Scope
- Third-party dependencies (report to their respective maintainers)
- Social engineering attacks
- Physical security
