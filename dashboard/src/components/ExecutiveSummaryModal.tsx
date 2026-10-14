'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import Modal from './Modal';
import { apiGet } from '@/lib/api';
import { useGlobalMonth, formatYearMonth } from '@/lib/globalMonth';
import { Loader2, AlertTriangle, TrendingUp, TrendingDown } from 'lucide-react';

interface SummaryHeadline {
  revenue: number;
  cases: number;
  gross_profit: number;
  gp_pct: number | null;
  mmt_pct: number | null;
  yoy_pct: number | null;
  prev_month_revenue: number;
  prev_month_gp: number;
  yoy_revenue: number;
}

interface SummaryMat {
  revenue: number;
  cases: number;
  gross_profit: number;
  gp_pct: number | null;
}

interface SummaryWine {
  sku_code: string;
  item_description: string;
  variety: string | null;
  region: string | null;
  revenue: number;
  cases: number;
}

interface SummaryAlerts {
  recent_errors: number;
  recent_dead_letters: number;
  last_sync: string | null;
}

interface ExecutiveSummary {
  month: string;
  generated_at: string;
  headline: SummaryHeadline;
  mat: SummaryMat;
  active_customers: number;
  top_wines: SummaryWine[];
  alerts: SummaryAlerts;
}

interface ExecutiveSummaryModalProps {
  isOpen: boolean;
  onClose: () => void;
}

function formatCurrency(value: number): string {
  if (!Number.isFinite(value)) return '—';
  if (Math.abs(value) >= 1_000_000) return `$${(value / 1_000_000).toFixed(2)}M`;
  if (Math.abs(value) >= 1_000) return `$${(value / 1_000).toFixed(1)}K`;
  return `$${value.toFixed(0)}`;
}

function formatPct(value: number | null): string {
  if (value === null || !Number.isFinite(value)) return '—';
  return `${value >= 0 ? '+' : ''}${value.toFixed(1)}%`;
}

function PctBadge({ value }: { value: number | null }) {
  if (value === null || !Number.isFinite(value)) {
    return <span className="text-[#8A8A8D]">—</span>;
  }
  const positive = value > 0;
  const negative = value < 0;
  const Icon = positive ? TrendingUp : negative ? TrendingDown : null;
  const color = positive ? 'text-[#1B7A3D]' : negative ? 'text-[#B42318]' : 'text-[#505052]';
  return (
    <span className={`inline-flex items-center gap-1 ${color}`}>
      {Icon ? <Icon size={12} /> : null}
      <span className="font-medium">{formatPct(value)}</span>
    </span>
  );
}

