import { describe, expect, it } from 'vitest'

import { buildProtectRpcUrl } from './protect'

const VAULT = '0x9F0d36DFf418195F767763B17B5D9E5782D74ED0' as const

describe('buildProtectRpcUrl', () => {
  it('rejects 0', () => {
    expect(() => buildProtectRpcUrl({ vault: VAULT, vaultPercent: 0 })).toThrow()
  })

  it('rejects 100', () => {
    expect(() => buildProtectRpcUrl({ vault: VAULT, vaultPercent: 100 })).toThrow()
  })

  it('rejects non-integers', () => {
    expect(() => buildProtectRpcUrl({ vault: VAULT, vaultPercent: 42.5 })).toThrow()
  })

  it('emits exactly one refund param encoding vault:percent', () => {
    const url = new URL(buildProtectRpcUrl({ vault: VAULT, vaultPercent: 50 }))
    expect(url.searchParams.getAll('refund')).toEqual([`${VAULT}:50`])
  })

  it('emits each hint as a separate hint param', () => {
    const url = new URL(buildProtectRpcUrl({ vault: VAULT, vaultPercent: 50, hints: ['hash', 'calldata'] }))
    expect(url.searchParams.getAll('hint')).toEqual(['hash', 'calldata'])
  })

  it('defaults hints to ["hash"] when omitted', () => {
    const url = new URL(buildProtectRpcUrl({ vault: VAULT, vaultPercent: 50 }))
    expect(url.searchParams.getAll('hint')).toEqual(['hash'])
  })
})
