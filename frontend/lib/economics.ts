// Shape of each record in data/economics.json (see test/Economics.fork.t.sol's
// _serialize()). Numeric fields are decimal strings, not bigint/number — several
// exceed Number.MAX_SAFE_INTEGER, and bigint isn't guaranteed to survive the
// server-to-client component prop boundary, so callers convert with BigInt(...)
// where they need to compute or format a value.
export interface EconomicsRecord {
  source: string
  scenario: string
  pool: string
  lpNetValueWeiC0Equiv: string
  feeRevenue0: string
  feeRevenue1: string
  fairShareRevenue0: string
  fairShareRevenue1: string
  effectiveTraderCostWeiC0Equiv: string
  lvrProxyWeiC0Equiv: string
  protectedVolumeShareBps: string
}

export const SCENARIOS = ['calm', 'volatile', 'sandwichable', 'informed_flow', 'split_attack'] as const
export const POOLS = ['vanilla', 'high-fee', 'themis'] as const
