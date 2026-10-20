# TolerableChat

A chat filter for **WoW Forever** that keeps public chat about the game. It hides politics,
religion, streamer drama, bigotry and harassment, while groups, trades, dungeon runs and other
game talk still come through. It can also mute every member of any guild whose name contains
your keywords, finding them over time in the background as you play.

## Download

Get **TolerableChat-1.0.1.zip** from the
[latest release](../../releases/latest).

Don't use the green **Code → Download ZIP** button: that unzips to a folder named
`TolerableChat-main`, which WoW won't load until it's renamed to `TolerableChat`.

## Install

1. Exit the game.
2. Unzip the download. Inside is one folder, `TolerableChat`.
3. Copy that folder into `World of Warcraft\<your Forever folder>\Interface\AddOns\`, so the
   file sits at `Interface\AddOns\TolerableChat\TolerableChat.toc`.
4. Start the game and type `/tc` to open it.

## What it does

- **Hides topics, not opinions.** Politics, religion, nationality and streamer talk are hidden
  whichever side they're on, along with crude sexual talk, bigotry and harassment. Spelling tricks
  (`p0litics`, `t.r.u.m.p`, look-alike letters) are seen through, and item, spell, NPC and quest
  names are never caught.
- **Timeouts.** A message hidden by a Timeout category also hides that player's other non-game
  messages for 30 minutes either side, so the whole argument goes. Groups, trades and item links
  still get through.
- **Guild muting.** Mute every member of any guild whose name contains a word you choose. A
  background `/who` sweep finds them as you play, at most one search every 5 seconds.
- **Muted players can't bother you.** Their invites and duels are declined, trades are asked
  about first, and their chat bubbles are blanked (open world only).
- **Never touched:** your own messages, GMs, friends, your guild and your group. Party, raid and
  guild chat aren't filtered at all.
- **Everything stays on your screen.** It never tells anyone they're muted and never changes your
  ignore list.

## Make it yours

It's tuned to my preferences and is overly broad in places, especially around politics and
marginalized groups. Everything can be changed:

- Each category can be set to **Mute Forever**, **Timeout**, **Hide Only** or **Off** (Filter tab).
- **Edit terms…** lets you switch any word off, add your own, or turn off every built-in term at
  once and start your own list.
- To use only the guild muting, set every category to **Off** and untick symbol spam.

## More detail

- [GUIDE.md](GUIDE.md): the full guide (every tab, the right-click menu, slash commands, sharing
  lists, troubleshooting)
- [FILTERS.md](FILTERS.md): what each category hides, and why
- [TERMS.md](TERMS.md): every built-in word and phrase

## The fine print

I built this for myself and shared it because some guildmates asked. While I do have a
programming background, it was nearly entirely vibe coded. I'm not planning revisions or updates
unless something catastrophically breaks.

This is random code from a stranger on the internet, so you should probably have your robot look
at it before you trust it not to send me all your gold.

## Credits and licence

- **Dog Whistle Glossary**: Mendelsohn, Le Bras, Choi and Sap (2023),
  github.com/juliamendelsohn/dogwhistles. MIT licence.
- **HurtLex EN 1.2**: Bassignana, Basile and Patti (2018), github.com/valeriobasile/hurtlex.
  CC BY-NC-SA 4.0.

TolerableChat is free. Terms derived from HurtLex may not be sold, and any modified term list must
keep the CC BY-NC-SA licence. `CREDITS.txt` has the full notices.
