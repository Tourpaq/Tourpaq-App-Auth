---
name: Azure Cost Overview
description: Azure spend per month, reserved-instance coverage, VM inventory and migration planning.
url: https://azurecost.app.journeybooking.eu
app: azure-cost
category: Apps
status: internal
access: netbird
login: none
owner: Mogens
icon: https://azurecost.app.journeybooking.eu/favicon.svg
order: 10
---

Pulls cost and usage data from the Azure APIs into a local SQLite database and
presents it as monthly cost reports, reserved-instance coverage, VM inventory
and a migration planner.

## What it is good for

- Seeing what a month actually cost, split by consumption vs reservations.
- Spotting reserved instances that are about to expire.
- Planning VM family migrations and tracking which ones have been reviewed.

## Running it locally

```bash
cd "Azure cost overview/azure_cost_web"
bin/rails server
```

Data is refreshed by background jobs; the sidebar pill shows whether a fetch is
currently running. Credentials live in `.env` — see `.env.example`.
