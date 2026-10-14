'use client';

/**
 * SkuMatchModal
 *
 * B6b — JC-108 / JC-120: a reusable modal for linking an unmatched SKU to
 * an EXISTING canonical_sku. Used by:
 *   - Reference Tables → SKU tab (when a row is missing canonical_sku_id)
 *   - Import preview / upload flows (when a new external code arrives)
 *   - Anywhere we need a one-click match without leaving the current page.
 *
 * JC-108 explicit: NO free-form create. The modal lists existing canonicals
 * (top-3 fuzzy via /api/admin/unmatched-skus, plus a typeahead search) and
 * Approve/Skip. Brand-new canonicals come exclusively from the accdb
 * pipeline (etl/import_sku_from_access_first.py).
 */

import { useEffect, useState, useCallback, useRef } from 'react';
import { Search, RefreshCw, CheckCircle, XCircle, AlertTriangle } from 'lucide-react';
import { apiGet, apiPost } from '@/lib/api';
import Modal from './Modal';
import Button from './Button';

interface CanonicalSkuOption {
  id: number;
  sku_name: string;
  range_name: string | null;
  range_group: string | null;
  similarity?: number;
}

interface SkuMatchModalProps {
  isOpen: boolean;
  onClose: () => void;
  /** sku.sku_id of the unmatched row */
  skuId: number;
  /** sku.sku_code — shown as the title context */
  skuCode: string;
  /** sku.item_description — used to seed the search */
  itemDescription: string;
  /** Top-3 fuzzy suggestions (passed in by caller; otherwise modal fetches /api/admin/unmatched-skus row inline) */
  initialSuggestions?: CanonicalSkuOption[];
  /** Called after a successful match. Caller refreshes its row list. */
  onMatched?: (canonicalSkuId: number) => void;
}

function scoreColor(score: number): string {
  if (score >= 90) return 'bg-green-500';
  if (score >= 70) return 'bg-yellow-400';
  return 'bg-red-400';
}

