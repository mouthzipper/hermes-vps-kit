Sled (https://github.com/layercodedev/sled) is cloned to ~/sled by bootstrap.sh.
- `pages.patch`: local change defaulting the new-agent workdir to `~/projects`. Applied with `git apply`; installation fails if it cannot apply cleanly.
- `UPSTREAM_REV`: the exact upstream commit checked out by bootstrap before `pnpm install --frozen-lockfile`. Review the patch and lockfile when bumping it.
- `dev.vars.example`: copy to `~/sled/app/.dev.vars` (contains no secrets on the reference box).
