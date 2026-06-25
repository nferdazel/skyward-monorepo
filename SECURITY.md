# Security Policy

Last reviewed on `2026-06-26`.

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
