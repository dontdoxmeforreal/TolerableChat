# TolerableChat

A chat filter for **WoW Forever** that keeps chat quiet and game-focused. It hides politics,
religion, streamer talk, bigotry, harassment and the arguments around them, while groups, trades,
dungeon runs and other game talk still come through. It can also mute every member of the guilds you
choose, finding them with `/who` as you play.

Everything happens on your screen only. TolerableChat never changes your ignore list, never tells
anyone they're muted and never reports anyone by itself (the Log tab's **Report** button opens the
game's own report window, if you choose to).

**Other pages:** [FILTERS.md](FILTERS.md) (what's hidden and why) · [TERMS.md](TERMS.md) (every
built-in word) · [ARCHITECTURE.md](ARCHITECTURE.md) (for developers)

---

## Contents

- [Installing](#installing)
- [Getting started](#getting-started)
- [What it hides](#what-it-hides)
- [Muting players and guilds](#muting-players-and-guilds)
- [A guild was muted by mistake](#a-guild-was-muted-by-mistake)
- [Finding members of muted guilds: the guild sweep](#finding-members-of-muted-guilds-the-guild-sweep)
- [Muted players can't bother you](#muted-players-cant-bother-you)
- [The window, tab by tab](#the-window-tab-by-tab)
- [Right-click menu](#right-click-menu)
- [Slash commands](#slash-commands)
- [Sharing lists with your guild](#sharing-lists-with-your-guild)
- [Your data, and playing on several realms](#your-data-and-playing-on-several-realms)
- [Troubleshooting](#troubleshooting)
- [Limits worth knowing](#limits-worth-knowing)
- [Optional: OlympusNet](#optional-olympusnet)
- [Credits and licences](#credits-and-licences)
- [For developers](#for-developers)

---

## Installing

1. **Exit the game.**
2. Download the TolerableChat zip and open it. Inside is one folder, `TolerableChat`.
3. Copy that folder into the AddOns folder of your WoW Forever install:

   ```
   World of Warcraft\<Forever folder>\Interface\AddOns\TolerableChat\TolerableChat.toc
   ```

   `<Forever folder>` is the folder the launcher put WoW Forever in, the one with `Interface` and
   `WTF` inside it (the beta used `_classic_beta_`).

   The `.toc` file must sit directly inside `AddOns\TolerableChat\`, not in
   `AddOns\TolerableChat-1.0.1\` and not in `AddOns\TolerableChat\TolerableChat\`. If WoW doesn't
   list the addon, this is almost always why.
4. Start the game. On the character screen, **AddOns** should list TolerableChat, ticked.
   If it says "out of date", tick **Load out of date AddOns**.

**Updating:** exit the game, delete the old `TolerableChat` folder, copy the new one in. Your lists
and settings are kept (they're saved elsewhere, see [Your data](#your-data-and-playing-on-several-realms)).

---

## Getting started

- Open the window with **`/tc`**, a key binding (game menu → Key Bindings → *Toggle TolerableChat*),
  the **Open TolerableChat** button in Settings → AddOns, or the AddOn Compartment button by the
  minimap if your client has one.
- It works straight away with sensible defaults. The **Overview** tab says what's being hidden.
- Hover over any line in the **Log** tab to see exactly why it was hidden.
- Something got through that shouldn't have? Right-click the sender's name → **Flag message**.
- Something hidden that shouldn't be? In the **Log** tab, flag it as wrongly hidden.
- Type **`/tc test some text`** to see whether a message would be hidden, and why.

**Never hidden:** your own messages, GM messages, your friends, your guild (in other channels too),
and everyone in your group or raid. Party, raid and guild chat themselves are never filtered.
Whispers aren't word-filtered either, unless you tick Whispers on the Filter tab; muted players'
whispers are hidden anyway.

---

## What it hides

**[FILTERS.md](FILTERS.md)** explains every category in plain words, and why some topics (politics,
religion, nationality, LGBT and identity talk) are hidden at all: not because they're bad, but
because public game chat isn't where those conversations go well. **[TERMS.md](TERMS.md)** lists
every built-in word and phrase.

### Categories

Every term belongs to a category. For each category you choose what a match does (Filter tab):

- **Mute Forever**: mute that player; everything from them is hidden from then on.
- **Timeout**: hide the message, and that player's other messages for the Timeout Duration (below),
  unless they're about the game.
- **Hide Only**: hide just that message.
- **Off**: don't check this category.

| Category | Covers | Default |
|---|---|---|
| Streamers | Streamer and stream-drama talk, streamer events like OnlyFangs | Timeout |
| Politics | Parties, politicians, pundits, elections, hot-button issues, slogans and insults of every side, LGBT and identity topics, plain Nazi mentions | Timeout |
| Nationality | Countries, continents, regions (EU, UK), US states and the people from them, nationalist slogans; even when used for time zones | Timeout |
| Religion | Religions, scripture, preaching | Timeout |
| Sexual | Crude sexual words (whole words only) | Timeout |
| Bigotry | Racial, ethnic and anti-LGBT slurs in any spelling, hate slogans, Nazi salutes, antisemitic phrases and tropes, mocking names for LGBT people, "go back to your country", hateful dog whistles | Mute Forever |
| Harassment | "kys", "kill yourself", "hang yourself" and the like (not game advice like "you'll kill yourself pulling that") | Timeout |
| Dead Horses | Jokes everyone has heard: Thunderfury, Mankrik (quest questions included), Chuck Norris | Hide Only |
| Custom | Your own terms | Timeout |

Terms match whole words and phrases. Spelling tricks are undone first: `t.r.u.m.p`, `t-r-u-m-p`,
`p0litics`, `7rump`, `b!den`, accents (`trümp`), look-alike Cyrillic or Greek letters, fullwidth
letters, invisible characters, a plural z (`commiez`) and a number stuck to a word (`biden2024`,
`2028trump`). Words of 5+ letters are also caught
starred (`pol*tics`, at most half the letters) or stretched (`poliitical`), and the worst slurs are
stems that catch every ending and run-together form. Game names that happen to contain a term are
protected: an item, spell, NPC or quest name, or a transmute request like "LF alch to trans
arcanite", is never hidden because of a word inside it.

**Changing the lists:** Filter tab → **Edit terms…** shows every term with a search box, a category
filter and a tick box per term: untick one to switch it off, or add your own. Built-in terms can be
switched off but not deleted, so an update never brings back one you switched off. `/tc term` does
the same in chat.

**Starting your own list from scratch:** **Turn off built-in terms** (bottom of the Edit terms…
window) switches every built-in term off at once, after asking, so only the terms you add filter
chat. Your own terms, guild words and settings stay. The same button then reads **Turn built-in
terms on** and brings them all back.

Each term has a match type, shown next to it (hover a term for what it matches):

| Match | Like | Example |
|---|---|---|
| **Whole word** | `\btrump\b` | `trump`, `t.r.u.m.p`, `trump2028`; not `trumpet` |
| **Exact text** | the text, spaces included | ` eu ` (with the spaces) |
| **Anywhere** | the text with no `\b` | `cat` also in `category` |
| **All of** | every comma-separated part, any order | `free, gold` |
| **Pattern** | a Lua pattern (like a simple regular expression) | `%f[%w]immigra` (immigrant, immigration…) |

Every type is checked after spelling tricks are undone. When you add a term, the **Match:** button at
the bottom of the window picks its type, and the line above it says what that type does. Hover a
term in the list for what it matches.

**Patterns** are Lua patterns, the closest thing WoW addons have to regular expressions. They run on
the lowercased message, after spelling tricks are undone:

| Write | Means | Regex equivalent |
|---|---|---|
| `%f[%w]` | the start of a word | `\b` before a word |
| `%f[^%w]` | the end of a word | `\b` after a word |
| `%a`, `%d`, `%w` | a letter, a digit, a letter or digit | `[a-z]`, `\d`, `\w` (without `_`) |
| `[a@4]`, `[^%w]` | any one of a, @, 4; anything but a letter or digit | the same |
| `.` | any character | the same |
| `+`, `*`, `?` | one or more, zero or more, optional | the same |
| `-` | zero or more, as few as possible | `*?` |
| `^`, `$` | the start and end of the whole message | the same |

What Lua patterns don't have, and the editor refuses with a message saying what to do instead:

- **Either/or** (`trump|biden`): add one term for each alternative.
- **Counts** (`o{2,3}`): repeat the part (`ooo?`) or use `+`.
- **Lookahead, lookbehind and regex escapes** (`(?=`, `\b`, `\d`): use `%f[%w]`, `%d` and friends.
- **Capital classes** such as `%W`: the text is lowercased first, so write `[^%w]`.

TolerableChat also keeps patterns cheap, because each one runs on every chat line: at most 2
open-ended parts (`%a+`, `.-`) and 10 optional ones (`x?`). Patterns aren't accepted from guild
shares; pass them on with **Export my lists…** and **Import lists…**.


### Timeouts (30 minutes by default)

A message hidden by a **Timeout** category puts its sender in a timeout: their other messages from
30 minutes before to 30 minutes after are hidden too, so the replies and follow-ups of an argument
disappear with it. The length is the **Timeout Duration** on the Filter tab (5 to 120 minutes).
**Game talk still gets through**: groups, trades, dungeons, item links. The exception is a
sender who is clearly spamming (3 or more hidden messages in the window, or 5 messages in
2 minutes), whose WTS/WTB posts are hidden as well.

Hide Only categories (Dead Horses by default) and meme words never start a timeout; they only hide
that one message.

### Symbol and script spam

ASCII art, braille art and box-drawing walls, and messages mostly in another script (Chinese,
Korean, Cyrillic and so on) are hidden. A message counts when more than 80% of it isn't letters,
digits or emoji; "..." or a single "?" never counts. A word mixing Latin letters with Cyrillic or
Greek look-alikes is hidden too, a trick gold sellers' ads use ("FАSТ LЕVЕLІNG").

### Meme word mute

When a joke goes round (everyone posting murloc memes), the **Overview** tab lists the 3 words most
shared by the last 50 messages, each with **Mute 30 min** and **Mute 4 hours**. Muting a word also
removes the lines with it from the last 30 minutes. A muted word comes back by itself, so you can
still talk about murlocs later. Everyday words never count.

---

## Muting players and guilds

- **By hand:** right-click a name → **Mute**, or `/tc mute Name`. Their earlier lines vanish too.
- **Your game ignore list carries over:** anyone on it who isn't muted here is muted, quietly, on all
  your characters on that realm. That's the only connection: TolerableChat never adds to or removes
  from the game's ignore list, and unignoring someone in the game changes nothing here (unmute them
  on the People tab). The game's ignore keeps working on its own: it also hides them in party, raid
  and guild chat, and tells them "is ignoring you" when they whisper you; TolerableChat's **Mute**
  never tells anyone. Settings has a switch.
- **For 2 hours:** right-click → **Mute for 2 hours**, for someone mildly annoying.
- **Automatically:** a term in a Mute Forever category (Bigotry, by default) mutes the sender. The
  **Auto-mutes** tab lists every one so you can review (and undo) them. When an update stops a word
  from muting, the auto-mutes it made are judged again at the next login and lifted unless the
  player's message also had a word that still mutes; **Re-check against the lists** on that tab does
  the same after you change a category yourself.
- **By guild:** anyone whose guild name contains a muted guild word is muted. TolerableChat comes
  with a short starting list (Guilds tab → *Muted guild words*); add your own and remove any you
  don't want. Spaces, dots and digits don't matter, so for the word `raiders`, `R41D3RS` and
  `R.A.I.D.E.R.S` count.
- **By name:** anyone whose character name contains a name keyword (People tab; spaces don't
  matter, so the keyword "dustmonkey" catches "Dust Monkey").
- **Never mute:** right-click → **Never mute**, for anyone who should always be shown.

**A guild mute is for good.** Once the game has shown someone in a muted guild, they stay muted even
after they leave it. To look at someone again, right-click → **Re-check guild**, the **Re-check**
button on the People tab, or `/tc recheck Name`: the mute is lifted until the game shows their guild
again, and they're first for the next `/who`. `/tc recheck left` lets go of everyone the game has
since shown in an unmuted guild.

### Muting a guild

Add a guild in any of these ways, and the guild sweep starts looking for its members:

- **Guilds** tab → *Known guilds*: every guild TolerableChat has seen, with a **Mute guild** button
  on each row. Or type a guild's name in the box and press **Mute guild**.
- Right-click a player → **Mute guild: Their Guild**. If TolerableChat doesn't know their guild yet,
  the menu says **Mute their guild (look it up with /who)**: the next `/who` looks them up and mutes
  whatever guild it shows (`/tc guild of Name` does the same).
- `/tc guild add Guild Name`.

The chat line says how many known guilds it now mutes. The guild sweep searches for it from the next
`/who`, and its members are muted as they're found. `/tc guild preview word` shows what a word would
mute without adding it. A word needs at least 4 letters: a short one would mute every guild that
happens to contain it. **Restore default words** (Guilds tab, *Muted guild words*) or
`/tc guild defaults` puts back any default word you removed.

**Offensively named guilds are muted automatically:** a guild whose name contains a Mute Forever word
(a slur or other bigotry). TolerableChat tries to deobfuscate the name first, so digits, symbols and
accents standing in for letters don't hide the word. A guild exception still wins; Settings has a
switch. Place names never count in a guild's name, whatever the Nationality category is set to: a
guild called "Texas Raiders" is just a guild.

### Lists to check now and then (Guilds tab)

- **Look-alike guilds:** guilds one letter away from a muted guild word of 6 or more letters (a
  letter changed, added, dropped or swapped, like "Raidres" for `raiders`), which no word or `/who`
  search catches. Nothing here is muted unless you press **Mute guild**.
- **Named with a filtered word:** guilds whose names contain a Timeout or Hide Only word, shown with
  the word and its category: "Thunderfury Raiders" (Dead Horses), a MAGA guild (Politics). Nothing
  is muted automatically, because a guild mute is for good and hides everything its members say;
  press **Mute guild** on the ones you want gone. Place names aren't listed.

### How TolerableChat learns guilds

Chat messages don't say which guild the sender is in, so TolerableChat collects it wherever **the
game** shows it:

- **/who** answers, its own and yours
- **nameplates** of players as they appear (read only: nothing about the nameplates changes)
- **mouseover**, **target**, **focus**, group members, inspect, guild invites

What it learns is saved, so the list keeps growing from session to session.

---

## A guild was muted by mistake

Say you muted the word `raiders`, and an innocent guild called "Raiders of Mercy" is muted with it.

1. **Guilds** tab → *Known guilds* → find it → **Exception**. Or right-click one of its members →
   **Guild exception: Raiders of Mercy**, or `/tc guild except Raiders of Mercy`.
2. Every member TolerableChat knows is shown again at once, including those who had already left it;
   the chat line says how many. A guild mute is tied to the guild's name, so when that guild stops
   being muted, every mute it caused ends.
3. If the guild was muted by a word you added, removing the word (*Muted guild words* → **Remove**)
   does the same for every guild that word caught.
4. To fix it for the whole guild, share your lists (exceptions are included) or tell people the
   guild's exact name.

What doesn't come back: lines already hidden stay hidden (new ones show), and anyone muted by hand,
by a Mute Forever term or by a name keyword stays muted (People tab → **Unmute**).

---

## Finding members of muted guilds: the guild sweep

The **Check** tab runs `/who` searches to find the online members of your muted guilds.

**When it searches.** The game only allows `/who` from a key press or a click, and TolerableChat
never sends one closer than **5 seconds** after the last. So:

- **Any key press** (on by default): once 5 seconds have passed, the next key you press (moving,
  casting, anything except Esc) runs the next search. You just play and it keeps going.
  It pauses during combat.
- Or press **Next /who** on the Check tab (or its small floating window), or the key binding
  *Next /who*.

If the server ever says to wait, the same search runs again on the next press and the gap grows by
a second.

**What it searches.** A sweep looks for every online member of every muted guild:

1. `g-"raiders" 1-60`, one search per muted guild word.
2. One search per muted guild the game has shown members of, e.g. `g-"IRON RAIDERS" 1-60`, the
   guilds with the most members still unknown first. `/who` matches any part of a guild name, so
   `g-"IRON RAIDERS"` also lists Iron Raiders II: a guild whose name contains another's gets no
   search of its own, since the shorter name's search already lists its members.
3. `/who` shows at most 50 players. When an answer is full, the search is split into finer ones:
   the level range in halves down to a single level, then by class, then by race (only the
   class/race combinations your faction allows), then by zone, then (guild searches only) by
   letters in the name (`n-"b"`, `n-"ba"`, `n-"bal"`). The last step is there for launch-sized
   crowds; it needs no attention.

Every third sweep is a **discovery sweep**: the word searches split too, so members of guilds
TolerableChat hasn't heard of yet are found and their guilds added to the index.

**The other faction.** `/who` only shows your own faction, so the sweep leaves out guilds whose
members are all of the other faction, and keeps its progress separately for each faction. An alt of
the other faction starts with its own discovery sweeps.

**What it does with the answers.** Everyone in a muted guild is muted at once (their earlier lines
go). And when a discovery sweep ends, everyone else who was online during it (talking, on
nameplates) and wasn't found is cleared as not being in a muted guild, without a search of their
own. Only the players you add with right-click → **Check** (or **Re-check guild**) get an individual
`/who`. Muted players are never looked up again by the sweep: a guild mute is for good.

The **Muted guild index** (Guilds tab, or `/tc guilds`) lists every muted guild seen so far, with
the members found and its faction. A guild whose name contains another's says whose search lists it
("in IRON RAIDERS's search").

The Who window stays shut while TolerableChat searches, and the results don't print in chat.

---

## Muted players can't bother you

- **Group invites, guild invites and duels** from muted players are declined after a random
  2–8 second pause (like a person clicking Decline), with the pop-up out of sight meanwhile.
- **Trades:** TolerableChat asks "Trade with Name?" first (Allow covers them for 10 minutes), or
  declines them outright (Settings tab).
- **Heads-ups:** inviting or whispering a muted player shows a one-line warning.
- **Whisper tabs:** if you have whispers open in their own tabs, a muted player's whisper still opens
  an empty tab (the game opens it before any addon sees the message). Close it by hand: closing it
  from an addon would interfere with the game's own whisper handling.
- **Chat bubbles** of muted players are blanked (open world only; the game locks bubbles in
  dungeons).
- **Tooltips** show "TolerableChat: muted (reason)".

---

## The window, tab by tab

| Tab | What's there |
|---|---|
| Overview | On/off, today's counts, a summary of what's hidden, Meme word mute, the last 5 hidden messages |
| Filter | One Mute Forever / Timeout / Hide Only / Off choice per category, Edit terms…, symbol spam, the Timeout Duration, which channels are filtered, a test box |
| People | Muted players (search, sort, unmute, re-check a guild mute, never mute), the never-mute list, name keywords |
| Guilds | Known guilds (Mute guild, Exception), the muted guild index, muted guild words (Restore default words), exceptions, look-alike guilds, guilds named with a filtered word |
| Check | Next /who, sweep progress, "any key press runs the next /who", "learn guilds from nameplates", players getting a search of their own |
| Log | Every hidden message of the last 30 minutes, with the reason (hover a line) |
| Flagged | Messages you flagged, for tuning the lists |
| Auto-mutes | Everyone muted automatically, with the message that did it; undo from here, or re-check them all against the current lists |
| Settings | Interaction blocking, warnings, bubbles, tooltip, the ignore list carry-over, offensive guild names, sharing, diagnostics |
| Advanced | Optional OlympusNet listening, off unless you turn it on (see [the end of this page](#optional-olympusnet)) |

---

## Right-click menu

On any player's name (chat, target, party, raid, friends, guild roster):

- **Mute** / **Unmute**
- **Never mute** (toggle)
- **Mute guild: Name**, or **Guild exception: Name** if they're muted by their guild (when the game
  has shown their guild); **Mute their guild (look it up with /who)** when it hasn't
- **Re-check guild**: for a player muted by a guild, now or one they left
- **Check**: look this player up with the next `/who`
- **Flag message**: this message should have been hidden (chat lines only)
- **Mute for 2 hours** (chat lines only)

---

## Slash commands

`/tc` (or `/tolerablechat`) on its own opens the window.

| Command | What it does |
|---|---|
| `/tc mute Name`, `/tc unmute Name` | Mute or unmute (several names: separate with commas) |
| `/tc allow Name` | Never mute (toggle) |
| `/tc guild add\|remove word`, `/tc guild except Guild Name` | Muted guild words (or exact guild names) and exceptions |
| `/tc guild preview word`, `/tc guild defaults` | Which known guilds a word would mute; put back the default words |
| `/tc guild of Name` | Mute that player's guild, looked up with the next `/who` if it isn't known |
| `/tc name add\|remove word` | Name keywords |
| `/tc check [Name]` | Open the Check tab, or put a player first for the next `/who` |
| `/tc guilds` | The muted guild index |
| `/tc key on\|off` | Any key press runs the next `/who` |
| `/tc meme`, `/tc meme mute word [minutes]`, `/tc meme unmute word` | Meme word mute |
| `/tc term add [word\|phrase\|contains\|allof\|pattern] text`, `/tc term remove text`, `/tc term list` | Your own terms |
| `/tc test text` | Would this be hidden, and why |
| `/tc status Name` | Why a player is shown or hidden |
| `/tc recheck Name`, `/tc recheck left` | Lift a guild mute and look them up again; let go of everyone who left their muted guild |
| `/tc share Name\|group\|guild` | Send your lists to another TolerableChat user |
| `/tc log`, `/tc flagged`, `/tc advanced` | Open those tabs |
| `/tc tally` | Stats |
| `/tc diag`, `/tc diag report` | Health summary; the full diagnostics report to copy |
| `/tc on`, `/tc off`, `/tc debug` | Master switch; debug output in chat |
| `/tc net on\|all\|off`, `/tc net forget` | Optional OlympusNet listening (read the warning first); forget what it heard on this realm |

---

## Sharing lists with your guild

Settings tab → **Share my lists with: My group / My guild / a player**, or `/tc share guild`.
This sends your muted guild words, guild exceptions, name keywords and custom terms; never players
and never the default terms. The other player (who needs TolerableChat too) sees a preview and
chooses **Add to mine**, **Replace mine** or **Cancel**. Shares from muted players are ignored, and
anyone can switch incoming shares off. Guild words under 4 letters are left out.

Custom terms of the **Pattern** type aren't accepted from other players: a pattern runs on every chat
line, and a badly made one can freeze the game. The preview says how many were left out. To pass
patterns on, use **Export my lists…** and have the other player paste the text into **Import
lists…**. Patterns you add or paste yourself may have at most two open-ended parts such as `.-` or
`%a+`, and at most ten optional ones (`s?`).

**Export my lists…** / **Import lists…** do the same through copy and paste.

---

## Your data, and playing on several realms

Everything is saved per account in

```
World of Warcraft\<Forever folder>\WTF\Account\<your account>\SavedVariables\TolerableChat.lua
```

- **Shared by all your characters, on every realm:** your settings, terms, muted guild words, guild
  exceptions and name keywords. Change them once and every character uses them.
- **Kept per realm:** muted players, the never-mute list, the guilds players are in, the muted guild
  index and the sweep's progress. Character and guild names are only unique on
  one realm, so a mute on one realm never hides a same-named character on another, and each realm
  builds its own list as you play there.
- On a realm, both factions share the lists: an alt of the other faction adds to them (`/who` only
  shows your own faction).

**Start over:** exit the game and delete (or move) that file.

---

## Troubleshooting

- **Not in the AddOns list:** check the folder layout under [Installing](#installing).
- **Errors:** TolerableChat keeps its own log: `/tc diag` prints a health summary, and
  `/tc diag report` (or Settings → Diagnostics report…) shows everything, ready to copy into a
  message to whoever looks after the addon.
- **A message was hidden and you don't know why:** hover it in the Log tab, or `/tc test` its text.
- **Someone is muted who shouldn't be:** `/tc status Name` says why. Right-click → Never mute, or see
  [A guild was muted by mistake](#a-guild-was-muted-by-mistake).
- **After updating, something doesn't work:** exit the game fully and start it again. A `/reload`
  doesn't pick up files an update added.

---

## Limits worth knowing

- `/who` only shows your own faction, at most 50 players per search, and TolerableChat never sends
  one closer than 5 seconds apart. It matches any part of a name, so a guild search also lists every
  guild whose name contains the searched name.
- A member of a muted guild is muted only once the game shows their guild (a `/who`, a nameplate,
  a mouseover). Their earlier lines are removed then, so someone who talks before the sweep reaches
  them is visible until it does.
- Chat bubbles can only be blanked in the open world.
- A new guild isn't muted until its name contains a muted guild word or you mute it.
- Built for WoW Forever (interface 16001). Other WoW versions aren't supported.

---

## Optional: OlympusNet

The **Advanced** tab can listen to OlympusNet, a hidden channel one group of guilds uses to share
guild information, and add the guild names it hears to your lists. It's off unless you turn it on,
and it's separate from everything above: nothing else needs it, and with it off TolerableChat never
joins the channel. It only listens. Nothing heard there mutes anyone or gets anyone a `/who`: guilds
with a muted word in their name go into the muted guild index, and the others wait on the Advanced
tab for you to look at.

> **Warning:** while you listen, your character's name is in the channel's member list, and the
> channel's users may target that character for harassment. If you use it, use a disposable alt on
> the same realm and faction with **This character only** (`/tc net on`), leave it on for 10 minutes or more,
> then turn it **Off**. It can stop working whenever the channel's owners change their addon.

If odd guild names start arriving, turn it **Off** and press **Forget OlympusNet data…**
(`/tc net forget`). While it's on, its channels are kept at the end of your channel list, so
General, Trade and your own channels keep their numbers.

---

## Credits and licences

- **Dog Whistle Glossary**: Mendelsohn, Le Bras, Choi and Sap (2023),
  github.com/juliamendelsohn/dogwhistles. MIT licence.
- **HurtLex EN 1.2**: Bassignana, Basile and Patti (2018), github.com/valeriobasile/hurtlex.
  CC BY-NC-SA 4.0.

TolerableChat is shared free. Terms derived from HurtLex may not be sold, and any modified term list
must keep the CC BY-NC-SA licence. `CREDITS.txt` in the addon folder has the full notices.

---

## For developers

**[ARCHITECTURE.md](ARCHITECTURE.md)** explains how the addon works inside: the files, the decision
order, the saved data, the sweep, and how to build, test and release. `TolerableChat.spec` is the
full specification, and `in-game-checklist.md` lists what to check in game after each version.

```
python build/build_data.py      rebuild Terms.lua, GameNames.lua and TERMS.md from the term lists
python tests/run_tests.py       the offline tests (needs lupa: pip install lupa)
python build/install.py         copy the addon into the game (exit the game first if files were added or removed)
python build/package.py         make the release zip
```
