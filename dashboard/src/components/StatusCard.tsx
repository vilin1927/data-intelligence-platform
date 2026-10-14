'use client';

import { useState, useEffect, useRef, useCallback } from 'react';
import { apiPost } from '@/lib/api';

interface StatusCardProps {
  source: string;
  display_name: string;
  status: 'green' | 'yellow' | 'red';
  last_sync: string | null;
  rows_total: number;
  error: string | null;
}

const STATUS_COLORS = {
  green: {
    dot: 'bg-emerald-400',
    border: 'border-emerald-500/30',
    bg: 'bg-emerald-500/5',
    label: 'Connected',
  },
  yellow: {
    dot: 'bg-amber-400',
    border: 'border-amber-500/30',
    bg: 'bg-amber-500/5',
    label: 'Stale',
  },
  red: {
    dot: 'bg-red-400',
    border: 'border-red-500/30',
    bg: 'bg-red-500/5',
    label: 'Error',
  },
};

// Map card source keys to sync API source values
const SYNC_SOURCE_MAP: Record<string, string> = {
  vinsight: 'vinsight',
  xero_trust: 'xero',
  xero_wines: 'xero',
  google_sheets: 'sheets',
};

function formatSyncTime(dateStr: string | null): string {
  if (!dateStr) return 'Never';
  const date = new Date(dateStr);
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffMins = Math.floor(diffMs / 60000);
  const diffHours = Math.floor(diffMs / 3600000);
  const diffDays = Math.floor(diffMs / 86400000);

  if (diffMins < 1) return 'Just now';
  if (diffMins < 60) return `${diffMins}m ago`;
  if (diffHours < 24) return `${diffHours}h ago`;
  if (diffDays < 7) return `${diffDays}d ago`;

  return date.toLocaleDateString('en-AU', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  });
}

type SyncState = 'idle' | 'syncing' | 'success' | 'failed' | 'cooldown';

