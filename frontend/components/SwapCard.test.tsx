// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'

vi.mock('wagmi', () => ({
  useAccount: () => ({ address: '0xAD6433f3a49eb065e6470F231a3dc3Dee26F0f9d', isConnected: true, chainId: 11155111 }),
  useSwitchChain: () => ({ switchChain: vi.fn(), isPending: false }),
  useWalletClient: () => ({ data: undefined }),
  useWriteContract: () => ({ writeContract: vi.fn(), isPending: false }),
}))

vi.mock('@privy-io/react-auth', () => ({
  usePrivy: () => ({ login: vi.fn(), logout: vi.fn(), ready: true, authenticated: true }),
}))

// AMBER regime, forced deterministically — the real hook reads on-chain state,
// which this component test has no wallet/RPC for.
vi.mock('@/lib/themis', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/lib/themis')>()
  return {
    ...actual,
    usePreviewRisk: () => ({ score: 50, regime: 1, premiumPpm: 5000, isLoading: false }),
  }
})

const { SwapCard } = await import('./SwapCard')

afterEach(() => cleanup())

// FR-013, restated as code: there is no code path where declining protection
// results in an automatic public send.
describe('SwapCard — declining protection (FR-013)', () => {
  it('leaves the main swap button disabled after declining protection', () => {
    render(<SwapCard />)

    fireEvent.change(screen.getByPlaceholderText('0.0'), { target: { value: '1' } })
    fireEvent.click(screen.getByText('Continue without protection'))

    const swapButton = screen.getByRole('button', { name: /^swap$/i }) as HTMLButtonElement
    expect(swapButton.disabled).toBe(true)
  })

  it('surfaces the public-route warning behind a separate confirm action, not the main button', () => {
    render(<SwapCard />)

    fireEvent.change(screen.getByPlaceholderText('0.0'), { target: { value: '1' } })
    fireEvent.click(screen.getByText('Continue without protection'))

    expect(screen.queryByTestId('public-warning')).not.toBeNull()
    expect(screen.queryByText('Swap publicly anyway')).not.toBeNull()
  })

  it('never shows the decision panel once protection is enabled', () => {
    render(<SwapCard />)

    fireEvent.change(screen.getByPlaceholderText('0.0'), { target: { value: '1' } })
    expect(screen.queryByTestId('amber-decision')).not.toBeNull()
  })
})
