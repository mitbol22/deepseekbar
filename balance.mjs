#!/usr/bin/env node
// DeepSeek balance & spending checker.
//
// - Reads your live balance from GET https://api.deepseek.com/user/balance
// - Estimates how many days your balance lasts at your recent pace
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
      console.log(`  ${day.padEnd(14)}${fmtMoney(spent, cur)}`)
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
        console.log(`  Spent since ${since}: ${fmtMoney(diff, cur)}`)
      } else if (diff < 0) {
        console.log(`  Balance up ${fmtMoney(-diff, cur)} since ${since} (top-up)`)
      } else {
        console.log(`  No spend since ${since}`)
      }
    }

    // Days left at your recent pace (last 7 days of recorded snapshots).
    const rows = history.filter((h) => h.currency === cur)
    if (rows.length) {
      const weekAgo = Date.now() - 7 * 86400e3
      let spentWeek = 0
      const all = [...rows, { at: new Date().toISOString(), total }]
      for (let k = 1; k < all.length; k++) {
        const d = all[k - 1].total - all[k].total
        if (d > 0 && Date.parse(all[k].at) >= weekAgo) spentWeek += d
      }
      const span = Math.min(7, Math.max(1, (Date.now() - Date.parse(rows[0].at)) / 86400e3))
      const perDay = spentWeek / span
      if (perDay > 0) console.log(`  Lasts about ${Math.round(total / perDay)} days at ${fmtMoney(perDay, cur)}/day`)
    }

    snapshots.push({ at: new Date().toISOString(), currency: cur, total, granted, toppedUp })
  }


  if (!args.has('--no-save') && snapshots.length) {
    writeFileSync(HISTORY_FILE, JSON.stringify([...history, ...snapshots], null, 2))
  }
}

main().catch((err) => {
  console.error(err.message ?? err)
  process.exit(1)
})