export default function ExecutiveSummaryModal({ isOpen, onClose }: ExecutiveSummaryModalProps) {
  const { month } = useGlobalMonth();
  const [data, setData] = useState<ExecutiveSummary | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!isOpen) return;
    let cancelled = false;
    setLoading(true);
    setError(null);
    setData(null);

    apiGet(`/api/reports/executive-summary?month=${encodeURIComponent(month)}`)
      .then(async (res) => {
        if (cancelled) return;
        if (!res.ok) {
          setError('Failed to load executive summary');
          return;
        }
        const json = (await res.json()) as ExecutiveSummary;
        setData(json);
      })
      .catch(() => !cancelled && setError('Network error'))
      .finally(() => !cancelled && setLoading(false));

    return () => {
      cancelled = true;
    };
  }, [isOpen, month]);

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={`Executive Summary — as at ${formatYearMonth(month)}`}
      size="xl"
    >
      {loading ? (
        <div className="flex items-center gap-2 text-sm text-[#505052] py-12 justify-center">
          <Loader2 size={16} className="animate-spin" />
          Crunching the numbers…
        </div>
      ) : error ? (
        <div className="flex items-center gap-2 text-sm text-[#B42318] py-6">
          <AlertTriangle size={16} /> {error}
        </div>
      ) : data ? (
        <div className="space-y-5">
          {/* Headline KPIs */}
          <section>
            <h3 className="text-[10px] uppercase tracking-wide text-[#8A8A8D] font-medium mb-2">
              Headline ({formatYearMonth(data.month)})
            </h3>
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 text-sm">
              <div className="p-3 rounded-lg bg-[#FAF9F7] border border-[#D8D9DA]">
                <div className="text-[10px] text-[#505052] uppercase tracking-wide">Revenue</div>
                <div className="text-lg font-semibold text-[#1F1F1F]" style={{ fontFamily: 'Cardo, serif' }}>
                  {formatCurrency(data.headline.revenue)}
                </div>
                <div className="text-xs mt-1">
                  MMT <PctBadge value={data.headline.mmt_pct} />
                  {' '}· YOY <PctBadge value={data.headline.yoy_pct} />
                </div>
              </div>
              <div className="p-3 rounded-lg bg-[#FAF9F7] border border-[#D8D9DA]">
                <div className="text-[10px] text-[#505052] uppercase tracking-wide">Gross Profit</div>
                <div className="text-lg font-semibold text-[#1F1F1F]" style={{ fontFamily: 'Cardo, serif' }}>
                  {formatCurrency(data.headline.gross_profit)}
                </div>
                <div className="text-xs mt-1 text-[#505052]">
                  GP% <span className="font-medium text-[#1F1F1F]">{formatPct(data.headline.gp_pct)}</span>
                </div>
              </div>
              <div className="p-3 rounded-lg bg-[#FAF9F7] border border-[#D8D9DA]">
                <div className="text-[10px] text-[#505052] uppercase tracking-wide">Cases</div>
                <div className="text-lg font-semibold text-[#1F1F1F]" style={{ fontFamily: 'Cardo, serif' }}>
                  {data.headline.cases.toLocaleString('en-AU')}
                </div>
              </div>
              <div className="p-3 rounded-lg bg-[#FAF9F7] border border-[#D8D9DA]">
                <div className="text-[10px] text-[#505052] uppercase tracking-wide">Active Customers</div>
                <div className="text-lg font-semibold text-[#1F1F1F]" style={{ fontFamily: 'Cardo, serif' }}>
                  {data.active_customers.toLocaleString('en-AU')}
                </div>
                <div className="text-xs mt-1 text-[#505052]">12-mo distinct</div>
              </div>
            </div>
          </section>

          {/* MAT */}
          <section>
            <h3 className="text-[10px] uppercase tracking-wide text-[#8A8A8D] font-medium mb-2">
              Moving Annual Total (12 months ending {formatYearMonth(data.month)})
            </h3>
            <div className="grid grid-cols-3 gap-3 text-sm">
              <div className="p-3 rounded-lg bg-white border border-[#D8D9DA]">
                <div className="text-[10px] text-[#505052] uppercase tracking-wide">MAT Revenue</div>
                <div className="text-base font-semibold text-[#1F1F1F]">{formatCurrency(data.mat.revenue)}</div>
              </div>
              <div className="p-3 rounded-lg bg-white border border-[#D8D9DA]">
                <div className="text-[10px] text-[#505052] uppercase tracking-wide">MAT Gross Profit</div>
                <div className="text-base font-semibold text-[#1F1F1F]">{formatCurrency(data.mat.gross_profit)}</div>
                <div className="text-xs text-[#505052] mt-0.5">GP% {formatPct(data.mat.gp_pct)}</div>
              </div>
              <div className="p-3 rounded-lg bg-white border border-[#D8D9DA]">
                <div className="text-[10px] text-[#505052] uppercase tracking-wide">MAT Cases</div>
                <div className="text-base font-semibold text-[#1F1F1F]">{data.mat.cases.toLocaleString('en-AU')}</div>
              </div>
            </div>
          </section>

          {/* Top wines */}
          <section>
            <h3 className="text-[10px] uppercase tracking-wide text-[#8A8A8D] font-medium mb-2">
              Top 5 Wines (12 months)
            </h3>
            <table className="w-full text-xs" style={{ fontFamily: 'Inter, sans-serif' }}>
              <thead>
                <tr className="text-left text-[#505052] border-b border-[#D8D9DA]">
                  <th className="py-2 pr-3 font-medium">#</th>
                  <th className="py-2 pr-3 font-medium">Wine</th>
                  <th className="py-2 pr-3 font-medium">Variety</th>
                  <th className="py-2 pr-3 text-right font-medium">Cases</th>
                  <th className="py-2 pr-3 text-right font-medium">Revenue</th>
                </tr>
              </thead>
              <tbody>
                {data.top_wines.length === 0 ? (
                  <tr><td colSpan={5} className="py-4 text-center text-[#505052]">No sales data</td></tr>
                ) : (
                  data.top_wines.map((w, i) => (
                    <tr key={w.sku_code} className="border-b border-[#D8D9DA]/40">
                      <td className="py-2 pr-3 text-[#505052]">{i + 1}</td>
                      <td className="py-2 pr-3">
                        <div className="text-[#1F1F1F] font-medium">{w.item_description}</div>
                        <div className="text-[#505052]/70 text-[10px]">{w.sku_code}</div>
                      </td>
                      <td className="py-2 pr-3 text-[#505052]">{w.variety ?? '—'}</td>
                      <td className="py-2 pr-3 text-right text-[#505052]">{w.cases.toLocaleString('en-AU')}</td>
                      <td className="py-2 pr-3 text-right text-[#1F1F1F] font-medium">{formatCurrency(w.revenue)}</td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </section>

          {/* Alerts */}
          {(data.alerts.recent_errors > 0 || data.alerts.recent_dead_letters > 0) && (
            <section className="bg-amber-50 border border-amber-200 rounded-lg p-3 text-xs text-amber-800 flex items-start gap-2">
              <AlertTriangle size={14} className="flex-shrink-0 mt-0.5" />
              <div>
                {data.alerts.recent_errors > 0 ? (
                  <div>{data.alerts.recent_errors} sync error(s) in last 24h.</div>
                ) : null}
                {data.alerts.recent_dead_letters > 0 ? (
                  // B7 fix: link to /admin (sync status surface) since no dedicated
                  // dead-letter UI exists yet (queued for Phase 2).
                  <div>
                    {data.alerts.recent_dead_letters} dead-letter row(s) —{' '}
                    <Link href="/admin" className="underline hover:text-amber-900">
                      review in admin
                    </Link>{' '}
                    (full review queued for Phase 2).
                  </div>
                ) : null}
              </div>
            </section>
          )}
        </div>
      ) : null}
    </Modal>
  );
}
