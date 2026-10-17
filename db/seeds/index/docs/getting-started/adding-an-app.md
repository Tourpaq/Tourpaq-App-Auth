---
title: Adding an app to this index
order: 10
summary: Open "Index content" on the admin host, fill in a form, save. It is live straight away.
---

Every card and every row on this site is one entry in the admin. There is
nothing to build and nothing to push: open **Index content** on the admin host
([admin.app](https://admin.app.journeybooking.eu/index)), choose **Add an
entry**, and save. The change is live the moment you do.

Editing is for the Tourpaq Auth admins.

## The fields

| Field | Required | Notes |
|---|---|---|
| Name | yes | Shown on the card and in search. |
| Description | yes | One sentence. Keep it to a line so the cards stay even. |
| Section | no | Which menu item it belongs under. Without one it shows on the front page under *Not yet in a group*. |
| Tied to an app | no | One of our apps in Tourpaq Auth: then only the people with access to it see the entry, with their role. |
| Visibility | no | For other entries: everyone signed in, or only the chosen groups. |
| URL | yes* | Where it runs. Becomes the **Open** button. |
| Address | yes* | A host name or IP range, e.g. the NetBird resource. Shown as text you can click to copy. |
| Access | no | How it's reached on the network — see below. |
| Login | no | How you sign in — see below. |
| Status | no | `live`, `beta`, `internal` or `retired`. |
| Owner | no | Who to ask about it. |
| Icon | no | A single emoji, or a link to an image. Without one you get an initials tile. |
| Repository | no | Adds a **Repo** button. |
| Order | no | Lower sorts first within the group. |

\* An entry needs at least one of a URL, an address or a link, so it points
somewhere. A database server has an address and no URL; a set of Grafana
dashboards can be links only.

## Sections, and who they are for

Sections are the menu. Each one has a **layout**:

- **Cards** — shown as cards on the front page. Put things here that anyone
  might open: our own apps, reports.
- **Table** — shown under *Technical* in the menu, each on a page of its own
  with a compact table and a filter box. Servers, databases, dashboards, log
  search and anything mostly used for support and development belong here.

And a **visibility**: everyone signed in, or only the chosen groups (the
technical sections start with DK Tech and RO DevOps). Add, rename or reorder
them under **Sections** in the admin.

## Access and login

Every entry says two things about getting in: how you reach it on the network,
and how you authenticate. Together they turn the index into an access overview
— useful when someone joins, and when someone leaves.

**Leave one out and the card says so** — `Access?` or `Login?` in a dashed
pill. That's deliberate: an entry nobody has recorded access for is exactly the
one worth asking about. The admin's overview page lists every entry with a gap.

Both lists are edited in the admin, under **Access levels** and **Login
methods**. Adding Tailscale, or a new login category, is a form, not a code
change. The *tone* colours the dot on the pill: ok (green), warn (amber),
danger (red) or neutral (grey). Use warn for anything that deserves a second
look — *Public access* carries it.

## Icons

An icon is optional. Give it a single emoji, or a link to an image — a favicon
or a logo both work. Images are fitted inside the tile rather than cropped, and
loaded without a referrer.

With no icon you get a dark tile with the first letters of the name — often
the tidiest option, and it never breaks. If a linked image disappears you get
an empty tile, so prefer a URL you control.

## Linking to more than one place

Some services are really several places: a Grafana with four dashboards you
actually open, a log search with three saved queries. Rather than one entry per
dashboard, add **Links** to the entry. They show as a short list on the card,
and on the details page.

Put the one you open most at the top. Four to six links is about where a card
stops being scannable — past that, the details page is the better home.

## The details page

Anything written under **Details page** becomes a page of its own, linked from
the card as **Details**. Use it for the things a new colleague would ask: what
it does, who uses it, how to run it locally, what breaks. It is markdown, so
`## Headings`, lists, links, tables and code blocks all work.
