# DPM — NGE 2027 Resignation Register

A web-based register for Public Servants and Agency Heads who resign to
contest the 2027 Papua New Guinea National General Election, built for the
Department of Personnel Management (DPM), Reforms & Policy Branch.

This repository currently ships a **working front-end prototype**
(`index.html`) styled to match the DRBMS design system, plus everything
needed to move it off Claude's built-in artifact storage and onto a real,
DPM-controlled backend: **GitHub** for source control/hosting and
**Supabase** (managed Postgres + Auth) for the database.

> **Status:** prototype for internal DPM/TWT committee review — not yet
> connected to a production database. See [Current state vs. production](#current-state-vs-production)
> below before using this with real officers' records.

---

## What's in this repo

| File | Purpose |
|---|---|
| `index.html` | The application — dashboard, registers, new-registration form, audit log, feedback, security page. Currently reads/writes via Claude's `window.storage` artifact API. |
| `schema.sql` | Supabase/Postgres schema: tables, enums, indexes, triggers and row-level security policies that reproduce the role permissions already defined in the app's "Security & Safeguards" page. |
| `README.md` | This file. |

---

## Features

- **Two registers, one dataset** — Agency Heads and Public Servants, plus a
  combined, filterable view.
- **15-field Data Entry Matrix**, matching the existing DPM Excel matrices
  (category, name, designation, agency, institution category, province,
  electorate, party, resignation/received/acknowledgement dates, phone,
  email, subject, status, remarks).
- **Status workflow**: Received → Under Verification → Acknowledged →
  Released to PNGEC (or Withdrawn).
- **Dashboard** with live metrics and charts (status split, category split,
  by-province breakdown) via Chart.js.
- **Role-based permissions**: Administrator, Data Entry Officer, Verifying
  Officer, Read-only Viewer.
- **Audit log** of every create/update/delete/export/sign-in/sign-out.
- **Committee feedback** panel, visible to everyone reviewing the link.
- **CSV export** of the full register.

---

## Current state vs. production

The prototype's login is a name field + role chip — a role *selector* for
demo purposes, not real authentication, and its data store is Claude's
shared artifact storage rather than a DPM-owned database. Moving to
production means:

1. Standing up the Supabase project and applying `schema.sql` (below).
2. Replacing the artifact `window.storage` calls in `index.html` with the
   `supabase-js` client (see [Wiring the front end to Supabase](#wiring-the-front-end-to-supabase)).
3. Replacing the login screen with real Supabase Auth (email/password or
   magic link), with two-factor authentication added on top before this
   holds real officers' data.
4. Hosting the static front end somewhere DPM/ICT approves (GitHub Pages,
   Netlify, Vercel, or an internal server) with HTTPS enforced.
5. EM MIS/ICT sign-off on data residency, since Supabase is a third-party
   managed host — confirm this is acceptable for public-service resignation
   records, or plan a self-hosted Postgres instance instead (the same
   `schema.sql` applies to either).

---

## Setting up Supabase

1. Create a free project at [supabase.com](https://supabase.com).
2. In the Supabase dashboard, open **SQL Editor** → **New query**, paste in
   the contents of `schema.sql`, and run it. This creates:
   - `profiles` (extends `auth.users` with a `full_name` and `role`)
   - `resignation_records` (the register itself)
   - `audit_log`
   - `feedback`
   - Row-level security policies enforcing the four roles
   - A trigger that auto-creates a `profiles` row (defaulted to
     `Read-only Viewer`) whenever someone signs up
3. Under **Authentication → Providers**, enable the sign-in method you
   want (email/password to start; add an MFA/2FA requirement under
   **Authentication → Policies** before going live).
4. Once at least one officer has signed up, promote them to
   `Administrator` so they can manage roles for everyone else:

   ```sql
   update public.profiles set role = 'Administrator' where full_name = 'Officer Name';
   ```

5. Copy your **Project URL** and **anon public API key** from
   **Project Settings → API** — you'll need both in the front end.

---

## Wiring the front end to Supabase

`index.html` currently persists data through Claude's artifact storage:

```js
await window.storage.get(STORE_KEY, true);
await window.storage.set(STORE_KEY, JSON.stringify(records), true);
```

To run this as a standalone site, swap that layer for `supabase-js`. At a
high level:

```html
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script>
  const supabase = window.supabase.createClient(
    'https://YOUR-PROJECT.supabase.co',
    'YOUR-ANON-PUBLIC-KEY'
  );

  // fetch the register
  const { data: records } = await supabase
    .from('resignation_records')
    .select('*')
    .order('created_at', { ascending: false });

  // insert a new registration
  await supabase.from('resignation_records').insert({ ...rec });

  // update a status
  await supabase.from('resignation_records').update({ status: newStatus }).eq('id', id);

  // sign in
  await supabase.auth.signInWithPassword({ email, password });
  ```

Never put a **service_role** key in the front end — only the **anon**
key, which is safe to expose because row-level security (from
`schema.sql`) enforces who can do what.

If you'd like, I can also rewrite `index.html`'s storage and login
functions to call Supabase directly — happy to do that as a follow-up.

---

## Deploying

Any static host works, since `index.html` has no build step:

- **GitHub Pages** — push this repo, then enable Pages on the `main`
  branch in the repo's Settings.
- **Netlify / Vercel** — connect the repo and deploy with no build
  command (static site).
- **Internal DPM server** — copy `index.html` behind DPM's own HTTPS
  reverse proxy.

Set your Supabase URL/anon key directly in `index.html` for a quick start,
or inject them at build time via a hosting provider's environment
variables if you add a small build step later.

---

## Security notes

RLS policies in `schema.sql` reproduce this permission table exactly:

| Role | View registers | Add record | Edit status | Delete record |
|---|---|---|---|---|
| Administrator | Y | Y | Y | Y |
| Data Entry Officer | Y | Y | Y | — |
| Verifying Officer | Y | — | Y | — |
| Read-only Viewer | Y | — | — | — |

Additional items to confirm with DPM ICT / EM MIS before go-live:

- Enforce MFA/2FA on Supabase Auth.
- Turn on Supabase's automatic daily backups (or configure your own).
- Add a data-retention/disposal job for candidate records no longer
  needed after NGE 2027, per DPM records policy.
- Restrict the deployed URL to DPM/committee members only, if the
  hosting choice allows it (e.g. Netlify/Vercel access controls, or an
  internal-only server) rather than a fully public link.

---

## License / ownership

Internal DPM project — Reforms & Policy Branch, Legislative and
Administrative Reforms (L&AR) Division. Not for external distribution
until approved for production use.
