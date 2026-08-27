import { useSyncExternalStore } from 'react'

const subscribeNoop = () => () => {}

// wagmi's connection state rehydrates from browser storage on the client, so
// isConnected can flip true immediately after mount even though SSR always
// renders the disconnected shell (no wallet access server-side). Branching a
// render on isConnected directly causes a hydration mismatch — and React
// tearing down and regenerating the mismatched tree mid-interaction is what
// makes clicks silently no-op right after load (see components/SwapCard.tsx's
// git history for the bug this was found fixing). useSyncExternalStore is
// React's own documented fix: the server snapshot and the first client
// snapshot both return false, so the first client render is provably
// identical to the server's; only a later, ordinary re-render (not the
// hydration pass) picks up the real value.
export function useHasMounted() {
  return useSyncExternalStore(subscribeNoop, () => true, () => false)
}
