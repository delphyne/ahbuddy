# ahbuddy

A [Windower 4](https://www.windower.net/) addon for Final Fantasy XI that
searches the Auction House from the chat line.

Instead of paging through the AH menus to find out whether something is for
sale and what it has been going for, type the item's name and get the answer
in the chat log: how many are up right now, singles and stacks, and the last
ten sales of each with date, price, seller and buyer. It is the same data the
in-game AH shows, fetched from the same place the game fetches it.

## What it does

- **Looks an item up by name.** `//ahbuddy fire crystal` finds the item in
  the game's own item list. Short and long names both work, case does not
  matter, and a partial name works when it matches only one item. When
  several items match, it lists them so you can be more specific.
- **Reports stock.** The number for sale on your world right now, as singles
  and, for stackable items, as stacks.
- **Reports price history.** The most recent sales of each form, newest
  first, with the price range across them. Three by default; `//ahbuddy
  results <n>` shows up to the ten the server keeps.
- **Asks your world's search server directly.** The game client fetches AH
  listings from a per-world search server, separate from the game server.
  ahbuddy speaks that protocol itself, so the answer is live and nothing is
  injected into the game.
- **Never stalls the game.** Network work runs on a non-blocking socket that is
  polled once per frame.

## Installation

1. Download or clone this repository into your Windower addons folder so that
   the file lives at `Windower/addons/ahbuddy/ahbuddy.lua`. The other `.lua`
   files in the folder must come with it.
2. In game, load the addon:

   ```
   //lua load ahbuddy
   ```

## Commands

`//ah` is a short alias for `//ahbuddy` in every command below.

```
//ahbuddy <item name>
```

Looks the item up. Names with spaces do not need quotes.

```
//ahbuddy results [n]          Show or set how many sales to list per form (1-10).
//ahbuddy server             Show the search server that will be asked.
//ahbuddy server <ip[:port]> Ask this server instead of your world's.
//ahbuddy server auto        Go back to picking the server from your world.
//ahbuddy debug [on|off]     Show or set extra reply details.
//ahbuddy help               List the commands.
```

## Configuration file

Settings are written to `data/settings.xml` inside the addon directory the
first time the addon loads.

- `server`: a search server to ask instead of the one for your world. Empty
  means automatic.
- `base_ip`: the first address of the block of sixteen world search servers.
  Your world's server is this address plus the world's position in the block.
  Only this needs changing if Square Enix moves the block.
- `timeout`: seconds to wait on each network step.
- `results`: how many of the most recent sales to show per form, 1 to 10.
- `debug`: print the AH category number with each lookup.

## How it works

The FFXI client talks to a search server on TCP port 54002 for `/search`,
linkshell lists and the Auction House. Each request is a small packet with an
MD5 trailer, encrypted with Blowfish using a client-specific round function
and a key derived from a random tail on the packet. ahbuddy implements that
in `searchserver.lua` (with `md5.lua` and the cipher tables in
`cipher_table.lua`) and sends one history request per item form. The reply
holds the current count for sale and up to ten sales.

The protocol layout follows the
[LandSandBoat](https://github.com/LandSandBoat/server) search server, which
mirrors retail, and the retail specifics were worked out by
[OmniWatch](https://github.com/BalladOfWorms/OmniWatch).

## Notes

- Stock and history are per world. The addon picks your world from the login
  data and maps it to its search server; use `//ahbuddy server` to check or
  override.
- The search server only knows items that can be sold on the AH. Anything
  else comes back with no stock and no sales.
