import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App.tsx'

// Development only: if .env.local sets VITE_DEV_WALLET_KEY (a throwaway testnet key), register a
// stand-in wallet so automated runs can approve transactions. Only in a browser that opted in with
// localStorage "brake-dev-wallet" = "on" (the test browser), so a person's own browser always uses
// their real wallet. Never in builds; the key never goes in a URL or in storage.
const optedIn = (() => {
  try {
    return localStorage.getItem('brake-dev-wallet') === 'on'
  } catch {
    return false
  }
})()
const devKey = import.meta.env.DEV && optedIn ? (import.meta.env.VITE_DEV_WALLET_KEY as string | undefined) : undefined
if (devKey) (await import('./dev/testWallet')).registerTestWallet(devKey)

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
