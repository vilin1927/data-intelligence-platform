'use client';

import {
  BarChart3,
  Users,
  MapPin,
  TrendingUp,
  Clock,
  Package,
  Layers,
  Wine,
  FileText,
} from 'lucide-react';
import type { ReactNode } from 'react';
import { useGlobalMonth, formatYearMonth } from '@/lib/globalMonth';

/**
 * JC-330/331/335: 1-click preset reports replace prompt-chip text on /chat.
 * Each button injects a structured prompt (with the global "as at mmm-yy" month).
 * AI Chat then runs SQL via the existing pipeline.
 *
 * AC2 requires ≥8 buttons; we ship 10.
 */

export interface PresetReport {
  id: string;
  label: string;
  description: string;
  icon: ReactNode;
  prompt: (month: string) => string; // 'YYYY-MM'
  group: 'summary' | 'sales' | 'time' | 'inventory' | 'product';
}

const ICON_SIZE = 18;

export const PRESET_REPORTS: PresetReport[] = [
  {
    id: 'executive-summary',
    label: 'Executive Summary',
    description: 'Revenue, GP, top wines, MAT/MMT/YOY in one view',
    icon: <FileText size={ICON_SIZE} />,
    group: 'summary',
    prompt: (m) =>
      `Run the Executive Summary report as at ${formatYearMonth(m)} (${m}). ` +
      `Show total revenue, gross profit (economic basis), MAT, MMT vs prior month, ` +
      `YOY vs same month last year, top 5 wines by revenue, and any ALERTS (sync errors, low GP).`,
  },
  {
    id: 'top-customers',
    label: 'Top Customers',
    description: 'Top 20 customers by revenue (last 12 months)',
    icon: <Users size={ICON_SIZE} />,
    group: 'sales',
    prompt: (m) =>
      `Show the top 20 customers by net revenue for the 12 months ending ${formatYearMonth(m)} (${m}). ` +
      `Include channel, territory, cases, revenue, and YoY change.`,
  },
  {
    id: 'sales-by-territory',
    label: 'Sales by Territory',
    description: 'Cases + revenue per territory with MQT variance',
    icon: <MapPin size={ICON_SIZE} />,
    group: 'sales',
    prompt: (m) =>
      `Show sales performance by territory for the quarter ending ${formatYearMonth(m)} (${m}). ` +
      `Include cases, gross revenue, deductions, net revenue, GP%, and MQT variance vs prior quarter.`,
  },
  {
    id: 'margin-by-sku',
    label: 'Margin by SKU',
    description: 'Economic GP% per wine, ranked',
    icon: <TrendingUp size={ICON_SIZE} />,
    group: 'product',
    prompt: (m) =>
      `For the 12 months ending ${formatYearMonth(m)} (${m}), list every active SKU with revenue, ` +
      `economic COGS per unit, accounting COGS per unit, GP% (economic), and GP% (accounting). Sort by GP% economic descending.`,
  },
  {
    id: 'mat-report',
    label: 'MAT (Moving Annual Total)',
    description: 'Trailing 12-month total revenue + cases',
    icon: <TrendingUp size={ICON_SIZE} />,
    group: 'time',
    prompt: (m) =>
      `Compute the Moving Annual Total (MAT) for the 12 months ending ${formatYearMonth(m)} (${m}). ` +
      `Break out by channel (DWS, ALM, Direct) and compare to the prior MAT period.`,
  },
  {
    id: 'mmt-report',
    label: 'MMT (Month-on-Month)',
    description: 'Current month vs prior month with delta %',
    icon: <BarChart3 size={ICON_SIZE} />,
    group: 'time',
    prompt: (m) =>
      `Compare net revenue and cases for ${formatYearMonth(m)} (${m}) versus the previous calendar month. ` +
      `Show absolute delta and percentage change by channel.`,
  },
  {
    id: 'mqt-report',
    label: 'MQT (Quarter Trend)',
    description: 'Last quarter vs prior quarter, by territory',
    icon: <Clock size={ICON_SIZE} />,
    group: 'time',
    prompt: (m) =>
      `Show Moving Quarterly Total (MQT) for the quarter ending ${formatYearMonth(m)} (${m}) compared to the prior quarter. ` +
      `Break out by territory and channel.`,
  },
  {
    id: 'inventory-cover',
    label: 'Inventory Cover',
    description: 'Months of stock cover by SKU at current velocity',
    icon: <Package size={ICON_SIZE} />,
    group: 'inventory',
    prompt: (_m) =>
      `For each active SKU show units in stock, 6-month sales velocity (units/month), ` +
      `and stock cover (months). Flag any SKU with under 2 months cover.`,
  },
  {
    id: 'channel-mix',
    label: 'Channel Mix',
    description: 'Revenue split DWS / ALM / Direct',
    icon: <Layers size={ICON_SIZE} />,
    group: 'sales',
    prompt: (m) =>
      `Show revenue split across DWS, ALM and Direct channels for the 12 months ending ${formatYearMonth(m)} (${m}). ` +
      `Include % share of total and YoY change per channel.`,
  },
  {
    id: 'vintage-performance',
    label: 'Vintage Performance',
    description: 'Revenue + GP% per vintage year',
    icon: <Wine size={ICON_SIZE} />,
    group: 'product',
    prompt: (m) =>
      `Show net revenue and average economic GP% by vintage year for the 12 months ending ${formatYearMonth(m)} (${m}). ` +
      `Include cases sold per vintage.`,
  },
];

