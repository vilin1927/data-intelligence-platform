'use client';

/**
 * /admin/unmatched-skus
 *
 * B6b — JC-107 / JC-108 / JC-120: One-click approve UI for matching
 * unmatched SKUs to canonical_sku entries.
 *
 * Lists every sku row with sales activity but no canonical_sku_id. For each:
 *   - Revenue + transaction summary
 *   - Top-3 live fuzzy suggestions (pg_trgm on canonical_sku.sku_name)
 *   - Score bars per suggestion
 *   - Approve button on each suggestion
 *   - Manual canonical_sku typeahead (existing canonicals only — JC-108)
 *   - Skip button (defers review)
 *
 * JC-108: NO free-form create. Brand-new canonicals come from the accdb
 * pipeline (etl/import_sku_from_access_first.py); the modal only links
 * existing canonicals.
 *
 * Bucket colour coding (mirrors /admin/unmatched-customers):
 *   HIGH_CONFIDENCE_AUTO -> green badge
 *   REVIEW_NEEDED        -> yellow badge
 *   NO_MATCH             -> red badge
 *
 * Auth: protected by middleware.ts (all /admin/* require session cookie).
 *
 * API:
 *   GET  /api/admin/unmatched-skus
 *   POST /api/admin/unmatched-skus/[id]/match
 *   POST /api/admin/unmatched-skus/[id]/skip
 */

import { useEffect, useState, useCallback, useRef } from 'react';
import { apiGet, apiPost } from '@/lib/api';
import AppLayout from '@/components/AppLayout';
import Badge from '@/components/Badge';
import {
  CheckCircle,
  XCircle,
  Search,
  ChevronDown,
  ChevronRight,
  AlertTriangle,
  Package,
  DollarSign,
  RefreshCw,
} from 'lucide-react';

// ─── Types ──────────────────────────────────────────────────────────────────

interface CanonicalSkuSuggestion {
  canonical_sku_id: number;
  canonical_sku_name: string;
  range_name: string | null;
  range_group: string | null;
  similarity: number;
}

interface ReviewInfo {
  action: string;
  applied_canonical_sku_id: number | null;
  reviewer: string;
  reviewed_at: string;
  notes: string | null;
}

interface UnmatchedSku {
  sku_id: number;
  sku_code: string;
  item_description: string;
  variety: string | null;
  region: string | null;
  vintage: number | null;
  source_system: string | null;
  revenue_aud: string;
  txn_count: number;
  qty_cases: string;
  min_date: string | null;
  max_date: string | null;
  review_status: string;
  review: ReviewInfo | null;
  suggestions: CanonicalSkuSuggestion[];
}

interface CanonicalSkuSearchResult {
  id: number;
  sku_name: string;
  range_name: string | null;
  range_group: string | null;
}

// ─── Helpers ────────────────────────────────────────────────────────────────

function formatRevenue(rev: string | number): string {
  const n = typeof rev === 'string' ? parseFloat(rev) : rev;
  if (isNaN(n)) return '$0.00';
  return new Intl.NumberFormat('en-AU', { style: 'currency', currency: 'AUD' }).format(n);
}

function bucketBadgeVariant(reviewStatus: string): 'success' | 'warning' | 'error' | 'info' | 'neutral' {
  switch (reviewStatus) {
    case 'matched': return 'success';
    case 'skipped': return 'neutral';
    case 'pending': return 'info';
    default: return 'neutral';
  }
}

function scoreColor(score: number): string {
  if (score >= 90) return 'bg-green-500';
  if (score >= 70) return 'bg-yellow-400';
  return 'bg-red-400';
}

function scoreBarWidth(score: number): string {
  return `${Math.min(100, Math.max(0, score))}%`;
}

// ─── Canonical SKU Typeahead ─────────────────────────────────────────────────

interface CanonicalTypeaheadProps {
  onSelect: (canonical: CanonicalSkuSearchResult) => void;
  placeholder?: string;
}

