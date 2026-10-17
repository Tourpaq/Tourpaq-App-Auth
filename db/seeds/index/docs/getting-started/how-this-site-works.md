---
title: How this site works
order: 20
summary: The index is part of Tourpaq Auth, edited by its admins at admin.app.
---

The index is part of Tourpaq Auth, the sign-in for all our apps. Everything you
see — the cards, the groups, the access overview and these docs — lives in its
database and is edited in the browser on the admin host, under
[Index content](https://admin.app.journeybooking.eu/index).

## Where things are

- **The front page** shows the apps you have access to, with your role, and
  the groups shown as cards.
- **Technical** groups each have a page with a compact table and a filter box,
  built for long lists of servers and services.
- **Search** is in the menu on every page. Press `/` to jump to it; results
  appear as you type, and Enter opens the top one. It matches names,
  descriptions, host names, owners, groups and link labels.

## Who sees what

You sign in with your Microsoft account, through Tourpaq Auth. An app of ours
is shown only to the people with access to it. Every other entry, and every
group, is shown either to everyone signed in or only to the chosen groups.

## Who can edit

The Tourpaq Auth admins, on the admin host. A few things keep it safe:

- Deleting always asks first, and every change is in the audit log.
- Markdown is cleaned before it is shown, so pasted HTML cannot run script.
- Links must be ordinary web addresses (`https://…`, `http://…` or a path on
  this site).

## Under the hood

- Rails 8, PostgreSQL in production — the Tourpaq App Platform's shared server
  — and SQLite when running it locally.
- Deployed by Coolify from the Tourpaq-App-Auth repository. Code changes go
  through git; content changes don't need to.
