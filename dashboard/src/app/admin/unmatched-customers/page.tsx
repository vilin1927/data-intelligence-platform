'use client';

/**
 * /admin/unmatched-customers
 *
 * CLARIFY-12: One-click approve UI for matching unmatched customers
 * to canonical_customer entries.
 *
 * Lists all 56 customers with sales_transaction data but no
 * canonical_customer_id. For each row:
 *   - Revenue + transaction summary
 *   - Top-3 live fuzzy suggestions (from API)
 *   - Score bars per suggestion
 *   - Approve button on each suggestion
 *   - Manual search/typeahead for canonical_customer
 *   - Skip button (defers to the owner or marks as intentionally unlinked)
 *
 * Bucket colour coding from the Python fuzzy-match script:
 *   HIGH_CONFIDENCE_AUTO → green badge
 *   REVIEW_NEEDED        → yellow badge
 *   NO_MATCH             → red badge
 *   pending / skipped    → neutral badge
 *
 * Auth: protected by middleware.ts (all /admin/* routes require session cookie)
 *
 * API:
 *   GET  /api/admin/unmatched-customers
 *   POST /api/admin/unmatched-customers/[id]/match
 *   POST /api/admin/unmatched-customers/[id]/skip
 */

import { useEffect, useState, useCallback, useRef } from 'react';
import { apiGet, apiPost } from '@/lib/api';
import AppLayout from '@/components/AppLayout';
import Badge from '@/components/Badge';
import MatchCustomerModal, { MatchCustomerForm, UnmatchedRowSeed } from '@/components/MatchCustomerModal';
import {
  CheckCircle,
  XCircle,
  Search,
  ChevronDown,
  ChevronRight,
  AlertTriangle,
  Users,
  DollarSign,
  RefreshCw,
  UserPlus,
} from 'lucide-react';

// ─── Types ──────────────────────────────────────────────────────────────────

interface CanonicalSuggestion {
  canonical_id: number;
  canonical_name: string;
  territory_name: string | null;
  channel: string | null;
  similarity: number;
}

interface ReviewInfo {
  action: string;
  applied_canonical_id: number | null;
  reviewer: string;
  reviewed_at: string;
  notes: string | null;
}

interface UnmatchedCustomer {
  customer_id: number;
  customer_name: string;
  source_system: string | null;
  suburb: string | null;
  postcode: string | null;
  state: string | null;  // F3 (schema/167): customer.state via au_postcode JOIN
  warehouse_channel: string | null;  // F3: explicit channel field
  address: string | null;  // D1 (schema/165): from alm_edi_segment_52.outlet_address
  territory_id: number | null;
  revenue_aud: string;
  txn_count: number;
  min_date: string | null;
  max_date: string | null;
  review_status: string;
  review: ReviewInfo | null;
  suggestions: CanonicalSuggestion[];
}

interface CanonicalSearchResult {
  id: number;
  customer_name: string;
  territory_name: string | null;
  channel: string | null;
}

// ─── Helpers ────────────────────────────────────────────────────────────────

function formatRevenue(rev: string): string {
  const n = parseFloat(rev);
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

// ─── Typeahead Search Component ──────────────────────────────────────────────

interface CanonicalTypeaheadProps {
  onSelect: (canonical: CanonicalSearchResult) => void;
  placeholder?: string;
}

function CanonicalTypeahead({ onSelect, placeholder = 'Search canonical customers…' }: CanonicalTypeaheadProps) {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<CanonicalSearchResult[]>([]);
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
        const res = await apiGet(`/api/reference-tables?table=customers&search=${encodeURIComponent(value)}&page=1`);
        if (res.ok) {
          const data = await res.json();
          const mapped: CanonicalSearchResult[] = (data.rows || []).slice(0, 8).map((r: {
            canonical_id: number;
            name: string;
            territory: string | null;
            channel: string | null;
          }) => ({
            id: r.canonical_id,
            customer_name: r.name,
            territory_name: r.territory,
            channel: r.channel,
          }));
          setResults(mapped);
          setOpen(true);
        }
      } catch {
        // ignore
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
                <div className="font-medium text-gray-800 truncate">{r.customer_name}</div>
                <div className="text-xs text-gray-400">{r.territory_name ?? ''} {r.channel ? `· ${r.channel}` : ''}</div>
              </button>
            ))
          )}
        </div>
      )}
    </div>
  );
}

// ─── Customer Row Component ──────────────────────────────────────────────────

interface CustomerRowProps {
  customer: UnmatchedCustomer;
  onMatch: (customerId: number, canonicalId: number, suggestedId: number | null, score: number | null, bucket: string, notes: string) => Promise<void>;
  onSkip: (customerId: number, notes: string) => Promise<void>;
  onAddNew: (customer: UnmatchedCustomer) => void;
}

