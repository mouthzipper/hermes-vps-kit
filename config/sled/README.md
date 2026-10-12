Sled (https://github.com/layercodedev/sled) is cloned to ~/sled by bootstrap.sh.
- `pages.patch`: local change defaulting the new-agent workdir to `~/projects`. Applied with `git apply` if it still applies.
- `UPSTREAM_REV`: the upstream commit it was tested against.
- `dev.vars.example`: copy to `~/sled/app/.dev.vars` (contains no secrets on the reference box).
