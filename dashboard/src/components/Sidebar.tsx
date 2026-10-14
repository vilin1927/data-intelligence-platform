'use client';

import { useState, useEffect } from 'react';
import { usePathname } from 'next/navigation';
import Link from 'next/link';
import Image from 'next/image';
import {
  LayoutDashboard,
  TrendingUp,
  Calculator,
  Search,
  Package,
  FileSpreadsheet,
  BarChart3,
  MessageSquare,
  Settings,
  LogOut,
  ChevronsLeft,
  ChevronsRight,
  Database,
  BookOpen,
} from 'lucide-react';
import P2PreviewModal from './P2PreviewModal';

interface NavItem {
  href: string;
  label: string;
  icon: React.ReactNode;
  badge?: 'P2' | 'M3' | 'IN_DEV';
  enabled?: boolean;
}

const navItems: NavItem[] = [
  { href: '/', label: 'Overview', icon: <LayoutDashboard size={20} />, enabled: true },
  { href: '/margin', label: 'Margin Analysis', icon: <TrendingUp size={20} />, enabled: true },
  { href: '/what-if', label: 'What-If Calculator', icon: <Calculator size={20} />, enabled: true },
  { href: '/wines', label: 'Wine Profile', icon: <Search size={20} />, enabled: true },
  { href: '/inventory', label: 'Inventory & Bottling', icon: <Package size={20} />, enabled: true },
  { href: '/sales', label: 'Sales Analytics', icon: <BarChart3 size={20} />, enabled: true },
  { href: '/chat', label: 'AI Chat', icon: <MessageSquare size={20} />, enabled: true },
  { href: '/legacy-data', label: 'Combined Data', icon: <Database size={20} />, enabled: true },
  { href: '/reference', label: 'Reference Data', icon: <BookOpen size={20} />, enabled: true },
  { href: '/admin', label: 'Admin', icon: <Settings size={20} />, enabled: true },
];

// Phase 2 zone — items shown greyed out, clicking opens P2PreviewModal.
// Routes exist (preserved on prod) but nav surface is deferred per Pre-Read scope.
const p2Items: NavItem[] = [
  { href: '/cashflow', label: 'Cashflow Forecast', icon: <TrendingUp size={20} />, badge: 'P2' },
  { href: '/production', label: 'Production Planning', icon: <Package size={20} />, badge: 'P2' },
  { href: '/legacy-reports', label: 'Legacy Reports', icon: <FileSpreadsheet size={20} />, badge: 'P2' },
];

function p2ModalKey(href: string): 'cashflow' | 'production' | 'legacy-reports' {
  if (href === '/cashflow') return 'cashflow';
  if (href === '/production') return 'production';
  return 'legacy-reports';
}

// Cosmetic VIEW_ONLY demo flag — hides edit/admin controls so prospects don't
// hit dead buttons. Real enforcement is the middleware 403. Flag unset (live
// editor) => everything renders as before.
const VIEW_ONLY = process.env.NEXT_PUBLIC_VIEW_ONLY === 'true';

const badgeStyles: Record<string, string> = {
  IN_DEV: 'text-white/25',
  M3: 'text-blue-400/50',
  P2: 'text-purple-400/50',
};

const badgeLabels: Record<string, string> = {
  IN_DEV: 'Soon',
  M3: 'M3',
  P2: 'P2',
};

const STORAGE_KEY = 'moppity_sidebar_collapsed';