function CanonicalSkuTypeahead({ onSelect, placeholder = 'Search canonical SKUs…' }: CanonicalTypeaheadProps) {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<CanonicalSkuSearchResult[]>([]);
  const [loading, setLoading] = useState(false);
  const [open, setOpen] = useState(false);
  const debounceRef = useRef<ReturnType<typeof setTimeout>>();

  const handleChange = useCallback((value: string) => {
    setQuery(value);
    if (debounceRef.current) clearTimeout(debounceRef.current);
    if (value.length < 2) {
      setResults([]);
      setOpen(false);
      return;
    }
    debounceRef.current = setTimeout(async () => {
      setLoading(true);
      try {
        // /api/reference-tables?table=canonical_sku reads from the same
        // canonical_sku pool the modal must link against. JC-108: existing
        // canonicals only.
        const res = await apiGet(`/api/reference-tables?table=canonical_sku&search=${encodeURIComponent(value)}&page=1`);
        if (res.ok) {
          const data = await res.json();
          const mapped: CanonicalSkuSearchResult[] = (data.rows || []).slice(0, 8).map((r: {
            canonical_id?: number;
            id?: number;
            name?: string;
            sku_name?: string;
            range_name?: string | null;
            range_group?: string | null;
          }) => ({
            id: (r.canonical_id ?? r.id) as number,
            sku_name: (r.sku_name ?? r.name ?? '') as string,
            range_name: r.range_name ?? null,
            range_group: r.range_group ?? null,
          }));
          setResults(mapped);
          setOpen(true);
        }
      } catch {
        // ignore — typeahead is best-effort
      } finally {
        setLoading(false);
      }
    }, 300);
  }, []);

  return (
    <div className="relative">
      <div className="flex items-center gap-2 border border-gray-200 rounded-lg px-3 py-2 bg-white focus-within:ring-2 focus-within:ring-blue-500 focus-within:border-blue-500">
        <Search size={14} className="text-gray-400 shrink-0" />
        <input
          type="text"
          className="flex-1 text-sm outline-none text-gray-800 placeholder-gray-400"
          placeholder={placeholder}
          value={query}
          onChange={e => handleChange(e.target.value)}
          onFocus={() => results.length > 0 && setOpen(true)}
          onBlur={() => setTimeout(() => setOpen(false), 150)}
        />
        {loading && <RefreshCw size={12} className="animate-spin text-gray-400" />}
      </div>
      {open && query.length >= 2 && !loading && (
        <div className="absolute z-50 top-full left-0 right-0 mt-1 bg-white border border-gray-200 rounded-lg shadow-lg max-h-48 overflow-auto">
          {results.length === 0 ? (
            <div className="px-3 py-2 text-sm text-gray-500 italic">No matches</div>
          ) : (
            results.map(r => (
              <button
                key={r.id}
                className="w-full text-left px-3 py-2 hover:bg-gray-50 text-sm border-b border-gray-100 last:border-0"
                onMouseDown={() => {
                  onSelect(r);
                  setQuery('');
                  setOpen(false);
                }}
              >
                <div className="font-medium text-gray-800 truncate">{r.sku_name}</div>
                <div className="text-xs text-gray-400">
                  {r.range_name ?? ''}
                  {r.range_group ? ` · ${r.range_group}` : ''}
                </div>
              </button>
            ))
          )}
        </div>
      )}
    </div>
  );
}

// ─── SKU Row ────────────────────────────────────────────────────────────────

interface SkuRowProps {
  sku: UnmatchedSku;
  onMatch: (skuId: number, canonicalId: number, suggestedId: number | null, score: number | null, bucket: string, notes: string) => Promise<void>;
  onSkip: (skuId: number, notes: string) => Promise<void>;
}

