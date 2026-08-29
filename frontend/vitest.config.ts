import path from 'node:path'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  resolve: {
    alias: {
      '@': path.resolve(__dirname, '.'),
    },
  },
  test: {
    environment: 'node',
    // SwapCard short-circuits to a static fallback (never calling wagmi/Privy
    // hooks) when this is unset — component tests need the real branch.
    env: { NEXT_PUBLIC_PRIVY_APP_ID: 'test-privy-app-id' },
  },
})
