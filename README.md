# vps-setup

One interactive script that turns a **fresh Ubuntu 26.04 server** (tested on Vultr) into a secured Laravel host. It automates every step of my LEMP + Laravel setup guide.

It asks a few questions at the start, then does the rest on its own. It only pauses once, so you can add a deploy key on GitHub.

## What it sets up

| Area | What happens |
| --- | --- |
| System | Full `apt upgrade`, automatic daily security updates, 2 GB swap (if none exists) |
| Your user | New sudo user with your SSH public key |
| SSH | Root login **off**, password login **off** (also overrides Vultr's `50-cloud-init.conf`), checked with `sshd -T` |
| Firewall | UFW on: only SSH (22), HTTP (80) and HTTPS (443) allowed |
| PHP | Ubuntu's PHP-FPM (8.5 on 26.04) + Laravel extensions, PHP2Shell hardening settings |
| Composer | From Ubuntu |
| MySQL | MySQL 8.4, secured like `mysql_secure_installation`, plus a database and user for the app |
| Nginx | Installed, version number hidden, Laravel server block (runs only `index.php`) |
| Your app | Deploy key, `git clone`, `composer install`, `npm ci` + `npm run build`, `.env` (production, debug off), migrations, permissions, `php artisan optimize` |
| Domain | Optional. Without one, the site runs on `http://<server-ip>` |
| HTTPS | Let's Encrypt certificate with auto-renewal and HTTP to HTTPS redirect, only with a domain whose DNS already points at the server |
| Updates later | Writes `~/deploy-<app>.sh` for future deploys |

## Before you run it

1. **Create the server:** Vultr, Ubuntu 26.04 LTS. Adding your SSH key in the Vultr form is optional; the script can copy it from root, or you can paste it in.
2. **Domain (optional).** To get HTTPS straight away, point your domain's A record (`@`, and `www` if you want it) at the new server's IP first. No domain yet? Leave the question empty: the site runs on `http://<server-ip>`, and you can add the domain later (see below).
3. Have these ready:
   - your Mac's **public** SSH key (`cat ~/.ssh/id_farhan.pub`). No key yet? On your Mac, run `ssh-keygen -t ed25519 -f ~/.ssh/id_farhan` first; the script also shows these commands.
   - your repo's **SSH** address (`git@github.com:user/repo.git`)
   - an email address for Let's Encrypt

## Run it

Log in to the new server as root, then:

```bash
curl -fsSLO https://raw.githubusercontent.com/nanno619/vps-setup/main/setup.sh
less setup.sh            # read it first. Never pipe a script straight into bash.
sudo bash setup.sh
```

It takes about 10 minutes. The full log is saved to `/var/log/vps-setup.log`. The database password is shown once at the end and is **not** written to the log.

**Before closing the root window**, test your login from a new terminal on your Mac. The script prints the `~/.ssh/config` entry to use. If something is wrong, you can still fix it from the open window, or from Vultr's **View Console**.

## Adding a domain later

If you ran the script without a domain:

1. Point the domain's A record (`@`, and `www` if wanted) at the server's IP, and wait until `dig +short yourdomain.com` shows it.
2. Run `sudo bash setup.sh` again. Use the **same repo and app folder**, and this time enter the domain and say yes to HTTPS.

The script keeps your code and database. It adds an Nginx config for the domain, updates `APP_URL`, and gets the certificate. The IP-address config stays as a fallback.

## Deploying updates later

After you push new code, log in as your user and run:

```bash
~/deploy-<app>.sh
```

It puts the site into maintenance mode, then pulls, installs packages, builds the frontend, migrates, rebuilds caches and reloads PHP.

## Safe to re-run

If a step fails, fix the cause and run the script again. Finished steps are detected and skipped, and existing users, keys, databases, swap and code are left alone.

## Notes

- **No secrets live in this repo.** Passwords and keys are typed in or generated when the script runs.
- Requires your project to commit `package-lock.json`, so `npm ci` installs the same versions as your Mac. Keep your Mac and the server on the same Node.js major version (22 on Ubuntu 26.04).
- Only GitHub's host key is checked against a known fingerprint. For other Git hosts the script trusts the key on first connect and warns you.