interface PresetReportButtonsProps {
  onPick: (prompt: string) => void;
  variant?: 'grid' | 'compact';
}

const GROUP_LABELS: Record<PresetReport['group'], string> = {
  summary: 'Summary',
  sales: 'Sales',
  time: 'Time-series',
  inventory: 'Inventory',
  product: 'Product',
};

export default function PresetReportButtons({ onPick, variant = 'grid' }: PresetReportButtonsProps) {
  const { month } = useGlobalMonth();

  if (variant === 'compact') {
    return (
      <div className="flex flex-wrap gap-2" style={{ fontFamily: 'Inter, sans-serif' }}>
        {PRESET_REPORTS.map((r) => (
          <button
            key={r.id}
            type="button"
            onClick={() => onPick(r.prompt(month))}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-[#D8D9DA] bg-white text-xs text-[#1F1F1F] hover:border-[#931220] hover:bg-[#931220]/5 transition-colors"
            data-preset-id={r.id}
            title={r.description}
          >
            <span className="text-[#931220]">{r.icon}</span>
            {r.label}
          </button>
        ))}
      </div>
    );
  }

  // grid variant — 1-click report buttons (replaces sample-prompt chips)
  const groups = (['summary', 'sales', 'time', 'product', 'inventory'] as const).map((g) => ({
    group: g,
    items: PRESET_REPORTS.filter((r) => r.group === g),
  }));

  return (
    <div
      className="w-full space-y-5"
      style={{ fontFamily: 'Inter, sans-serif' }}
      data-testid="preset-report-buttons"
    >
      <div className="flex items-center gap-2 text-xs text-[#505052]">
        <BarChart3 size={14} className="text-[#931220]" />
        <span>
          1-click reports — period: <span className="font-medium text-[#1F1F1F]">{formatYearMonth(month)}</span>
        </span>
      </div>

      {groups.map(({ group, items }) =>
        items.length === 0 ? null : (
          <div key={group}>
            <h4 className="text-[10px] uppercase tracking-wide text-[#8A8A8D] mb-2 font-medium">
              {GROUP_LABELS[group]}
            </h4>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
              {items.map((r) => (
                <button
                  key={r.id}
                  type="button"
                  onClick={() => onPick(r.prompt(month))}
                  className="flex items-start gap-3 text-left px-4 py-3 rounded-xl border border-[#E5E5E5] bg-white hover:bg-[#F5F5F5] hover:border-[#931220] transition-all"
                  data-preset-id={r.id}
                >
                  <span className="flex-shrink-0 w-8 h-8 rounded-lg bg-[#931220]/10 flex items-center justify-center text-[#931220]">
                    {r.icon}
                  </span>
                  <span className="flex-1 min-w-0">
                    <span className="block text-sm font-medium text-[#1F1F1F]">{r.label}</span>
                    <span className="block text-xs text-[#505052] mt-0.5">{r.description}</span>
                  </span>
                </button>
              ))}
            </div>
          </div>
        )
      )}
    </div>
  );
}