export default function SkuMatchModal({
  isOpen,
  onClose,
  skuId,
  skuCode,
  itemDescription,
  initialSuggestions,
  onMatched,
}: SkuMatchModalProps) {
  const [suggestions, setSuggestions] = useState<CanonicalSkuOption[]>(initialSuggestions ?? []);
  const [query, setQuery] = useState('');
  const [searchResults, setSearchResults] = useState<CanonicalSkuOption[]>([]);
  const [searching, setSearching] = useState(false);
  const [selected, setSelected] = useState<CanonicalSkuOption | null>(null);
  const [notes, setNotes] = useState('');
  const [applying, setApplying] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const debounceRef = useRef<ReturnType<typeof setTimeout>>();

  // Reset state on open / new skuId
  useEffect(() => {
    if (!isOpen) return;
    setSuggestions(initialSuggestions ?? []);
    setQuery('');
    setSearchResults([]);
    setSelected(null);
    setNotes('');
    setError(null);

    // Lazy-fetch suggestions if caller didn't provide them.
    if (!initialSuggestions || initialSuggestions.length === 0) {
      apiGet('/api/admin/unmatched-skus')
        .then(r => r.ok ? r.json() : { rows: [] })
        .then((data: { rows: Array<{ sku_id: number; suggestions: Array<{ canonical_sku_id: number; canonical_sku_name: string; range_name: string | null; range_group: string | null; similarity: number }> }> }) => {
          const row = (data.rows || []).find(r => r.sku_id === skuId);
          if (row) {
            setSuggestions(row.suggestions.map(s => ({
              id: s.canonical_sku_id,
              sku_name: s.canonical_sku_name,
              range_name: s.range_name,
              range_group: s.range_group,
              similarity: s.similarity,
            })));
          }
        })
        .catch(() => { /* best-effort */ });
    }
  }, [isOpen, skuId, initialSuggestions]);

  const handleSearch = useCallback((value: string) => {
    setQuery(value);
    if (debounceRef.current) clearTimeout(debounceRef.current);
    if (value.length < 2) {
      setSearchResults([]);
      return;
    }
    debounceRef.current = setTimeout(async () => {
      setSearching(true);
      try {
        const res = await apiGet(`/api/reference-tables?table=canonical_sku&search=${encodeURIComponent(value)}&page=1`);
        if (res.ok) {
          const data = await res.json();
          setSearchResults((data.rows || []).slice(0, 8).map((r: {
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
          })));
        }
      } catch {
        // ignore
      } finally {
        setSearching(false);
      }
    }, 300);
  }, []);

  const handleApply = async () => {
    if (!selected) return;
    setApplying(true);
    setError(null);
    try {
      const topSuggestion = suggestions[0]?.id ?? null;
      const res = await apiPost(`/api/admin/unmatched-skus/${skuId}/match`, {
        canonical_sku_id: selected.id,
        suggested_canonical_sku_id: topSuggestion,
        score: selected.similarity ?? null,
        bucket: selected.similarity != null ? (selected.similarity >= 90 ? 'HIGH_CONFIDENCE_AUTO' : selected.similarity >= 70 ? 'REVIEW_NEEDED' : 'NO_MATCH') : 'MANUAL',
        notes: notes || undefined,
      });
      if (!res.ok) {
        const err = await res.json().catch(() => ({ error: res.statusText }));
        throw new Error(err.error || 'Match failed');
      }
      if (onMatched) onMatched(selected.id);
      onClose();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setApplying(false);
    }
  };

  const handleSkip = async () => {
    setApplying(true);
    setError(null);
    try {
      const res = await apiPost(`/api/admin/unmatched-skus/${skuId}/skip`, {
        notes: notes || undefined,
      });
      if (!res.ok) {
        const err = await res.json().catch(() => ({ error: res.statusText }));
        throw new Error(err.error || 'Skip failed');
      }
      onClose();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setApplying(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={`Match SKU ${skuCode}`}
      size="lg"
      footer={
        <>
          <Button variant="ghost" onClick={handleSkip} disabled={applying}>
            Skip (defer)
          </Button>
          <Button variant="primary" onClick={handleApply} disabled={!selected || applying} loading={applying}>
            Apply Match
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        {/* Source SKU card */}
        <div className="bg-[#FAF9F7] rounded-lg px-3 py-2 border border-[#D8D9DA]">
          <div className="flex items-center gap-2">
            <span className="font-mono text-xs bg-white border border-[#D8D9DA] px-1.5 py-0.5 rounded text-[#505052]">{skuCode}</span>
            <span className="text-sm font-medium text-[#1F1F1F]">{itemDescription}</span>
          </div>
          <div className="text-[11px] text-[#505052] mt-1">
            Select an existing canonical SKU. New canonical SKUs are created by the import process, not added here.
          </div>
        </div>

        {/* Top suggestions */}
        {suggestions.length > 0 && (
          <div>
            <div className="text-xs font-semibold text-[#505052] uppercase tracking-wide mb-2">
              Suggested Matches
            </div>
            <div className="space-y-1">
              {suggestions.map(s => {
                const isSelected = selected?.id === s.id;
                return (
                  <button
                    key={s.id}
                    onClick={() => setSelected(s)}
                    className={`w-full text-left flex items-center gap-3 rounded-lg px-3 py-2 border transition-colors ${
                      isSelected ? 'bg-blue-50 border-blue-300 ring-2 ring-blue-200' : 'bg-white border-[#D8D9DA] hover:bg-[#FAF9F7]'
                    }`}
                  >
                    <div className="flex-1 min-w-0">
                      <div className="font-medium text-sm text-[#1F1F1F] truncate">{s.sku_name}</div>
                      <div className="text-xs text-[#505052]">
                        {s.range_name ?? ''}{s.range_group ? ` · ${s.range_group}` : ''}
                      </div>
                    </div>
                    {s.similarity !== undefined && (
                      <div className="flex items-center gap-2">
                        <div className="w-20 h-2 bg-gray-200 rounded-full overflow-hidden">
                          <div
                            className={`h-full rounded-full ${scoreColor(s.similarity)}`}
                            style={{ width: `${Math.min(100, Math.max(0, s.similarity))}%` }}
                          />
                        </div>
                        <span className="text-xs text-[#505052] w-10 text-right">{s.similarity.toFixed(0)}%</span>
                      </div>
                    )}
                  </button>
                );
              })}
            </div>
          </div>
        )}

        {suggestions.length === 0 && (
          <div className="flex items-center gap-2 text-xs text-[#505052] italic">
            <AlertTriangle size={14} className="text-amber-500" />
            No automatic suggestions. Use search below.
          </div>
        )}

        {/* Manual search */}
        <div>
          <div className="text-xs font-semibold text-[#505052] uppercase tracking-wide mb-2">
            Search canonical SKUs
          </div>
          <div className="flex items-center gap-2 border border-[#D8D9DA] rounded-lg px-3 py-2 bg-white focus-within:ring-2 focus-within:ring-blue-500 focus-within:border-blue-500">
            <Search size={14} className="text-[#505052] shrink-0" />
            <input
              type="text"
              className="flex-1 text-sm outline-none text-[#1F1F1F] placeholder-[#505052]"
              placeholder="Type at least 2 characters…"
              value={query}
              onChange={e => handleSearch(e.target.value)}
            />
            {searching && <RefreshCw size={12} className="animate-spin text-[#505052]" />}
          </div>
          {searchResults.length > 0 && (
            <div className="mt-2 border border-[#D8D9DA] rounded-lg overflow-hidden divide-y divide-[#D8D9DA] bg-white">
              {searchResults.map(r => {
                const isSelected = selected?.id === r.id;
                return (
                  <button
                    key={r.id}
                    onClick={() => setSelected(r)}
                    className={`w-full text-left px-3 py-2 text-sm transition-colors ${
                      isSelected ? 'bg-blue-50 text-blue-900' : 'hover:bg-[#FAF9F7] text-[#1F1F1F]'
                    }`}
                  >
                    <div className="font-medium truncate">{r.sku_name}</div>
                    <div className="text-xs text-[#505052]">
                      {r.range_name ?? ''}{r.range_group ? ` · ${r.range_group}` : ''}
                    </div>
                  </button>
                );
              })}
            </div>
          )}
        </div>

        {/* Selected confirmation banner */}
        {selected && (
          <div className="flex items-center gap-2 bg-blue-50 border border-blue-200 text-blue-900 rounded-lg px-3 py-2 text-sm">
            <CheckCircle size={14} />
            <span className="flex-1 truncate"><strong>{selected.sku_name}</strong> selected</span>
            <button onClick={() => setSelected(null)} className="text-blue-400 hover:text-blue-700">
              <XCircle size={14} />
            </button>
          </div>
        )}

        {/* Notes */}
        <div>
          <label className="text-xs font-semibold text-[#505052] uppercase tracking-wide block mb-1">
            Notes (optional)
          </label>
          <input
            type="text"
            className="w-full border border-[#D8D9DA] rounded-lg px-3 py-1.5 text-sm text-[#1F1F1F] placeholder-[#505052]/60 focus:outline-none focus:ring-2 focus:ring-blue-500"
            placeholder="e.g. New vintage of an existing canonical"
            value={notes}
            onChange={e => setNotes(e.target.value)}
          />
        </div>

        {error && (
          <div className="bg-red-50 border border-red-200 rounded-lg px-3 py-2 text-red-700 text-sm flex items-center gap-2">
            <XCircle size={14} />
            {error}
          </div>
        )}
      </div>
    </Modal>
  );
}
