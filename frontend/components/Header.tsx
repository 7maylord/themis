'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'

import { ConnectButton } from '@/components/ConnectButton'

const LINKS = [
  { href: '/swap', label: 'Swap' },
  { href: '/pool', label: 'Pool' },
  { href: '/research', label: 'Research' },
] as const

export function Header() {
  const pathname = usePathname()

  return (
    <header className="border-b border-white/10">
      <div className="mx-auto flex w-full max-w-4xl items-center justify-between px-4 py-4">
        <Link href="/" className="font-semibold tracking-tight">
          Themis
        </Link>
        <nav className="flex items-center gap-1">
          {LINKS.map((link) => (
            <Link
              key={link.href}
              href={link.href}
              className={`rounded-lg px-3 py-1.5 text-sm ${
                pathname === link.href ? 'bg-white text-black' : 'text-white/70 hover:text-white'
              }`}
            >
              {link.label}
            </Link>
          ))}
          <div className="ml-2">
            <ConnectButton />
          </div>
        </nav>
      </div>
    </header>
  )
}
