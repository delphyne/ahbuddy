# ahbuddy

Windower 4 addon for Final Fantasy XI that searches the Auction House from the
chat line. See README.md for what it does and the command reference.

## Install

Windower runs under the Lumoria flatpak. Its install is at:

```
~/.var/app/net.windower.Lumoria/data/prefixes/prefix-1/pfx/drive_c/Windower4/
```

The addon is installed as a symlink from that folder's `addons/` directory to
this repo, so edits here are live in game after a reload. The Makefile finds
the folder and makes the link:

```
make install                           # find Windower and symlink this repo
make install WINDOWER=/path/Windower4  # if it is somewhere else
make where                             # print the folder it would use
make uninstall                         # remove the symlink
```

`make install` refuses to replace a real directory at `addons/ahbuddy` (an
old clone, say). Move it aside first, keeping its `data/settings.xml` if the
settings matter; copy that file into this repo's gitignored `data/` folder.

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
make check                     # lint and tests
luajit test/test_ahbuddy.lua   # tests alone; Windower is stubbed
luacheck .                     # lint alone
```