export default function StatusCard({
  source,
  display_name,
  status,
  last_sync,
  rows_total,
  error,
}: StatusCardProps) {
  const colors = STATUS_COLORS[status];
  const [syncState, setSyncState] = useState<SyncState>('idle');
  const [cooldownSeconds, setCooldownSeconds] = useState(0);
  const cooldownRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const syncSource = SYNC_SOURCE_MAP[source];
  const cooldownKey = `sync_cooldown_${source}`;

  const clearCooldownInterval = useCallback(() => {
    if (cooldownRef.current) {
      clearInterval(cooldownRef.current);
      cooldownRef.current = null;
    }
  }, []);

  // On mount: check localStorage for active cooldown
  useEffect(() => {
    const stored = localStorage.getItem(cooldownKey);
    if (stored) {
      const endTime = parseInt(stored, 10);
      const remaining = Math.ceil((endTime - Date.now()) / 1000);
      if (remaining > 0) {
        setSyncState('cooldown');
        setCooldownSeconds(remaining);
        cooldownRef.current = setInterval(() => {
          const left = Math.ceil((endTime - Date.now()) / 1000);
          if (left <= 0) {
            clearCooldownInterval();
            setSyncState('idle');
            setCooldownSeconds(0);
            localStorage.removeItem(cooldownKey);
          } else {
            setCooldownSeconds(left);
          }
        }, 1000);
      } else {
        localStorage.removeItem(cooldownKey);
      }
    }
    return () => clearCooldownInterval();
  }, [clearCooldownInterval, cooldownKey]);

  const startCooldown = useCallback(() => {
    const endTime = Date.now() + 60000;
    localStorage.setItem(cooldownKey, endTime.toString());
    setSyncState('cooldown');
    setCooldownSeconds(60);

    clearCooldownInterval();
    cooldownRef.current = setInterval(() => {
      const left = Math.ceil((endTime - Date.now()) / 1000);
      if (left <= 0) {
        clearCooldownInterval();
        setSyncState('idle');
        setCooldownSeconds(0);
        localStorage.removeItem(cooldownKey);
      } else {
        setCooldownSeconds(left);
      }
    }, 1000);
  }, [clearCooldownInterval, cooldownKey]);

  const handleSync = async () => {
    if (!syncSource || syncState !== 'idle') return;

    setSyncState('syncing');

    try {
      const res = await apiPost('/api/sync', { source: syncSource });

      const data = await res.json();

      if (data.success) {
        setSyncState('success');
        startCooldown();
        setTimeout(() => {
          window.location.reload();
        }, 2000);
      } else {
        setSyncState('failed');
        setTimeout(() => setSyncState('idle'), 3000);
      }
    } catch {
      setSyncState('failed');
      setTimeout(() => setSyncState('idle'), 3000);
    }
  };

  const isButtonDisabled =
    syncState === 'syncing' ||
    syncState === 'success' ||
    syncState === 'cooldown';

  const renderSyncButton = () => {
    if (!syncSource) return null;

    let buttonText: React.ReactNode;
    let buttonClasses =
      'w-full mt-4 text-xs px-3 py-1.5 rounded transition-colors font-medium ';

    switch (syncState) {
      case 'syncing':
        buttonText = (
          <span className="flex items-center justify-center gap-1.5">
            <svg
              className="animate-spin h-3 w-3"
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
            >
              <circle
                className="opacity-25"
                cx="12"
                cy="12"
                r="10"
                stroke="currentColor"
                strokeWidth="4"
              />
              <path
                className="opacity-75"
                fill="currentColor"
                d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
              />
            </svg>
            Syncing...
          </span>
        );
        buttonClasses += 'bg-slate-700 text-slate-400 cursor-not-allowed';
        break;
      case 'success':
        buttonText = (
          <span className="text-emerald-400">Synced!</span>
        );
        buttonClasses += 'bg-emerald-500/10 border border-emerald-500/30 cursor-not-allowed';
        break;
      case 'failed':
        buttonText = (
          <span className="text-red-400">Failed</span>
        );
        buttonClasses += 'bg-red-500/10 border border-red-500/30 cursor-not-allowed';
        break;
      case 'cooldown':
        buttonText = `Sync Now (${cooldownSeconds}s)`;
        buttonClasses += 'bg-slate-700 text-slate-500 cursor-not-allowed';
        break;
      default:
        buttonText = 'Sync Now';
        buttonClasses += 'bg-slate-600 text-slate-200 hover:bg-slate-500';
        break;
    }

    return (
      <button
        onClick={handleSync}
        disabled={isButtonDisabled}
        className={buttonClasses}
      >
        {buttonText}
      </button>
    );
  };

  return (
    <div
      className={`rounded-xl border ${colors.border} ${colors.bg} p-5 transition-all hover:shadow-md`}
    >
      <div className="flex items-center justify-between mb-4">
        <h3 className="text-sm font-semibold text-slate-300 uppercase tracking-wide">
          {display_name}
        </h3>
        <div className="flex items-center gap-2">
          <span
            className={`inline-block h-2.5 w-2.5 rounded-full ${colors.dot} shadow-sm`}
            style={{
              boxShadow:
                status === 'green'
                  ? '0 0 6px rgba(52, 211, 153, 0.5)'
                  : status === 'yellow'
                  ? '0 0 6px rgba(251, 191, 36, 0.5)'
                  : '0 0 6px rgba(248, 113, 113, 0.5)',
            }}
          />
          <span
            className={`text-xs font-medium ${
              status === 'green'
                ? 'text-emerald-400'
                : status === 'yellow'
                ? 'text-amber-400'
                : 'text-red-400'
            }`}
          >
            {colors.label}
          </span>
        </div>
      </div>

      <div className="space-y-2">
        <div className="flex justify-between items-baseline">
          <span className="text-xs text-slate-500">Last sync</span>
          <span className="text-sm text-slate-200 font-medium">
            {formatSyncTime(last_sync)}
          </span>
        </div>
        <div className="flex justify-between items-baseline">
          <span className="text-xs text-slate-500">Rows synced</span>
          <span className="text-sm text-slate-200 font-medium">
            {rows_total.toLocaleString()}
          </span>
        </div>
      </div>

      {error && status === 'red' && (
        <div className="mt-3 rounded-md bg-red-500/10 border border-red-500/20 px-3 py-2">
          <p className="text-xs text-red-300 line-clamp-2">{error}</p>
        </div>
      )}

      {renderSyncButton()}
    </div>
  );
}
