#!/usr/bin/env node
// DeepSeek balance & token consumption checker.
//
// - Reads your live balance from GET https://api.deepseek.com/user/balance
// - Estimates how many tokens that balance still buys
// - Saves a snapshot each run (history.json) so you can see how much you've
//   spent / consumed since the last check and per day.
//
// Usage:
//   DEEPSEEK_API_KEY=sk-... node balance.mjs        # check + record snapshot
//   node balance.mjs --history                      # show recorded history
//   node balance.mjs --no-save                      # check without recording
//
// The key can also live in a .env file next to this script: DEEPSEEK_API_KEY=sk-...
// No dependencies; needs Node 18+.

import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const HISTORY_FILE = join(HERE, 'history.json')
const ENV_FILE = join(HERE, '.env')

// Prices per 1M tokens, in USD. DeepSeek changes these from time to time —
// check https://api-docs.deepseek.com/quick_start/pricing and override via .env.
const PRICE = {
  inputHit: num(process.env.DS_PRICE_INPUT_HIT, 0.028),
  inputMiss: num(process.env.DS_PRICE_INPUT_MISS, 0.28),
  output: num(process.env.DS_PRICE_OUTPUT, 0.42),
}
const CNY_PER_USD = num(process.env.DS_CNY_PER_USD, 7.1)

function num(v, fallback) {
  const n = Number(v)
  return v !== undefined && v !== '' && Number.isFinite(n) ? n : fallback
}

function loadEnvFile() {
  if (!existsSync(ENV_FILE)) return
  for (const line of readFileSync(ENV_FILE, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/)
    if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '')
  }
}

function loadHistory() {
  try {
    return JSON.parse(readFileSync(HISTORY_FILE, 'utf8'))
  } catch {
    return []
  }
}

const fmtMoney = (v, cur) => `${cur === 'CNY' ? '¥' : '$'}${v.toFixed(4)}`
const fmtTokens = (n) =>
  n >= 1e9 ? `${(n / 1e9).toFixed(2)}B` : n >= 1e6 ? `${(n / 1e6).toFixed(2)}M` : n >= 1e3 ? `${(n / 1e3).toFixed(1)}K` : `${Math.round(n)}`

function toUsd(amount, currency) {
  return currency === 'CNY' ? amount / CNY_PER_USD : amount
}

// Tokens a USD amount buys for a few usage shapes.
function tokenEstimates(usd) {
  // Typical chat: 3 input tokens (all cache miss) per 1 output token.
  const blended = (3 * PRICE.inputMiss + PRICE.output) / 4
  return {
    'Input only (cache miss)': (usd / PRICE.inputMiss) * 1e6,
    'Input only (cache hit)': (usd / PRICE.inputHit) * 1e6,
    'Output only': (usd / PRICE.output) * 1e6,
    'Mixed chat (3 in : 1 out)': (usd / blended) * 1e6,
  }
}

function showHistory(history) {
  if (history.length === 0) {
    console.log('No history yet. Run without --history to record a snapshot.')
    return
  }
  console.log('\nTime (local)            Currency   Total balance   Change')
  console.log('-'.repeat(62))
  let prev
  for (const h of history) {
    const change = prev && prev.currency === h.currency ? h.total - prev.total : null
    console.log(
      `${new Date(h.at).toLocaleString().padEnd(24)}${h.currency.padEnd(11)}${fmtMoney(h.total, h.currency).padEnd(16)}` +
        (change === null ? '' : change <= 0 ? `-${fmtMoney(-change, h.currency)}` : `+${fmtMoney(change, h.currency)} (top-up)`),
    )
    prev = h
  }

  // Per-day spend (ignores top-ups) for the most recent currency.
  const cur = history.at(-1).currency
  const rows = history.filter((h) => h.currency === cur)
  const perDay = new Map()
  for (let i = 1; i < rows.length; i++) {
    const spent = rows[i - 1].total - rows[i].total
    if (spent <= 0) continue
    const day = new Date(rows[i].at).toLocaleDateString()
    perDay.set(day, (perDay.get(day) ?? 0) + spent)
  }
  if (perDay.size) {
    console.log(`\nSpend per day (${cur}, top-ups excluded):`)
    for (const [day, spent] of perDay) {
      const est = tokenEstimates(toUsd(spent, cur))['Mixed chat (3 in : 1 out)']
      console.log(`  ${day.padEnd(14)}${fmtMoney(spent, cur).padEnd(12)}≈ ${fmtTokens(est)} tokens (mixed chat)`)
    }
  }
}

async function main() {
  loadEnvFile()
  const args = new Set(process.argv.slice(2))
  const history = loadHistory()

  if (args.has('--history')) return showHistory(history)

  const key = process.env.DEEPSEEK_API_KEY
  if (!key) {
    console.error('Missing DEEPSEEK_API_KEY. Set it in your shell or in', ENV_FILE)
    process.exit(1)
  }

  const res = await fetch('https://api.deepseek.com/user/balance', {
    headers: { Authorization: `Bearer ${key}`, Accept: 'application/json' },
    signal: AbortSignal.timeout(15_000),
  })
  if (!res.ok) {
    console.error(`DeepSeek API error ${res.status}: ${await res.text()}`)
    process.exit(1)
  }
  const data = await res.json()

  console.log(`\nDeepSeek balance — ${new Date().toLocaleString()}`)
  console.log(`Account can use API: ${data.is_available ? 'yes' : 'NO (balance too low?)'}`)

  const snapshots = []
  for (const b of data.balance_infos ?? []) {
    const total = Number(b.total_balance)
    const granted = Number(b.granted_balance)
    const toppedUp = Number(b.topped_up_balance)
    const cur = b.currency

    console.log(`\n[${cur}]`)
    console.log(`  Total:      ${fmtMoney(total, cur)}`)
    console.log(`  Topped up:  ${fmtMoney(toppedUp, cur)}`)
    console.log(`  Granted:    ${fmtMoney(granted, cur)}`)

    const last = [...history].reverse().find((h) => h.currency === cur)
    if (last) {
      const diff = last.total - total
      const since = new Date(last.at).toLocaleString()
      if (diff > 0) {
        const est = tokenEstimates(toUsd(diff, cur))['Mixed chat (3 in : 1 out)']
        console.log(`  Spent since ${since}: ${fmtMoney(diff, cur)} (≈ ${fmtTokens(est)} tokens, mixed chat)`)
      } else if (diff < 0) {
        console.log(`  Balance up ${fmtMoney(-diff, cur)} since ${since} (top-up)`)
      } else {
        console.log(`  No spend since ${since}`)
      }
    }

    console.log('  Estimated tokens remaining:')
    for (const [label, n] of Object.entries(tokenEstimates(toUsd(total, cur)))) {
      console.log(`    ${label.padEnd(28)}${fmtTokens(n)}`)
    }

    snapshots.push({ at: new Date().toISOString(), currency: cur, total, granted, toppedUp })
  }

  console.log(
    `\nPrices used (USD / 1M tokens): input hit $${PRICE.inputHit}, miss $${PRICE.inputMiss}, output $${PRICE.output}` +
      ' — override with DS_PRICE_* in .env if DeepSeek changes them.',
  )

  if (!args.has('--no-save') && snapshots.length) {
    writeFileSync(HISTORY_FILE, JSON.stringify([...history, ...snapshots], null, 2))
  }
}

main().catch((err) => {
  console.error(err.message ?? err)
  process.exit(1)
})
