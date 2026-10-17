---
title: App deployment
order: 10
summary: How to get an app you have built online, without needing to be a developer.
---

You have built something and you want it online at a proper web address, so
other people can use it. This page walks you through it.

You do not need to understand Docker, or write any code. The technical part is
one prompt you hand to Claude CoWork — copy it, paste it, and it prepares your
app for you. The rest is filling in a form.

Set aside about twenty minutes the first time.

## Before you start

- Your app, in a folder on your machine, working when you run it locally.
- Access to Coolify at [app.hetzner.tp](http://app.hetzner.tp). You need to be
  on the VPN to reach it — if the page doesn't load, that's usually why.
- A name for your app. Anything not already taken works.

It doesn't matter what your app is built with. React, plain HTML and
JavaScript, Rails, PHP, Python — the prompt below handles all of them.

## Step 1 — Let Claude prepare the app

Open your app's folder in Claude CoWork and paste this in. It works out what
your app is built with and sets everything up.

```text
I have a web app in this folder that I want to deploy on our Coolify server.
Please get the repository ready for deployment.

Work out which technology it uses — React, plain HTML and JavaScript, Rails,
PHP, Node, Python, anything — and then follow these house rules.

1. Create a Dockerfile.
   - Pin the base image to a specific version.
   - Build and run in separate stages where that makes the image smaller.
   - Run as a non-root user unless the app genuinely needs root.
   - If the app compiles to static files (React, Vue, plain HTML), build them
     and serve them with nginx.
   - Take the port from a PORT environment variable, and choose a free port
     above 1024.

2. Make the app answer /up with status 200 and a short body. Add that
   endpoint if it doesn't have one. It must be cheap — no database queries.

3. Add a HEALTHCHECK to the Dockerfile that polls /up. Give a slow-starting
   app a generous start period.

4. Create a docker-compose.yaml — that exact filename, not .yml.
   - restart: unless-stopped
   - expose the container port, and add a host mapping in the form
     "${WEB_PORT:-8000}:8000" so it can be switched off locally
   - List every environment variable explicitly under environment: using
     ${VAR} interpolation. Never use env_file:. Our Coolify host has no .env
     file, so env_file: would silently drop every secret.
   - Give defaults for ordinary variables, and no default for secrets, so a
     missing secret fails loudly instead of starting with a blank value.
   - Put anything that has to survive a redeploy — databases, uploaded files —
     in a named volume. A container's own filesystem is wiped on every deploy.
   - Repeat the healthcheck here.

5. Add a .dockerignore so .git, node_modules, virtual environments, local
   databases and .env never end up inside the image.

6. Set the folder up for git if it isn't already: git init -b main, a
   .gitignore covering build output, dependencies, local databases and .env,
   and a .gitattributes containing "* text=auto eol=lf". Then make the first
   commit. Check carefully that nothing secret is being committed.

7. Build the image, run it, and prove it actually works. The container must
   report "healthy", not merely "running".

When you are done, tell me in plain language:
- the port number I need to type into Coolify
- every environment variable I need to fill in there, and what each one is for
- anything you had to guess at, or that I should check
```

Claude will work through it and finish by telling you the port number and the
list of settings you need. **Keep that answer open** — you'll type those into
Coolify in step 3.

If it says it had to guess at something, read that part properly. It's usually
a question only you can answer, like which folder the finished website ends up
in.

## Step 2 — Put it on GitHub

Your code needs to live on GitHub so Coolify can fetch it. Ask Claude:

```text
Create a private GitHub repository for this app under the Tourpaq
organisation, add it as the remote, and push the main branch.
```

If that fails because you don't have permission to create repositories in the
organisation, ask a developer to create an empty one for you — then Claude can
push to it.

## Step 3 — Create it in Coolify

Go to [app.hetzner.tp](http://app.hetzner.tp) and:

1. **New Resource → Application**, and choose your repository from the list.
2. Set **Build pack** to **Docker Compose**, and the file to
   `docker-compose.yaml`.
3. In **Ports Exposes**, type the port number Claude gave you. Type it in
   yourself rather than leaving it blank — if Coolify has to guess, it often
   guesses wrong and the site shows an error page.
4. Under **Environment Variables**, add each variable Claude listed, with its
   value. This is where passwords and API keys go. They are stored securely
   here and are never in the code.
5. Under **Domains**, enter the web address you want — see the next step.
6. Turn on **Auto Deploy**, so the site updates itself whenever the code
   changes.

Then press **Deploy** and watch the log scroll past. The first deploy takes a
few minutes.

## Step 4 — Choose the web address

Every app here lives at:

```
https://<name>.app.journeybooking.eu
```

Pick any name that isn't already taken — `bookingmonitor`, `pricecheck`,
whatever describes it. **There is nothing to request and nobody to ask.** The
address works the moment you enter it, and the padlock in the browser works
too.

Two small habits worth keeping:

- Use the same name as the repository, so the address tells you where the code
  is.
- Check the [application index](/) first, to be sure the name is free.

## Step 5 — Add it to this index

The step everyone forgets. Add a card so colleagues can find your app, and so
there's a record of how it is reached and how you log in.

It's one short form: **Edit this site → Add an app or service**. See
[Adding an app to this index](../getting-started/adding-an-app.md).

## If something goes wrong

Deploys fail for ordinary reasons, and the log usually says which. Copy the
red part of the log out of Coolify and give it to Claude:

```text
My app failed to deploy on Coolify. Here is the log:

[paste the log here]

Please work out what went wrong and fix it in the repository.

Remember our house rules: environment variables are listed explicitly in
docker-compose.yaml with ${VAR} and never via env_file:; anything that must
survive a redeploy needs a named volume; and the app must answer /up.
```

The usual causes, in plain terms:

| What you see | What it usually means |
|---|---|
| Deploy fails while building | Something is missing from the code, or a password is needed to fetch it. |
| It starts, then stops, over and over | A setting is missing. Check the environment variables in step 3. |
| Stuck on "unhealthy" | The app is running but not answering `/up` — often just slow to start. |
| An error page at the web address | The port in **Ports Exposes** doesn't match the app's real port. |
| Passwords appear to be empty | Environment variables weren't filled in, or `env_file:` crept back in. |
| Data disappeared after an update | It was saved inside the container instead of a named volume. |
| Browser warns about the certificate | The address isn't under `app.journeybooking.eu`. |

If Claude can't sort it out in a couple of goes, ask a developer — take the
log with you.

## What the words mean

You'll see these in Coolify. None of them need to be understood deeply.

**Container** — your app boxed up with everything it needs to run, so it
behaves the same on your laptop and on the server.

**Image** — the boxed-up copy that gets built. A container is a running image.

**Deploy** — build a fresh image from the current code and swap it in for the
old one. Visitors don't notice.

**Environment variable** — a setting kept outside the code: a password, an API
key, a switch. Changing one means redeploying.

**Volume** — a storage cupboard that survives a deploy. Without one, anything
your app saves is thrown away next time it updates.

**Healthy** — the server has checked your app is genuinely answering, not just
switched on. Coolify waits for this before sending visitors to the new
version.