function SkuRow({ sku, onMatch, onSkip }: SkuRowProps) {
  const [expanded, setExpanded] = useState(false);
  const [notes, setNotes] = useState('');
  const [pendingCanonical, setPendingCanonical] = useState<CanonicalSkuSearchResult | null>(null);
  const [applying, setApplying] = useState(false);

  const isReviewed = sku.review_status === 'matched' || sku.review_status === 'skipped';

  // Bucket from top suggestion (mirrors customer-side logic).
  let bucket = 'NO_MATCH';
  if (sku.suggestions.length > 0) {
    const top1 = sku.suggestions[0].similarity;
    const top2 = sku.suggestions[1]?.similarity ?? 0;
    if (top1 >= 90 && (top1 - top2) >= 10) bucket = 'HIGH_CONFIDENCE_AUTO';
    else if (top1 >= 70) bucket = 'REVIEW_NEEDED';
    else bucket = 'NO_MATCH';
  }

  const bucketBadge = bucket === 'HIGH_CONFIDENCE_AUTO'
    ? 'success'
    : bucket === 'REVIEW_NEEDED'
      ? 'warning'
      : 'error';

  return (
    <div className={`border rounded-xl mb-3 overflow-hidden ${isReviewed ? 'opacity-60' : 'bg-white'}`}>
      {/* Header */}
      <div
        className="flex items-center gap-3 px-4 py-3 cursor-pointer hover:bg-gray-50 transition-colors"
        onClick={() => setExpanded(e => !e)}
      >
        <span className="text-gray-400">{expanded ? <ChevronDown size={16} /> : <ChevronRight size={16} />}</span>

        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <span className="font-mono text-xs bg-gray-100 px-1.5 py-0.5 rounded text-gray-700 shrink-0">{sku.sku_code}</span>
            <span className="font-medium text-gray-900 text-sm truncate">{sku.item_description}</span>
            {sku.vintage && <span className="text-xs text-gray-400 shrink-0">{sku.vintage}</span>}
          </div>
          <div className="text-xs text-gray-400 mt-0.5">
            {sku.txn_count} txns · {parseFloat(sku.qty_cases).toFixed(0)} cases
            {sku.variety && <> · {sku.variety}</>}
            {sku.region && <> · {sku.region}</>}
            {sku.min_date && <> · {sku.min_date.slice(0,7)} – {sku.max_date?.slice(0,7)}</>}
          </div>
        </div>

        <div className="flex items-center gap-3 shrink-0">
          <span className="font-semibold text-gray-900 text-sm">{formatRevenue(sku.revenue_aud)}</span>
          {isReviewed ? (
            <Badge variant={bucketBadgeVariant(sku.review_status)}>{sku.review_status}</Badge>
          ) : (
            <Badge variant={bucketBadge as 'success' | 'warning' | 'error'}>
              {bucket === 'HIGH_CONFIDENCE_AUTO' ? 'HIGH' : bucket === 'REVIEW_NEEDED' ? 'REVIEW' : 'NO MATCH'}
            </Badge>
          )}
        </div>
      </div>

      {expanded && (
        <div className="border-t border-gray-100 px-4 py-4 bg-gray-50 space-y-4">
          {/* Review banner */}
          {isReviewed && sku.review && (
            <div className={`rounded-lg px-3 py-2 text-sm flex items-center gap-2 ${
              sku.review.action === 'matched'
                ? 'bg-green-50 text-green-800 border border-green-200'
                : 'bg-gray-100 text-gray-600 border border-gray-200'
            }`}>
              {sku.review.action === 'matched' ? <CheckCircle size={14} /> : <XCircle size={14} />}
              <span>
                {sku.review.action === 'matched'
                  ? `Matched to product id ${sku.review.applied_canonical_sku_id}`
                  : 'Skipped'}
                {' '}by {sku.review.reviewer} on {sku.review.reviewed_at?.slice(0,10)}
              </span>
              {sku.review.notes && <span className="italic text-xs">— {sku.review.notes}</span>}
            </div>
          )}

          {/* Top-3 fuzzy suggestions */}
          {sku.suggestions.length > 0 ? (
            <div>
              <div className="text-xs font-semibold text-gray-500 uppercase tracking-wide mb-2">
                Suggested Matches
              </div>
              <div className="space-y-2">
                {sku.suggestions.map((s, i) => (
                  <div key={s.canonical_sku_id} className="flex items-center gap-3 bg-white rounded-lg px-3 py-2 border border-gray-200">
                    <div className="flex-1 min-w-0">
                      <div className="font-medium text-sm text-gray-900 truncate">{s.canonical_sku_name}</div>
                      <div className="text-xs text-gray-400">
                        {s.range_name ?? ''}
                        {s.range_group ? ` · ${s.range_group}` : ''}
                      </div>
                    </div>
                    <div className="flex items-center gap-2 shrink-0">
                      <div className="w-20 h-2 bg-gray-200 rounded-full overflow-hidden">
                        <div
                          className={`h-full rounded-full ${scoreColor(s.similarity)}`}
                          style={{ width: scoreBarWidth(s.similarity) }}
                        />
                      </div>
                      <span className="text-xs text-gray-500 w-10 text-right">{s.similarity.toFixed(0)}%</span>
                      {!isReviewed && (
                        <button
                          disabled={applying}
                          onClick={async () => {
                            setApplying(true);
                            try {
                              await onMatch(
                                sku.sku_id,
                                s.canonical_sku_id,
                                sku.suggestions[0]?.canonical_sku_id ?? null,
                                s.similarity,
                                bucket,
                                notes
                              );
                            } finally {
                              setApplying(false);
                            }
                          }}
                          className="px-3 py-1 rounded-lg text-xs font-medium bg-blue-600 text-white hover:bg-blue-700 disabled:opacity-50 transition-colors"
                        >
                          {i === 0 ? 'Approve' : 'Use this'}
                        </button>
                      )}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          ) : (
            <div className="text-sm text-gray-500 italic flex items-center gap-2">
              <AlertTriangle size={14} className="text-amber-400" />
              No automatic suggestions — use manual search below
            </div>
          )}

          {/* Manual canonical_sku search (existing only — JC-108) */}
          {!isReviewed && (
            <div>
              <div className="text-xs font-semibold text-gray-500 uppercase tracking-wide mb-2">
                Manual Search (existing products only)
              </div>
              <div className="space-y-2">
                <CanonicalSkuTypeahead
                  onSelect={c => setPendingCanonical(c)}
                  placeholder="Search products by name…"
                />
                {pendingCanonical && (
                  <div className="flex items-center gap-3 bg-blue-50 rounded-lg px-3 py-2 border border-blue-200">
                    <div className="flex-1 min-w-0">
                      <div className="font-medium text-sm text-blue-900 truncate">{pendingCanonical.sku_name}</div>
                      <div className="text-xs text-blue-400">
                        {pendingCanonical.range_name ?? ''}
                        {pendingCanonical.range_group ? ` · ${pendingCanonical.range_group}` : ''}
                      </div>
                    </div>
                    <button
                      disabled={applying}
                      onClick={async () => {
                        setApplying(true);
                        try {
                          await onMatch(
                            sku.sku_id,
                            pendingCanonical.id,
                            sku.suggestions[0]?.canonical_sku_id ?? null,
                            null,
                            'MANUAL',
                            notes
                          );
                          setPendingCanonical(null);
                        } finally {
                          setApplying(false);
                        }
                      }}
                      className="px-3 py-1 rounded-lg text-xs font-medium bg-blue-600 text-white hover:bg-blue-700 disabled:opacity-50 transition-colors"
                    >
                      Apply Match
                    </button>
                    <button
                      onClick={() => setPendingCanonical(null)}
                      className="text-gray-400 hover:text-gray-600"
                    >
                      <XCircle size={14} />
                    </button>
                  </div>
                )}
              </div>
              <div className="text-[11px] text-gray-400 mt-1">
                Free-form create disabled. New products are added via the data import pipeline.
              </div>
            </div>
          )}

          {/* Notes + Skip */}
          {!isReviewed && (
            <div className="flex items-end gap-3">
              <div className="flex-1">
                <label className="text-xs font-semibold text-gray-500 uppercase tracking-wide block mb-1">
                  Notes (optional)
                </label>
                <input
                  type="text"
                  className="w-full border border-gray-200 rounded-lg px-3 py-1.5 text-sm text-gray-800 placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500"
                  placeholder="e.g. New vintage of an existing canonical, ALM rename"
                  value={notes}
                  onChange={e => setNotes(e.target.value)}
                />
              </div>
              <button
                disabled={applying}
                onClick={async () => {
                  setApplying(true);
                  try {
                    await onSkip(sku.sku_id, notes);
                  } finally {
                    setApplying(false);
                  }
                }}
                className="px-3 py-1.5 rounded-lg text-xs font-medium border border-gray-200 text-gray-600 hover:bg-gray-100 disabled:opacity-50 transition-colors"
              >
                Skip for now
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// ─── Page ───────────────────────────────────────────────────────────────────

export default function UnmatchedSkusPage() {
  const [skus, setSkus] = useState<UnmatchedSku[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<'all' | 'pending' | 'reviewed'>('all');
  const [toast, setToast] = useState<{ msg: string; type: 'ok' | 'err' } | null>(null);

  const loadSkus = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await apiGet('/api/admin/unmatched-skus');
      if (!res.ok) {
        const err = await res.json().catch(() => ({ error: res.statusText }));
        throw new Error(err.error || 'Failed to load');
      }
      const data = await res.json();
      setSkus(data.rows ?? []);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { loadSkus(); }, [loadSkus]);

  const showToast = (msg: string, type: 'ok' | 'err') => {
    setToast({ msg, type });
    setTimeout(() => setToast(null), 3000);
  };

  const handleMatch = useCallback(async (
    skuId: number,
    canonicalId: number,
    suggestedId: number | null,
    score: number | null,
    bucket: string,
    notes: string
  ) => {
    try {
      const res = await apiPost(`/api/admin/unmatched-skus/${skuId}/match`, {
        canonical_sku_id: canonicalId,
        suggested_canonical_sku_id: suggestedId,
        score,
        bucket,
        notes: notes || undefined,
      });
      if (!res.ok) {
        const err = await res.json().catch(() => ({ error: res.statusText }));
        throw new Error(err.error || 'Match failed');
      }
      showToast(`SKU ${skuId} matched to product ${canonicalId}`, 'ok');
      await loadSkus();
    } catch (e) {
      showToast((e as Error).message, 'err');
    }
  }, [loadSkus]);

  const handleSkip = useCallback(async (skuId: number, notes: string) => {
    try {
      const res = await apiPost(`/api/admin/unmatched-skus/${skuId}/skip`, {
        notes: notes || undefined,
      });
      if (!res.ok) {
        const err = await res.json().catch(() => ({ error: res.statusText }));
        throw new Error(err.error || 'Skip failed');
      }
      showToast(`SKU ${skuId} marked skipped`, 'ok');
      await loadSkus();
    } catch (e) {
      showToast((e as Error).message, 'err');
    }
  }, [loadSkus]);

  const filtered = skus.filter(s => {
    if (filter === 'pending') return s.review_status === 'pending';
    if (filter === 'reviewed') return s.review_status === 'matched' || s.review_status === 'skipped';
    return true;
  });

  const totalRev = skus.reduce((acc, s) => acc + parseFloat(s.revenue_aud), 0);
  const pendingCount = skus.filter(s => s.review_status === 'pending').length;
  const matchedCount = skus.filter(s => s.review_status === 'matched').length;
  const skippedCount = skus.filter(s => s.review_status === 'skipped').length;

  return (
    <AppLayout title="Unmatched SKUs" subtitle="Match unmatched SKUs to existing products">
      {toast && (
        <div
          className={`fixed top-4 right-4 z-50 flex items-center gap-2 px-4 py-2 rounded-lg shadow-lg text-sm font-medium transition-all ${
            toast.type === 'ok' ? 'bg-green-600 text-white' : 'bg-red-600 text-white'
          }`}
        >
          {toast.type === 'ok' ? <CheckCircle size={14} /> : <XCircle size={14} />}
          {toast.msg}
        </div>
      )}

      {/* Stats bar */}
      <div className="grid grid-cols-4 gap-4 mb-6">
        {[
          { label: 'Total Unmatched', value: skus.length, icon: <Package size={16} />, color: 'text-gray-700' },
          { label: 'Pending Review', value: pendingCount, icon: <AlertTriangle size={16} />, color: 'text-amber-600' },
          { label: 'Matched', value: matchedCount, icon: <CheckCircle size={16} />, color: 'text-green-600' },
          { label: 'Revenue at Stake', value: formatRevenue(totalRev), icon: <DollarSign size={16} />, color: 'text-blue-600' },
        ].map(s => (
          <div key={s.label} className="bg-white rounded-xl border border-gray-200 p-4">
            <div className={`flex items-center gap-2 text-sm font-medium mb-1 ${s.color}`}>
              {s.icon}
              {s.label}
            </div>
            <div className="text-2xl font-bold text-gray-900">{s.value}</div>
          </div>
        ))}
      </div>

      <div className="flex items-center justify-between mb-4">
        <div className="flex gap-2">
          {(['all', 'pending', 'reviewed'] as const).map(f => (
            <button
              key={f}
              onClick={() => setFilter(f)}
              className={`px-4 py-1.5 rounded-lg text-sm font-medium transition-colors ${
                filter === f
                  ? 'bg-gray-900 text-white'
                  : 'bg-white border border-gray-200 text-gray-600 hover:bg-gray-50'
              }`}
            >
              {f === 'all' ? 'All' : f === 'pending' ? `Pending (${pendingCount})` : `Reviewed (${matchedCount + skippedCount})`}
            </button>
          ))}
        </div>
        <button
          onClick={loadSkus}
          disabled={loading}
          className="flex items-center gap-2 px-3 py-1.5 rounded-lg text-sm border border-gray-200 text-gray-600 hover:bg-gray-50 disabled:opacity-50"
        >
          <RefreshCw size={14} className={loading ? 'animate-spin' : ''} />
          Refresh
        </button>
      </div>

      {loading && skus.length === 0 && (
        <div className="text-center py-12 text-gray-400">
          <RefreshCw size={24} className="animate-spin mx-auto mb-2" />
          Loading unmatched SKUs…
        </div>
      )}

      {error && (
        <div className="bg-red-50 border border-red-200 rounded-xl p-4 text-red-700 text-sm flex items-center gap-2">
          <XCircle size={16} />
          {error}
        </div>
      )}

      {!error && !loading && filtered.length === 0 && (
        <div className="text-center py-12 text-gray-400">
          {filter === 'pending' ? 'All SKUs have been reviewed!' : 'No SKUs found.'}
        </div>
      )}

      {!error && filtered.map(s => (
        <SkuRow
          key={s.sku_id}
          sku={s}
          onMatch={handleMatch}
          onSkip={handleSkip}
        />
      ))}

      {!loading && !error && (
        <div className="mt-6 bg-gray-50 rounded-xl border border-gray-100 p-4">
          <div className="text-xs font-semibold text-gray-500 uppercase tracking-wide mb-3">Bucket Legend</div>
          <div className="flex flex-wrap gap-4 text-xs text-gray-600">
            <div className="flex items-center gap-1.5">
              <span className="w-2 h-2 rounded-full bg-green-500 inline-block" />
              HIGH — Score ≥ 90, gap to #2 ≥ 10. Safe to auto-apply.
            </div>
            <div className="flex items-center gap-1.5">
              <span className="w-2 h-2 rounded-full bg-yellow-400 inline-block" />
              REVIEW — Score in [70, 90) or top-2 close. Needs human judgment.
            </div>
            <div className="flex items-center gap-1.5">
              <span className="w-2 h-2 rounded-full bg-red-400 inline-block" />
              NO MATCH — Score &lt; 70. Likely brand-new product. Defer to next data import.
            </div>
          </div>
        </div>
      )}
    </AppLayout>
  );
}
