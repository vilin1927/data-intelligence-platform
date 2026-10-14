'use client';

import { useState, useEffect } from 'react';
import { usePathname } from 'next/navigation';
import Sidebar from './Sidebar';
import GlobalMonthSelector from './GlobalMonthSelector';

const STORAGE_KEY = 'moppity_sidebar_collapsed';

interface AppLayoutProps {
  children: React.ReactNode;
  title?: string;
  subtitle?: string;
}

export default function AppLayout({ children, title, subtitle }: AppLayoutProps) {
  const [collapsed, setCollapsed] = useState(false);
  const [mounted, setMounted] = useState(false);
  const pathname = usePathname();

  useEffect(() => {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored === 'true') setCollapsed(true);
    setMounted(true);

    const handler = (e: Event) => {
      const detail = (e as CustomEvent).detail;
      setCollapsed(detail.collapsed);
    };
    window.addEventListener('sidebar-toggle', handler);
    return () => window.removeEventListener('sidebar-toggle', handler);
  }, []);

  return (
    <div className="min-h-screen bg-[#FAF9F7]">
      <Sidebar />

      <main className={`min-h-screen transition-all duration-200 ${mounted && collapsed ? 'ml-16' : 'ml-60'}`}>
        {/* "Reports as at mmm-yy" selector — mounted on Overview + main reporting
            pages (the owner ask 2026-04-26: "Have a month selector at the top —
            reports as at mmm-yy"). Restricted to Overview ('/') only per
            non-Overview routes. Page-level time controls (/sales 6m/12m/24m,
            /margin From/To MonthPicker) remain functional in their own pages. */}
        {pathname === '/' && (
          <div className="sticky top-0 z-20 bg-[#FAF9F7]/95 backdrop-blur border-b border-[#D8D9DA] px-8 py-2 flex justify-end">
            <GlobalMonthSelector />
          </div>
        )}

        {title && (
          <header
            className={`sticky ${pathname === '/' ? 'top-9' : 'top-0'} z-10 bg-[#FAF9F7] border-b border-[#D8D9DA] px-8 py-6`}
          >
            <h1
              className="text-2xl text-[#1F1F1F] font-semibold"
              style={{ fontFamily: 'Cardo, serif' }}
            >
              {title}
            </h1>
            {subtitle && (
              <p
                className="text-[#505052] text-sm mt-1"
                style={{ fontFamily: 'Inter, sans-serif' }}
              >
                {subtitle}
              </p>
            )}
          </header>
        )}

        <div className="p-8">
          {children}
        </div>
      </main>
    </div>
  );
}
