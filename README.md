# rp\_wp\_plesk\_two\_user

Harden a WordPress site on **Plesk (Linux)** by separating the **runtime user** (PHP-FPM) from the **deploy user** (code owner).
This script enforces a two-user model:

* **`site_runtime`** – the Plesk subscription **system user** that runs PHP-FPM.
* **`site_owner`** – a separate **deploy user** that owns the WordPress code and performs deployments (Git/SFTP/CI).

> 📘 **Full walkthrough & rationale:**
> Read the companion guide on our blog:
> [https://blogs.reliablepenguin.com/2025/09/09/how-to-lock-down-wordpress-on-plesk-with-a-two-user-model](https://blogs.reliablepenguin.com/2025/09/09/how-to-lock-down-wordpress-on-plesk-with-a-two-user-model)

The result: PHP can still write to **uploads** and **cache**, but **cannot** modify WordPress core, plugins, or themes.

> ⚠️ Tradeoff: WordPress **dashboard updates and plugin/theme installs no longer work**. Perform updates via deployments as `site_owner`.

---

## Features

* ✅ Keeps PHP-FPM running as the Plesk subscription user (`site_runtime`)
* ✅ Creates/adjusts a separate deploy user (`site_owner`) with shell `/bin/bash`
* ✅ Makes `site_owner` and `site_runtime` **share the same home** (`/var/www/vhosts/<domain>`)
* ✅ Grants `site_owner` **read + traverse (rx)** on the vhost home so `ls /var/www/vhosts/<domain>` works
* ✅ Sets `site_owner` as code owner for `httpdocs/` with safe perms (dirs `755`, files `644`)
* ✅ Prepares writable paths (default: `wp-content/uploads`, `wp-content/cache`)

  * group-sticky dirs (`chmod 2775`)
  * ACLs that grant `site_runtime` `rwX` + default inheritance
* ✅ Generates a **repair script** in `…/scripts/` to re-apply ownership/permissions/ACLs after Plesk “repairs”
* ✅ Idempotent, safe to re-run
* ✅ Handles NFS writable paths gracefully (ignores ACL errors where unsupported)

---

## Before you start

1. **Create the Plesk subscription** (this defines the runtime user)
   In Plesk, create the domain/subscription (**Websites & Domains → Add Domain**).
   The subscription’s **System user** is your **runtime user** (`site_runtime`) that runs PHP-FPM.
   The script assumes `/var/www/vhosts/<domain>` already exists.

2. **Install ACL tools (required)**
   Linux ACLs (`setfacl`, `getfacl`) are required to precisely grant rights.

   **Debian/Ubuntu**

   ```bash
   sudo apt-get update && sudo apt-get install -y acl
   ```

   **RHEL/CentOS/Rocky/Alma**

   ```bash
   sudo dnf install -y acl || sudo yum install -y acl
   ```

   **Amazon Linux**

   ```bash
   sudo dnf install -y acl || sudo yum install -y acl
   ```

   **SUSE / SLES**

   ```bash
   sudo zypper install -y acl
   ```

   Verify:

   ```bash
   setfacl --version && getfacl --version
   ```

   If you see **“Operation not supported”**, your filesystem mount may be missing ACL support. For **ext4**, remount with `acl` and persist in `/etc/fstab`:

   ```bash
   sudo mount -o remount,acl /var/www/vhosts
   # then add ",acl" to the options column for that filesystem in /etc/fstab
   ```

---

## Quick start

Download and run the setup script from this repo:

```bash
# Fetch the latest script (adjust branch/path if needed)
curl -fsSL -o wp_two_user_setup.sh \
  https://raw.githubusercontent.com/reliablepenguin/rp_wp_plesk_two_user/main/wp_two_user_setup.sh

# Harden a site called example.com
sudo bash wp_two_user_setup.sh -p example.com -r site_runtime -o site_owner
```

This will:

* ensure `site_owner` exists (`/bin/bash`, group `psacln`, home matches `site_runtime`),
* give `site_owner` **rx** on `/var/www/vhosts/<domain>`,
* set code ownership under `httpdocs/` to `site_owner:psacln` with safe perms,
* give `site_runtime` write access **only** to `uploads` and `cache`,
* create a repair script at `/var/www/vhosts/<domain>/scripts/wp_two_user_repair_<domain>.sh`.

---

## Usage

### Flags

```
sudo bash wp_two_user_setup.sh [OPTIONS]

Required:
  -r, --runtime-user USER     Plesk subscription system user (runs PHP-FPM)
  -o, --deploy-user  USER     Deploy user that will own the code

Target (choose one):
  -p, --domain DOMAIN         Domain (uses /var/www/vhosts/DOMAIN/httpdocs)
      OR
  -vhostroot PATH             Absolute path to vhost document root

Optional:
  -w, --writable "DIRS"       Space-separated list of writable dirs
                              (default: "wp-content/uploads wp-content/cache")
  --dry-run                   Print actions without making changes
  -h, --help                  Show help and exit
```

### Examples

**Domain-based (typical):**

```bash
sudo bash wp_two_user_setup.sh -p example.com -r site_runtime -o site_owner
```

**Custom docroot path:**

```bash
sudo bash wp_two_user_setup.sh -vhostroot /var/www/vhosts/example.com/httpdocs \
  -r site_runtime -o site_owner
```

**Add an extra writable path (e.g., `wp-content/media`):**

```bash
sudo bash wp_two_user_setup.sh -p example.com -r site_runtime -o site_owner \
  -w "wp-content/uploads wp-content/cache wp-content/media"
```

**Dry run (no changes):**

```bash
sudo bash wp_two_user_setup.sh -p example.com -r site_runtime -o site_owner --dry-run
```

---

## Generated repair script

After a successful run, you’ll have:

```
/var/www/vhosts/<domain>/scripts/wp_two_user_repair_<domain>.sh
```

Use it to quickly restore ownership/perms/ACLs after `plesk repair fs` or WPT actions:

```bash
sudo -u site_owner bash /var/www/vhosts/example.com/scripts/wp_two_user_repair_example.com.sh
```

**Cron (optional):** run weekly as `root`:

```bash
(crontab -l 2>/dev/null; echo '12 3 * * 1 sudo -u site_owner bash /var/www/vhosts/example.com/scripts/wp_two_user_repair_example.com.sh') | crontab -
```

---

## What the script does (in detail)

1. **Validates prerequisites**

   * Confirms `site_runtime` exists (created by Plesk).
   * Verifies ACL tools are installed and usable on the vhost home.

2. **Configures the deploy user (`site_owner`)**

   * Creates if missing; sets shell to `/bin/bash`.
   * Ensures membership in `psacln`.
   * Sets **home directory equal to the runtime home** (the subscription home).
   * Grants `site_owner` **rx** (read + traverse) ACL on the vhost home so listing works.

3. **Locks code ownership and permissions**

   * Recursively sets owner\:group on `httpdocs` to `site_owner:psacln`.
   * Sets directory perms to `755` and file perms to `644`.

4. **Prepares writable paths for PHP**

   * Ensures `wp-content/uploads` and `wp-content/cache` exist.
   * Sets owner\:group to `site_owner:psacln` and `chmod 2775` (group-sticky).
   * Applies ACLs granting `site_runtime` `rwX` with default inheritance.
   * **NFS note:** if these paths are NFS mounts, `setfacl` may say **“Operation not permitted.”** The script ignores those ACL errors and continues with `chown` + `chmod 2775`. Ensure your NFS export/umask keeps new files **group-writable**.

5. **Places a repair script in `…/scripts/`**

   * Re-applies the entire model, including the vhost-home `rx` ACL and writable path ACLs.

---

## Security model & expectations

* **Separation of duties:** `site_runtime` runs PHP; `site_owner` owns code.
* **Least privilege:** PHP writes only to necessary dirs; cannot modify code.
* **Operational tradeoff:** WordPress admin updates and plugin/theme installs are **disabled by design**. Use a deployment workflow (Git/SFTP/CI) as `site_owner`.

---

## Verification checklist

```bash
# 1) Who owns code?
ls -lad /var/www/vhosts/example.com/httpdocs
find /var/www/vhosts/example.com/httpdocs -maxdepth 1 -printf "%u:%g %m %p\n" | head

# 2) Can site_owner list the vhost home?
su -l site_owner -c 'ls -lad $HOME; ls -la $HOME | head'

# 3) Can PHP (site_runtime) write to uploads/cache?
sudo -u site_runtime bash -lc 'touch /var/www/vhosts/example.com/httpdocs/wp-content/uploads/test.txt && echo ok'
sudo -u site_runtime bash -lc 'rm -f /var/www/vhosts/example.com/httpdocs/wp-content/uploads/test.txt'
```

---

## Troubleshooting

* **`setfacl: Operation not supported` on vhost home**

  * Mount ACLs are likely disabled. Remount with `acl` (see *Before you start*).

* **`Operation not permitted` on `wp-content/uploads` (NFS)**

  * Expected on many NFS exports. Safe to ignore; script continues. Ensure NFS permissions/umask keep new files group-writable.

* **Plesk resets permissions**

  * Run the generated **repair** script under `…/scripts/`.

* **WordPress admin can’t install plugins/themes**

  * Expected. This model prevents PHP from writing code. Deploy changes as `site_owner`.

---

## Uninstall / Roll back (quick)

Return to Plesk defaults for a single site:

```bash
VHOSTROOT=/var/www/vhosts/example.com/httpdocs
# give runtime user ownership again
sudo chown -R site_runtime:psacln "$VHOSTROOT"
sudo find "$VHOSTROOT" -type d -exec chmod 755 {} \;
sudo find "$VHOSTROOT" -type f -exec chmod 644 {} \;

# optional: remove ACLs on writable dirs
sudo setfacl -bR "$VHOSTROOT/wp-content/uploads" 2>/dev/null || true
sudo setfacl -bR "$VHOSTROOT/wp-content/cache"   2>/dev/null || true
```

> You can keep the `site_owner` user for deployments, or remove it if you fully revert.

---

## Compatibility

* **OS**: Linux (Debian/Ubuntu, RHEL/CentOS/Rocky/Alma, Amazon Linux, SUSE)
* **Plesk**: Linux editions with PHP-FPM enabled per subscription
* **Filesystem**: Ext4/XFS recommended; ACLs required on the vhost home. NFS writable paths supported (ACLs may be ignored there).

---

## Contributing

Issues and PRs welcome! Please include:

* Plesk version, OS/distro, filesystem (ext4/xfs/nfs), and a brief reproduction.
* If your change affects behavior, update this README and the script help.

---

## License & Copyright

© 2025 Reliable Penguin, Inc. All rights reserved.
You may use and modify this script in your hosting environments.
Redistribution requires attribution to **Reliable Penguin**.

---

## Maintainers / Contact

* Reliable Penguin — [https://www.reliablepenguin.com](https://www.reliablepenguin.com)
