# DeepSeekBar

A small macOS menu bar app that shows your **DeepSeek API balance** at a glance.

- 🐋 DeepSeek logo, a mini gauge and **% of balance left** in the menu bar (turns red below 15%)
- Click it for a panel with your balance, **spending today / last 7 days** with a chart, and an estimate of how many **requests, tokens and days** you have left
- Switch amounts between **¥ CNY and $ USD**
- Optional **Open at login**
- Also includes `balance.mjs`, a command-line version

> Unofficial. Not affiliated with or endorsed by DeepSeek. Your API key stays on your Mac and is only sent to `api.deepseek.com`.

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools (for `swiftc`): `xcode-select --install`
- A DeepSeek API key from [platform.deepseek.com/api_keys](https://platform.deepseek.com/api_keys)
- Node.js 18+ (only for the optional command-line script)

## Install

```bash
git clone https://github.com/mitbol22/deepseekbar.git
cd deepseekbar
cp .env.example .env          # then put your key in DEEPSEEK_API_KEY
./menubar/build.sh            # builds and installs ~/Applications/DeepSeekBar.app
open ~/Applications/DeepSeekBar.app
```

The app reads `.env` from the folder you built it in, so keep the cloned folder where it is (or rebuild after moving it).

To start it automatically, open the panel and turn on **Open at login**.

## How it works

DeepSeek's API only exposes your **balance** (`GET /user/balance`), not per-request usage. So the app:

1. Checks your balance every 15 minutes and whenever you open the panel.
2. Saves a snapshot to `history.json` whenever the balance changes.
3. Works out **spending** from the drops between snapshots (top-ups are ignored).

That means spending history starts from the first time you run it.

**What 100% means:** DeepSeek has no quota, only a prepaid balance. By default 100% is your balance right after your latest top-up, and each top-up resets it. Set `DS_BUDGET` to measure against a fixed amount instead.

**Estimates:** "requests" and "tokens" left are worked out from list prices and a typical request size, so treat them as rough. If you rely heavily on cached input or send very large requests, your real numbers will differ. For exact figures, see [platform.deepseek.com/usage](https://platform.deepseek.com/usage).

If your account has balances in both CNY and USD, the app shows the one with money in it.

## Settings (`.env`)

| Variable | Default | What it does |
|---|---|---|
| `DEEPSEEK_API_KEY` | — | Your API key (required) |
| `DS_BUDGET` | balance after last top-up | Fixed amount that counts as 100% |
| `DS_PRICE_INPUT_HIT` | `0.028` | Price per 1M cached input tokens (USD) |
| `DS_PRICE_INPUT_MISS` | `0.28` | Price per 1M uncached input tokens (USD) |
| `DS_PRICE_OUTPUT` | `0.42` | Price per 1M output tokens (USD) |
| `DS_CNY_PER_USD` | `7.1` | Exchange rate for the ¥ / $ switch and estimates |
| `DS_AVG_INPUT` / `DS_AVG_OUTPUT` | `2000` / `500` | Size of a "typical request" |

DeepSeek changes its prices from time to time — check the [pricing page](https://api-docs.deepseek.com/quick_start/pricing) and update the `DS_PRICE_*` values if needed. Click refresh in the panel after editing `.env`.

## Command-line version

```bash
node balance.mjs             # show balance, record a snapshot
node balance.mjs --history   # show recorded snapshots and spend per day
node balance.mjs --no-save   # check without recording
```

It uses the same `.env` and `history.json` as the app.

## Privacy

- `.env` (your key) and `history.json` (your balance history) are git-ignored and never leave your Mac, except the key being sent to DeepSeek's API.
- The app has no analytics and talks to no server other than `api.deepseek.com`.

## Uninstall

Turn off **Open at login**, quit from the panel, then delete `~/Applications/DeepSeekBar.app`.

## Credits

DeepSeek logo SVG from [LobeHub Icons](https://github.com/lobehub/lobe-icons) (MIT). DeepSeek is a trademark of its owner.

## License

[MIT](LICENSE)
