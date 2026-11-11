# ahbuddy

Windower 4 addon for Final Fantasy XI that searches the Auction House from the
chat line. See README.md for what it does and the command reference.

## Install (this machine)

Windower runs under the Lumoria flatpak. Its install is at:

```
/home/deck/.var/app/net.windower.Lumoria/data/prefixes/prefix-1/pfx/drive_c/Windower4/
```

The addon is installed as a symlink from that folder's `addons/` directory to
this repo, so edits here are live in game after a reload:

```
ln -s /home/deck/scm/github/delphyne/ahbuddy \
  /home/deck/.var/app/net.windower.Lumoria/data/prefixes/prefix-1/pfx/drive_c/Windower4/addons/ahbuddy
```

The sibling addons (Balloon, enemybar2) are symlinked the same way from
`~/scm/github/delphyne/windower-Lua/addons/`. Note that `windower-Lua` is a
source clone, not the install; the real addons folder is only the one above.

In game:

```
//lua load ahbuddy      (first load)
//lua reload ahbuddy    (after editing)
```

## Tests and lint

```
luajit test/test_ahbuddy.lua   # from the repo root; Windower is stubbed
luacheck .
```