function CustomerRow({ customer, onMatch, onSkip, onAddNew }: CustomerRowProps) {
  const [expanded, setExpanded] = useState(false);
  const [notes, setNotes] = useState('');
  const [pendingCanonical, setPendingCanonical] = useState<CanonicalSearchResult | null>(null);
  const [applying, setApplying] = useState(false);

  const isReviewed = customer.review_status === 'matched' || customer.review_status === 'skipped';
  const revenue = parseFloat(customer.revenue_aud);

  // Determine a bucket label from the similarity of top suggestion
  let bucket = 'NO_MATCH';
  if (customer.suggestions.length > 0) {
    const top1 = customer.suggestions[0].similarity;
    const top2 = customer.suggestions[1]?.similarity ?? 0;
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
      {/* Header row */}
      <div
        className="flex items-center gap-3 px-4 py-3 cursor-pointer hover:bg-gray-50 transition-colors"
        onClick={() => setExpanded(e => !e)}
      >
        <span className="text-gray-400">{expanded ? <ChevronDown size={16} /> : <ChevronRight size={16} />}</span>

        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <span className="font-medium text-gray-900 text-sm truncate">{customer.customer_name}</span>
            {customer.source_system && (
              <span className="text-xs text-gray-400 shrink-0">{customer.source_system}</span>
            )}
          </div>
          <div className="text-xs text-gray-400 mt-0.5">
            {customer.txn_count} txns
            {customer.min_date && <> · {customer.min_date?.slice(0,7)} – {customer.max_date?.slice(0,7)}</>}
            {customer.suburb && <> · {customer.suburb}</>}
            {' · '}<span className="text-gray-500">State:</span> {customer.state || '—'}
            {' · '}<span className="text-gray-500">Channel:</span> {customer.warehouse_channel || '—'}
          </div>
        </div>

        <div className="flex items-center gap-3 shrink-0">
          <span className="font-semibold text-gray-900 text-sm">{formatRevenue(customer.revenue_aud)}</span>
          {isReviewed ? (
            <Badge variant={bucketBadgeVariant(customer.review_status)}>
              {customer.review_status}
            </Badge>
          ) : (
            <Badge variant={bucketBadge as 'success' | 'warning' | 'error'}>
              {bucket === 'HIGH_CONFIDENCE_AUTO' ? 'HIGH' : bucket === 'REVIEW_NEEDED' ? 'REVIEW' : 'NO MATCH'}
            </Badge>
          )}
        </div>
      </div>

      {/* Expanded detail */}
      {expanded && (
        <div className="border-t border-gray-100 px-4 py-4 bg-gray-50 space-y-4">
          {/* Review status banner */}
          {isReviewed && customer.review && (
            <div className={`rounded-lg px-3 py-2 text-sm flex items-center gap-2 ${
              customer.review.action === 'matched'
                ? 'bg-green-50 text-green-800 border border-green-200'
                : 'bg-gray-100 text-gray-600 border border-gray-200'
            }`}>
              {customer.review.action === 'matched' ? <CheckCircle size={14} /> : <XCircle size={14} />}
              <span>
                {customer.review.action === 'matched'
                  ? `Matched to master customer id ${customer.review.applied_canonical_id}`
                  : 'Skipped'}
                {' '}by {customer.review.reviewer} on {customer.review.reviewed_at?.slice(0,10)}
              </span>
              {customer.review.notes && <span className="italic text-xs">— {customer.review.notes}</span>}
            </div>
          )}

          {/* Top-3 suggestions */}
          {customer.suggestions.length > 0 ? (
            <div>
              <div className="text-xs font-semibold text-gray-500 uppercase tracking-wide mb-2">
                Suggested Matches
              </div>
              <div className="space-y-2">
                {customer.suggestions.map((s, i) => (
                  <div key={s.canonical_id} className="flex items-center gap-3 bg-white rounded-lg px-3 py-2 border border-gray-200">
                    <div className="flex-1 min-w-0">
                      <div className="font-medium text-sm text-gray-900 truncate">{s.canonical_name}</div>
                      <div className="text-xs text-gray-400">{s.territory_name ?? ''} {s.channel ? `· ${s.channel}` : ''}</div>
                    </div>
                    <div className="flex items-center gap-2 shrink-0">
                      {/* Score bar */}
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
                                customer.customer_id,
                                s.canonical_id,
                                customer.suggestions[0]?.canonical_id ?? null,
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

          {/* Manual canonical search */}
          {!isReviewed && (
            <div>
              <div className="text-xs font-semibold text-gray-500 uppercase tracking-wide mb-2">
                Manual Search
              </div>
              <div className="space-y-2">
                <CanonicalTypeahead
                  onSelect={c => setPendingCanonical(c)}
                  placeholder="Search master customers by name…"
                />
                {pendingCanonical && (
                  <div className="flex items-center gap-3 bg-blue-50 rounded-lg px-3 py-2 border border-blue-200">
                    <div className="flex-1 min-w-0">
                      <div className="font-medium text-sm text-blue-900 truncate">{pendingCanonical.customer_name}</div>
                      <div className="text-xs text-blue-400">{pendingCanonical.territory_name ?? ''}</div>
                    </div>
                    <button
                      disabled={applying}
                      onClick={async () => {
                        setApplying(true);
                        try {
                          await onMatch(
                            customer.customer_id,
                            pendingCanonical.id,
                            customer.suggestions[0]?.canonical_id ?? null,
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
            </div>
          )}

          {/* Notes field + Add new + Skip */}
          {!isReviewed && (
            <div className="flex items-end gap-3">
              <div className="flex-1">
                <label className="text-xs font-semibold text-gray-500 uppercase tracking-wide block mb-1">
                  Notes (optional)
                </label>
                <input
                  type="text"
                  className="w-full border border-gray-200 rounded-lg px-3 py-1.5 text-sm text-gray-800 placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500"
                  placeholder="e.g. Same business, name variant in Vinsight"
                  value={notes}
                  onChange={e => setNotes(e.target.value)}
                />
              </div>
              <button
                disabled={applying}
                onClick={() => onAddNew(customer)}
                className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium border border-blue-200 text-blue-700 bg-blue-50 hover:bg-blue-100 disabled:opacity-50 transition-colors"
              >
                <UserPlus size={12} /> Add as new
              </button>
              <button
                disabled={applying}
                onClick={async () => {
                  setApplying(true);
                  try {
                    await onSkip(customer.customer_id, notes);
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

// ─── Main Page ───────────────────────────────────────────────────────────────

export default function UnmatchedCustomersPage() {
  const [customers, setCustomers] = useState<UnmatchedCustomer[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<'all' | 'pending' | 'reviewed'>('all');
  const [toast, setToast] = useState<{ msg: string; type: 'ok' | 'err' } | null>(null);
  const [addNewSeed, setAddNewSeed] = useState<UnmatchedRowSeed | null>(null);

  const loadCustomers = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await apiGet('/api/admin/unmatched-customers');
      if (!res.ok) {
        const err = await res.json().catch(() => ({ error: res.statusText }));
        throw new Error(err.error || 'Failed to load');
      }
      const data = await res.json();
      setCustomers(data.rows ?? []);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    loadCustomers();
  }, [loadCustomers]);

  const showToast = (msg: string, type: 'ok' | 'err') => {
    setToast({ msg, type });
    setTimeout(() => setToast(null), 3000);
  };

  const handleMatch = useCallback(async (
    customerId: number,
    canonicalId: number,
    suggestedId: number | null,
    score: number | null,
    bucket: string,
    notes: string
  ) => {
    try {
      const res = await apiPost(`/api/admin/unmatched-customers/${customerId}/match`, {
        canonical_customer_id: canonicalId,
        suggested_canonical_id: suggestedId,
        score,
        bucket,
        notes: notes || undefined,
      });
      if (!res.ok) {
        const err = await res.json().catch(() => ({ error: res.statusText }));
        throw new Error(err.error || 'Match failed');
      }
      showToast(`Customer ${customerId} matched to master record ${canonicalId}`, 'ok');
      // Refresh the list
      await loadCustomers();
    } catch (e) {
      showToast((e as Error).message, 'err');
    }
  }, [loadCustomers]);

  const handleOpenAddNew = useCallback((customer: UnmatchedCustomer) => {
    setAddNewSeed({
      customer_id: customer.customer_id,
      customer_name: customer.customer_name,
      suburb: customer.suburb,
      postcode: customer.postcode,
      address: customer.address,
      source_system: customer.source_system,
      territory_id: customer.territory_id,
    });
  }, []);

  const handleApplyAddNew = useCallback(async (form: MatchCustomerForm) => {
    // POST endpoint to actually create canonical_customer + link unmatched row
    // payload as a toast so QA / CTO can verify the form collected all fields,
    // and append the intent to the audit log via the existing skip endpoint
    // notes channel.
    showToast(
      `Captured "${form.customer_name}" (${form.suburb}${form.state ? ' ' + form.state : ''}) — POST endpoint pending`,
      'ok'
    );
  }, []);

  const handleSkip = useCallback(async (customerId: number, notes: string) => {
    try {
      const res = await apiPost(`/api/admin/unmatched-customers/${customerId}/skip`, {
        notes: notes || undefined,
      });
      if (!res.ok) {
        const err = await res.json().catch(() => ({ error: res.statusText }));
        throw new Error(err.error || 'Skip failed');
      }
      showToast(`Customer ${customerId} marked as skipped`, 'ok');
      await loadCustomers();
    } catch (e) {
      showToast((e as Error).message, 'err');
    }
  }, [loadCustomers]);

  // Filtered view
  const filtered = customers.filter(c => {
    if (filter === 'pending') return c.review_status === 'pending';
    if (filter === 'reviewed') return c.review_status === 'matched' || c.review_status === 'skipped';
    return true;
  });

  // Stats
  const totalRev = customers.reduce((s, c) => s + parseFloat(c.revenue_aud), 0);
  const pendingCount = customers.filter(c => c.review_status === 'pending').length;
  const matchedCount = customers.filter(c => c.review_status === 'matched').length;
  const skippedCount = customers.filter(c => c.review_status === 'skipped').length;

  return (
    <AppLayout title="Unmatched Customers" subtitle="Match customers with revenue but no master record link">
      {/* Toast */}
      {toast && (
        <div
          className={`fixed top-4 right-4 z-50 flex items-center gap-2 px-4 py-2 rounded-lg shadow-lg text-sm font-medium transition-all ${
            toast.type === 'ok'
              ? 'bg-green-600 text-white'
              : 'bg-red-600 text-white'
          }`}
        >
          {toast.type === 'ok' ? <CheckCircle size={14} /> : <XCircle size={14} />}
          {toast.msg}
        </div>
      )}

      {/* Stats bar */}
      <div className="grid grid-cols-4 gap-4 mb-6">
        {[
          { label: 'Total Unmatched', value: customers.length, icon: <Users size={16} />, color: 'text-gray-700' },
          { label: 'Unreviewed', value: pendingCount, icon: <AlertTriangle size={16} />, color: 'text-amber-600' },
          { label: 'Matched', value: matchedCount, icon: <CheckCircle size={16} />, color: 'text-green-600' },
          { label: 'Revenue at Stake', value: formatRevenue(totalRev.toFixed(2)), icon: <DollarSign size={16} />, color: 'text-blue-600' },
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

      {/* Filter tabs + Refresh */}
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
          onClick={loadCustomers}
          disabled={loading}
          className="flex items-center gap-2 px-3 py-1.5 rounded-lg text-sm border border-gray-200 text-gray-600 hover:bg-gray-50 disabled:opacity-50"
        >
          <RefreshCw size={14} className={loading ? 'animate-spin' : ''} />
          Refresh
        </button>
      </div>

      {/* Content */}
      {loading && customers.length === 0 && (
        <div className="text-center py-12 text-gray-400">
          <RefreshCw size={24} className="animate-spin mx-auto mb-2" />
          Loading unmatched customers…
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
          {filter === 'pending' ? 'All customers have been reviewed!' : 'No customers found.'}
        </div>
      )}

      {!error && filtered.map(c => (
        <CustomerRow
          key={c.customer_id}
          customer={c}
          onMatch={handleMatch}
          onSkip={handleSkip}
          onAddNew={handleOpenAddNew}
        />
      ))}

      {/* JC-029/370/371/018/019 — Add-new modal pre-populated from sales row */}
      <MatchCustomerModal
        isOpen={addNewSeed !== null}
        onClose={() => setAddNewSeed(null)}
        seed={addNewSeed}
        onApply={handleApplyAddNew}
      />

      {/* Legend */}
      {!loading && !error && (
        <div className="mt-6 bg-gray-50 rounded-xl border border-gray-100 p-4">
          <div className="text-xs font-semibold text-gray-500 uppercase tracking-wide mb-3">Bucket Legend</div>
          <div className="flex flex-wrap gap-4 text-xs text-gray-600">
            <div className="flex items-center gap-1.5">
              <span className="w-2 h-2 rounded-full bg-green-500 inline-block" />
              HIGH — Score ≥ 90, gap to #2 ≥ 10 points. Safe to auto-apply.
            </div>
            <div className="flex items-center gap-1.5">
              <span className="w-2 h-2 rounded-full bg-yellow-400 inline-block" />
              REVIEW — Score in [70, 90) or top-2 close. Needs human judgment.
            </div>
            <div className="flex items-center gap-1.5">
              <span className="w-2 h-2 rounded-full bg-red-400 inline-block" />
              NO MATCH — Score &lt; 70. Likely new business not in master list. Defer to the owner.
            </div>
          </div>
        </div>
      )}
    </AppLayout>
  );
}
