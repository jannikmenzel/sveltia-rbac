# Role-Based Editing for Sveltia CMS on GitLab

Demo of **server-enforced, role-based editing** for a Git-backed CMS. [Sveltia CMS](https://github.com/sveltia/sveltia-cms) normally gives every repo collaborator full edit access — this repo adds a **GitLab pre-receive hook** that rejects any push violating per-file `edit_roles`, enforced by the Git server itself (not just the CMS UI, and not bypassable via a plain `git push` either).

Try it: [`pricing.md`](src/content/pages/pricing.md) is admin-only. An `editor` can push [`welcome.md`](src/content/pages/welcome.md), but a push to `pricing.md` gets rejected server-side.

## Repo structure

| Path                          | Purpose                                                                            |
|-------------------------------|------------------------------------------------------------------------------------|
| `src/content/pages/*.md`      | Demo content. `edit_roles` frontmatter per file.                                   |
| `src/config/roles/*.json`     | Role → GitLab usernames. Filename (no `.json`) = role name.                        |
| `scripts/pre-receive-hook.sh` | The server-side hook. `CONTENT_COLLECTIONS` there defines which paths get checked. |
| `public/admin/config.yml`     | Sveltia CMS config.                                                                |
| `src/content.config.ts`       | Astro content collection schemas (`edit_roles` field).                             |

## Permission model

- Only files matching `CONTENT_COLLECTIONS` (in the hook script) get an `edit_roles` check. Everything else → admin-only.
- New content file without `edit_roles` → any role may create it; the creator's role is tracked as owner (server-side `owners.tsv`, not in Git) and may edit/delete it afterwards, plus admin.
- `public/uploads/**`: anyone can upload; only admin or the uploader may change/delete an existing file.
- Changing `edit_roles` itself, or anything in `src/config/roles/`, is admin-only.
- New content collection: add its glob to `CONTENT_COLLECTIONS` in the hook, plus matching entries in `src/content.config.ts` and `config.yml`. `admin.astro` picks it up automatically.

## Setup

### 1. Configure

- Rename `src/config/roles/*.json` + contents to real GitLab usernames/roles.
- Update `public/admin/config.yml`: `repo`, `base_url`/`api_root`.
- In `scripts/pre-receive-hook.sh`, adjust the top-of-file variables:
  - `BRANCH` — your default branch (`main` / `master`).
  - `GITLAB_URL` — your GitLab instance's URL (only used as an API fallback when `GL_USERNAME` isn't set).
  - `CONTENT_COLLECTIONS` — glob patterns for the content paths that get an `edit_roles` check.

### 2. Install the hook

Self-managed GitLab only (Omnibus/Docker/source) — **not** GitLab.com, which has no server filesystem access. Installed straight into the project's **bare repo**, no instance-wide config needed.

Find the bare repo path (hashed storage):

```bash
sudo gitlab-rails runner \
  'puts Project.find_by_full_path("<namespace>/<project>")&.repository&.disk_path'
# Docker: docker exec <container> gitlab-rails runner '...'
```

→ `<hash>` in `/var/opt/gitlab/git-data/repositories/@hashed/<xx>/<yy>/<hash>.git`

Copy the script in:

```bash
REPO=/var/opt/gitlab/git-data/repositories/@hashed/<xx>/<yy>/<hash>.git
mkdir -p "$REPO/custom_hooks/pre-receive.d"
cp scripts/pre-receive-hook.sh "$REPO/custom_hooks/pre-receive.d/check-roles"
chmod +x "$REPO/custom_hooks/pre-receive.d/check-roles"
chown -R git:git "$REPO/custom_hooks"
```

Docker: prefix each command with `docker exec <container>` (use `docker cp` instead of `cp`).

### 3. Test

- Right role → push succeeds. Wrong role → `! [remote rejected] ... (pre-receive hook declined)`.
- Non-admin changing `edit_roles`, role config, or a file outside the content collections → rejected.
- New file without `edit_roles` → creator's role (+ admin) can edit/delete it afterwards; other roles can't.
- Upload to `public/uploads/` → anyone; edit/delete → only admin/uploader.

## Local test server (optional)

```bash
docker run -d --name gitlab-test -p 8929:8929 -p 2224:22 \
  -e GITLAB_OMNIBUS_CONFIG="external_url 'http://localhost:8929'; gitlab_rails['gitlab_shell_ssh_port']=2224" \
  gitlab/gitlab-ce:latest
```

Then follow steps 1–3 above against `http://localhost:8929`.

## License

[LICENSE](LICENSE).