export default function Sidebar() {
  const pathname = usePathname();
  const [p2Modal, setP2Modal] = useState<'cashflow' | 'production' | 'legacy-reports' | null>(null);
  const [collapsed, setCollapsed] = useState(false);
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored === 'true') setCollapsed(true);
    setMounted(true);
  }, []);

  const toggleCollapsed = () => {
    const next = !collapsed;
    setCollapsed(next);
    localStorage.setItem(STORAGE_KEY, String(next));
    window.dispatchEvent(new CustomEvent('sidebar-toggle', { detail: { collapsed: next } }));
  };

  const handleSignOut = async () => {
    await fetch('/api/auth/logout', { method: 'POST' });
    window.location.href = '/login';
  };

  if (!mounted) {
    return <aside className="fixed left-0 top-0 h-screen bg-[#0E0F0F] w-60" />;
  }

  return (
    <>
    <aside className={`fixed left-0 top-0 h-screen bg-[#0E0F0F] flex flex-col transition-all duration-200 ${collapsed ? 'w-16' : 'w-60'}`}>
      {/* Logo + Toggle */}
      <div className={`border-b border-white/10 flex items-center ${collapsed ? 'p-3 justify-center' : 'p-6 justify-center'}`}>
        <Link href="/" className="flex items-center justify-center">
          {VIEW_ONLY ? (
            <span
              className={`text-white font-medium tracking-wide text-center transition-all duration-200 ${collapsed ? 'text-[10px] leading-tight' : 'text-sm'}`}
              style={{ fontFamily: 'Inter, sans-serif' }}
            >
              {collapsed ? 'WDP' : 'Wine Data Platform'}
            </span>
          ) : (
            <Image
              src="/images/MV-logo.png"
              alt="Moppity Vineyards"
              width={collapsed ? 32 : 67}
              height={collapsed ? 28 : 58}
              className="object-contain transition-all duration-200"
            />
          )}
        </Link>
      </div>

      {/* Collapse toggle */}
      <button
        onClick={toggleCollapsed}
        className="flex items-center justify-center py-2 text-white/30 hover:text-white/60 transition-colors border-b border-white/5"
        title={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
      >
        {collapsed ? <ChevronsRight size={16} /> : <ChevronsLeft size={16} />}
      </button>

      {/* Navigation */}
      <nav className="flex-1 py-4 overflow-y-auto">
        <ul className={`space-y-1 ${collapsed ? 'px-2' : 'px-3'}`}>
          {navItems
            .filter((item) => !(VIEW_ONLY && item.href === '/admin'))
            .map((item) => {
            const isEnabled = item.enabled === true;
            const isActive = isEnabled && (
              pathname === item.href ||
              (item.href !== '/' && pathname.startsWith(item.href))
            );

            if (isEnabled) {
              return (
                <li key={item.href}>
                  <Link
                    href={item.href}
                    className={`
                      flex items-center ${collapsed ? 'justify-center' : 'gap-3'} px-3 py-2.5 rounded-lg text-sm transition-colors
                      ${isActive
                        ? 'bg-[#931220]/20 text-white border-l-2 border-[#931220] -ml-px pl-[11px]'
                        : 'text-white/70 hover:text-white hover:bg-white/5'
                      }
                    `}
                    style={{ fontFamily: 'Inter, sans-serif' }}
                    title={collapsed ? item.label : undefined}
                  >
                    <span className={isActive ? 'text-[#931220]' : 'text-white/50'}>
                      {item.icon}
                    </span>
                    {!collapsed && <span>{item.label}</span>}
                  </Link>
                </li>
              );
            }

            return (
              <li key={item.href}>
                <div
                  className={`flex items-center ${collapsed ? 'justify-center' : 'gap-3'} px-3 py-2.5 rounded-lg text-sm text-white/40 cursor-not-allowed`}
                  style={{ fontFamily: 'Inter, sans-serif' }}
                  title={collapsed ? item.label : undefined}
                >
                  <span className="text-white/30">{item.icon}</span>
                  {!collapsed && (
                    <>
                      <span>{item.label}</span>
                      {item.badge && (
                        <span className={`ml-auto text-[9px] uppercase tracking-wider ${badgeStyles[item.badge]}`}>
                          {badgeLabels[item.badge]}
                        </span>
                      )}
                    </>
                  )}
                </div>
              </li>
            );
          })}
        </ul>

        {/* P2 Section */}
        {!collapsed && (
          <div className="mt-6 px-3">
            <p className="text-white/30 text-xs font-medium uppercase tracking-wider px-3 mb-2">
              Phase 2
            </p>
            <ul className="space-y-1">
              {p2Items.map((item) => (
                <li key={item.href}>
                  <button
                    onClick={() => setP2Modal(p2ModalKey(item.href))}
                    className="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm text-white/40 hover:text-white/60 hover:bg-white/5 transition-colors text-left"
                    style={{ fontFamily: 'Inter, sans-serif' }}
                  >
                    <span className="text-white/30">{item.icon}</span>
                    <span>{item.label}</span>
                    {item.badge && (
                      <span className={`ml-auto text-[9px] uppercase tracking-wider ${badgeStyles[item.badge]}`}>
                        {badgeLabels[item.badge]}
                      </span>
                    )}
                  </button>
                </li>
              ))}
            </ul>
          </div>
        )}
        {collapsed && (
          <div className="mt-6 px-2 space-y-1">
            {p2Items.map((item) => (
              <button
                key={item.href}
                onClick={() => setP2Modal(p2ModalKey(item.href))}
                className="w-full flex items-center justify-center px-3 py-2.5 rounded-lg text-white/30 hover:text-white/60 hover:bg-white/5 transition-colors"
                title={item.label}
              >
                {item.icon}
              </button>
            ))}
          </div>
        )}
      </nav>

      {/* User section */}
      <div className="p-4 border-t border-white/10">
        <button
          onClick={handleSignOut}
          className={`w-full flex items-center ${collapsed ? 'justify-center' : 'gap-3'} px-3 py-2.5 rounded-lg text-sm text-white/70 hover:text-white hover:bg-white/5 transition-colors`}
          style={{ fontFamily: 'Inter, sans-serif' }}
          title={collapsed ? 'Sign Out' : undefined}
        >
          <LogOut size={20} className="text-white/50" />
          {!collapsed && <span>Sign Out</span>}
        </button>
      </div>
    </aside>

    {p2Modal && (
      <P2PreviewModal feature={p2Modal} onClose={() => setP2Modal(null)} />
    )}
    </>
  );
}
