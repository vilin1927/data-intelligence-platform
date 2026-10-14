'use client';

// ---------------------------------------------------------------------------
// ImportPreviewOverrides
// ---------------------------------------------------------------------------
// BUG-22: DASH-07 split — owns the three "override" panels:
//   - Unmatched SKUs picker (Vinsight SKU search + fuzzy chips)
//   - Unmatched Customers picker (customer search + create-new button)
//   - Unmatched Reps panel (create-new-rep button)
//
// Pure move from ImportPreview.tsx, zero behaviour changes.
// ---------------------------------------------------------------------------

import { useMemo, useState } from 'react';
import {
  useImportPreviewContext,
  font,
  type UnmatchedSku,
  type UnmatchedCustomer,
  type UnmatchedRep,
} from './ImportPreviewContext';

export default function ImportPreviewOverrides() {
  return (
    <>
      <UnmatchedSkusPanel />
      <UnmatchedCustomersPanel />
      <UnmatchedRepsPanel />
    </>
  );
}

// ---------------------------------------------------------------------------
// Unmatched SKUs panel
// ---------------------------------------------------------------------------

function UnmatchedSkusPanel() {
  const { unmatched_skus, assignedSkuCount, data } = useImportPreviewContext();

  return (
    <div className={`rounded-xl border p-4 ${unmatched_skus.length > 0 ? 'border-amber-200 bg-amber-50' : 'border-green-200 bg-green-50'}`}>
      {unmatched_skus.length === 0 ? (
        <h3 className="text-xs font-semibold text-green-700" style={font}>
          ✓ All SKUs Matched
        </h3>
      ) : (
        <>
        <h3 className="text-xs font-semibold text-amber-800 mb-1" style={font}>
          Unmatched SKUs ({unmatched_skus.length})
          {assignedSkuCount > 0 && <span className="text-green-700 ml-2">— {assignedSkuCount} assigned</span>}
        </h3>
        {/* JF-26: Reframed copy — SKUs originate in Vinsight. Wizard can match but never create. */}
        <p className="text-[10px] text-amber-700/80 mb-3" style={font}>
          All SKUs originate in Vinsight. Pick the matching Vinsight SKU from the list — the wizard will
          remember your choice so the same external code auto-resolves next time.
        </p>
        {data.sku_list.length === 0 && (
          <div className="mb-3 rounded-lg border border-amber-300 bg-white p-3 text-[11px] text-amber-900" style={font}>
            <strong>No Vinsight SKUs loaded.</strong> Create the SKU in Vinsight first, then re-sync the
            Vinsight data before retrying this import.
          </div>
        )}
        <div className="space-y-2">
          {unmatched_skus.map((sku) => (
            <UnmatchedSkuRow key={sku.external_code} sku={sku} />
          ))}
        </div>
        </>
      )}
    </div>
  );
}

function UnmatchedSkuRow({ sku }: { sku: UnmatchedSku }) {
  const {
    data,
    skuAssignments,
    setSkuAssignments,
    skuSearch,
    setSkuSearch,
    skuPickerOpen,
    setSkuPickerOpen,
    getFilteredSkus,
    persistMatch,
  } = useImportPreviewContext();

  const search = skuSearch[sku.external_code] || '';
  const pickerOpen = skuPickerOpen[sku.external_code] || search.length >= 1;
  const assignedId = skuAssignments[sku.external_code];
  const filtered = useMemo(() => getFilteredSkus(search), [getFilteredSkus, search]);

  return (
    <div className="text-xs" style={font}>
      <div className="flex items-center gap-3">
        <div className="min-w-[180px]">
          <span className="text-[#1F1F1F] font-mono text-[11px]">{sku.external_code}</span>
          {sku.description && <span className="text-[#505052] ml-1 text-[10px] italic">{sku.description}</span>}
          <span className="text-[#505052] ml-2 text-[10px]">({sku.row_count} rows, ${sku.total_revenue.toFixed(0)})</span>
        </div>
        <span className="text-[#D8D9DA]">&rarr;</span>
        {assignedId ? (
          <div className="flex items-center gap-2">
            <span className="text-green-700 text-[11px]">
              {data.sku_list.find(s => s.sku_id === assignedId)?.description || `ID: ${assignedId}`}
            </span>
            <button onClick={() => { const next = { ...skuAssignments }; delete next[sku.external_code]; setSkuAssignments(next); }} className="text-[10px] text-[#505052] hover:text-[#931220]">&#x2715;</button>
          </div>
        ) : (
          <div className="flex items-center gap-2 flex-1 max-w-lg">
            <div className="relative flex-1">
              <input
                type="text"
                placeholder={data.sku_list.length === 0 ? 'No Vinsight SKUs available' : 'Match to Vinsight SKU — search code or description...'}
                disabled={data.sku_list.length === 0}
                value={search}
                onChange={(e) => setSkuSearch(prev => ({ ...prev, [sku.external_code]: e.target.value }))}
                onFocus={() => setSkuPickerOpen(prev => ({ ...prev, [sku.external_code]: true }))}
                onBlur={() => {
                  // Delay close so option click lands first.
                  setTimeout(() => setSkuPickerOpen(prev => ({ ...prev, [sku.external_code]: false })), 150);
                }}
                className="w-full bg-white border border-[#D8D9DA] rounded-lg px-3 py-1.5 text-[11px] text-[#1F1F1F] placeholder-[#505052]/50 focus:border-[#931220] focus:outline-none disabled:bg-[#F5F4F1] disabled:cursor-not-allowed"
                style={font}
              />
              {pickerOpen && data.sku_list.length > 0 && (
                <div className="absolute z-10 mt-1 w-full bg-white border border-[#D8D9DA] rounded-lg shadow-lg max-h-64 overflow-y-auto">
                  <div className="px-3 py-1.5 text-[9px] uppercase tracking-wide text-[#505052]/60 border-b border-[#EBEBEC] bg-[#FAF9F7]" style={font}>
                    {search ? `Matches for "${search}"` : `Browse ${data.sku_list.length} Vinsight SKUs`}
                  </div>
                  {filtered.map((opt) => (
                    <button
                      key={opt.sku_id}
                      onMouseDown={(e) => e.preventDefault() /* keep focus so onBlur doesn't race */}
                      onClick={() => {
                        setSkuAssignments(prev => ({ ...prev, [sku.external_code]: opt.sku_id }));
                        setSkuSearch(prev => ({ ...prev, [sku.external_code]: '' }));
                        setSkuPickerOpen(prev => ({ ...prev, [sku.external_code]: false }));
                        persistMatch('sku', sku.external_code, opt.sku_id);
                      }}
                      className="w-full text-left px-3 py-1.5 text-[11px] hover:bg-[#FAF9F7] text-[#1F1F1F]"
                      style={font}
                    >
                      <span className="font-mono text-[#931220]">{opt.sku_code}</span>
                      <span className="ml-2 text-[#505052]">{opt.description}</span>
                      {opt.variety && <span className="ml-1 text-[10px] text-[#505052]/70">({opt.variety})</span>}
                    </button>
                  ))}
                  {filtered.length === 0 && (
                    <div className="px-3 py-2 text-[10px] text-[#505052]">
                      No Vinsight SKUs match &ldquo;{search}&rdquo;. If this is a brand-new product,
                      create it in Vinsight first, then re-sync and retry the import.
                    </div>
                  )}
                </div>
              )}
            </div>
          </div>
        )}
      </div>
      {/* JF-12: Inline SKU suggestions (80%+ auto-match hints) — kept per JF-26 spec */}
      {!assignedId && sku.suggestions && sku.suggestions.length > 0 && (
        <div className="ml-[180px] pl-7 mt-1 flex flex-wrap gap-1.5">
          <span className="text-[10px] text-[#505052]/60 mr-0.5">Suggest:</span>
          {sku.suggestions.map((s) => (
            <button
              key={s.sku_id}
              onClick={() => { setSkuAssignments(prev => ({ ...prev, [sku.external_code]: s.sku_id })); persistMatch('sku', sku.external_code, s.sku_id); }}
              className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] transition-colors ${
                s.score >= 70
                  ? 'bg-green-100 text-green-800 hover:bg-green-200 font-medium'
                  : 'bg-gray-100 text-[#505052] hover:bg-gray-200'
              }`}
              style={font}
            >
              <span className="font-mono">{s.sku_code}</span>
              <span className="text-[9px] opacity-70">{s.description?.slice(0, 30)}</span>
              <span className={`text-[9px] ${s.score >= 70 ? 'text-green-600' : 'text-[#505052]/50'}`}>{s.score}%</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Unmatched Customers panel
// ---------------------------------------------------------------------------

function UnmatchedCustomersPanel() {
  const { unmatched_customers, assignedCustomerCount } = useImportPreviewContext();

  return (
    <div className={`rounded-xl border p-4 ${unmatched_customers.length > 0 ? 'border-amber-200 bg-amber-50' : 'border-green-200 bg-green-50'}`}>
      {unmatched_customers.length === 0 ? (
        <h3 className="text-xs font-semibold text-green-700" style={font}>
          ✓ All Customers Matched
        </h3>
      ) : (
        <>
        <h3 className="text-xs font-semibold text-amber-800 mb-3" style={font}>
          Unmatched Customers ({unmatched_customers.length})
          {assignedCustomerCount > 0 && <span className="text-green-700 ml-2">— {assignedCustomerCount} assigned</span>}
        </h3>
        <div className="space-y-3">
          {unmatched_customers.map((cust) => (
            <UnmatchedCustomerRow key={cust.external_name} cust={cust} />
          ))}
        </div>
        </>
      )}
    </div>
  );
}

function UnmatchedCustomerRow({ cust }: { cust: UnmatchedCustomer }) {
  const {
    data,
    customerAssignments,
    setCustomerAssignments,
    customerSearch,
    setCustomerSearch,
    getFilteredCustomers,
    openCreateCustomer,
    persistMatch,
    newCustName,
  } = useImportPreviewContext();

  const search = customerSearch[cust.external_name] || '';
  const assignedId = customerAssignments[cust.external_name];
  const filtered = useMemo(() => getFilteredCustomers(search), [getFilteredCustomers, search]);

  return (
    <div className="text-xs" style={font}>
      <div className="flex items-center gap-3">
        <div className="min-w-[180px]">
          <span className="text-[#1F1F1F]">{cust.external_name}</span>
          {cust.is_sample && <span className="ml-1.5 inline-block px-1.5 py-0.5 rounded text-[9px] font-semibold bg-yellow-100 text-yellow-700">SAMPLE</span>}
          <span className="text-[#505052] ml-2 text-[10px]">({cust.row_count} rows, ${cust.total_revenue.toFixed(0)})</span>
        </div>
        <span className="text-[#D8D9DA]">→</span>
        {assignedId ? (
          <div className="flex items-center gap-2">
            <span className="text-green-700 text-[11px]">
              {(() => {
                const found = data.customer_list.find(c => c.customer_id === assignedId);
                return found?.display_name || found?.customer_name || newCustName || `ID: ${assignedId}`;
              })()}
            </span>
            <button onClick={() => { const next = { ...customerAssignments }; delete next[cust.external_name]; setCustomerAssignments(next); }} className="text-[10px] text-[#505052] hover:text-[#931220]">✕</button>
          </div>
        ) : (
          <div className="flex items-center gap-2 flex-1 max-w-lg">
            <div className="relative flex-1">
              <input
                type="text"
                placeholder="Search customer..."
                value={search}
                onChange={(e) => setCustomerSearch(prev => ({ ...prev, [cust.external_name]: e.target.value }))}
                className="w-full bg-white border border-[#D8D9DA] rounded-lg px-3 py-1.5 text-[11px] text-[#1F1F1F] placeholder-[#505052]/50 focus:border-[#931220] focus:outline-none"
                style={font}
              />
              {search.length >= 2 && (
                <div className="absolute z-10 mt-1 w-full bg-white border border-[#D8D9DA] rounded-lg shadow-lg max-h-48 overflow-y-auto">
                  {filtered.map((opt) => (
                    <button
                      key={opt.customer_id}
                      onClick={() => { setCustomerAssignments(prev => ({ ...prev, [cust.external_name]: opt.customer_id })); setCustomerSearch(prev => ({ ...prev, [cust.external_name]: '' })); persistMatch('customer', cust.external_name, opt.customer_id, cust.external_code); }}
                      className="w-full text-left px-3 py-1.5 text-[11px] hover:bg-[#FAF9F7] text-[#1F1F1F]"
                      style={font}
                    >
                      <span>{opt.display_name || opt.customer_name}</span>
                      {(opt.territory || opt.rep) && (
                        <span className="ml-1 text-[10px] text-[#505052]/70">
                          {[opt.territory, opt.rep].filter(Boolean).join(' · ')}
                        </span>
                      )}
                    </button>
                  ))}
                  {filtered.length === 0 && (
                    <div className="px-3 py-2 text-[10px] text-[#505052]">No matches found</div>
                  )}
                </div>
              )}
            </div>
            <button
              onClick={() => openCreateCustomer(cust.external_name)}
              className="px-2 py-1.5 rounded-lg text-[10px] font-medium bg-[#931220] text-white hover:bg-[#7a0f1a] whitespace-nowrap"
              style={font}
            >
              + New
            </button>
          </div>
        )}
      </div>
      {/* F17 + B8: Inline suggestions. B8 (May 8 / Apr 13 loop) adds
          suburb / state / channel meta so the owner can disambiguate suggestions
          like "CUSTOMER 106" vs "Customer 02" without clicking. */}
      {!assignedId && cust.suggestions && cust.suggestions.length > 0 && (
        <div className="ml-[180px] pl-7 mt-1 flex flex-wrap gap-1.5">
          <span className="text-[10px] text-[#505052]/60 mr-0.5">Suggest:</span>
          {cust.suggestions.map((s) => {
            const meta = [
              s.suburb,
              s.state || (s.postcode ? s.postcode : ''),
              s.channel,
            ].filter(Boolean).join(' · ');
            return (
              <button
                key={s.customer_id}
                onClick={() => { setCustomerAssignments(prev => ({ ...prev, [cust.external_name]: s.customer_id })); persistMatch('customer', cust.external_name, s.customer_id, cust.external_code); }}
                className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] transition-colors ${
                  s.score >= 80
                    ? 'bg-green-100 text-green-800 hover:bg-green-200 font-medium'
                    : 'bg-gray-100 text-[#505052] hover:bg-gray-200'
                }`}
                style={font}
                title={meta || undefined}
              >
                {s.display_name}
                {meta && (
                  <span className={`text-[9px] ${s.score >= 80 ? 'text-green-700/70' : 'text-[#505052]/60'}`}>
                    {meta}
                  </span>
                )}
                <span className={`text-[9px] ${s.score >= 80 ? 'text-green-600' : 'text-[#505052]/50'}`}>{s.score}%</span>
                {s.score >= 80 && <span className="text-green-600 text-[9px]">[OK]</span>}
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Unmatched Reps panel — JF-14
// ---------------------------------------------------------------------------

function UnmatchedRepsPanel() {
  const { data, createdReps } = useImportPreviewContext();
  // F4 (May 10): track which rep cards are expanded. Multiple cards may be
  // expanded simultaneously so the owner can compare two reps side-by-side.
  const [expandedReps, setExpandedReps] = useState<Set<string>>(new Set());

  if (!data.unmatched_reps || data.unmatched_reps.length === 0) return null;

  const toggleExpand = (repName: string) => {
    setExpandedReps(prev => {
      const next = new Set(Array.from(prev));
      if (next.has(repName)) next.delete(repName);
      else next.add(repName);
      return next;
    });
  };

  return (
    <div className="rounded-xl border border-amber-200 bg-amber-50 p-4">
      <h3 className="text-xs font-semibold text-amber-800 mb-3" style={font}>
        New Reps ({data.unmatched_reps.filter(r => !createdReps[r.rep_name]).length})
        {Object.keys(createdReps).length > 0 && <span className="text-green-700 ml-2">-- {Object.keys(createdReps).length} created</span>}
      </h3>
      <div className="space-y-2">
        {data.unmatched_reps.map((rep) => (
          <UnmatchedRepRow
            key={rep.rep_name}
            rep={rep}
            isExpanded={expandedReps.has(rep.rep_name)}
            onToggle={() => toggleExpand(rep.rep_name)}
          />
        ))}
      </div>
    </div>
  );
}

// F4 (May 10): per-rep card with collapsed/expanded state + drill-down sections.
// Backwards-compat: when the backend payload is the old 3-field shape (no
// customers / sample_rows), the chevron toggle is hidden and the row renders
// exactly as it did pre-F4 — pure additive enhancement.
function UnmatchedRepRow({
  rep,
  isExpanded,
  onToggle,
}: {
  rep: UnmatchedRep;
  isExpanded: boolean;
  onToggle: () => void;
}) {
  const { createdReps, openCreateRep } = useImportPreviewContext();
  const isCreated = !!createdReps[rep.rep_name];

  // Backwards-compat guards: only show drill-down UI when backend supplied
  // the F4 fields. Older cached previews fall through to the legacy render.
  const hasDrillDown =
    (rep.customers && rep.customers.length > 0) ||
    (rep.sample_rows && rep.sample_rows.length > 0);
  const txnCount = rep.transactions_count ?? rep.row_count;

  return (
    <div className="rounded-lg bg-white border border-amber-100 p-2.5">
      <div className="flex items-center gap-3 text-xs" style={font}>
        {/* Chevron — only when drill-down data is present */}
        {hasDrillDown ? (
          <button
            onClick={onToggle}
            className="text-[#505052] hover:text-[#1F1F1F] w-4 flex-shrink-0"
            style={font}
            aria-label={isExpanded ? 'Collapse' : 'Expand'}
            aria-expanded={isExpanded}
          >
            {isExpanded ? '▾' : '▸'}
          </button>
        ) : (
          <span className="w-4 flex-shrink-0" />
        )}

        <div className="flex-1 min-w-[180px]">
          <span className="text-[#1F1F1F] font-medium">{rep.rep_name}</span>
          <span className="text-[#505052] ml-2 text-[10px]">
            {rep.row_count} rows
            {rep.meta_territory ? ` | ${rep.meta_territory}` : ''}
            {hasDrillDown ? ` | ${txnCount} txn` : ''}
          </span>
        </div>

        {isCreated ? (
          <span className="text-green-700 text-[11px]">Created (ID: {createdReps[rep.rep_name]})</span>
        ) : (
          <button
            onClick={() => openCreateRep(rep.rep_name, rep.meta_territory)}
            className="px-2 py-1.5 rounded-lg text-[10px] font-medium bg-[#931220] text-white hover:bg-[#7a0f1a] whitespace-nowrap"
            style={font}
          >
            + Create Rep
          </button>
        )}
      </div>

      {hasDrillDown && isExpanded && (
        <div className="mt-3 ml-7 space-y-3 border-t border-amber-100 pt-3">
          {/* Customers */}
          {rep.customers && rep.customers.length > 0 && (
            <div>
              <div className="text-[10px] font-semibold text-amber-800 mb-1" style={font}>
                Customers ({rep.customers_count_total ?? rep.customers.length} distinct)
              </div>
              <div className="text-[10px] text-[#505052] max-h-24 overflow-y-auto" style={font}>
                {rep.customers.map((c, i) => (
                  <div key={i} className="truncate">{c}</div>
                ))}
                {rep.customers_count_total !== undefined &&
                 rep.customers_count_total > rep.customers.length && (
                  <div className="text-[#931220] mt-1">
                    +{rep.customers_count_total - rep.customers.length} more
                  </div>
                )}
              </div>
            </div>
          )}

          {/* Suburbs */}
          {rep.distinct_suburbs && rep.distinct_suburbs.length > 0 && (
            <div>
              <div className="text-[10px] font-semibold text-amber-800 mb-1" style={font}>
                Suburbs ({rep.suburbs_count_total ?? rep.distinct_suburbs.length} distinct)
              </div>
              <div className="text-[10px] text-[#505052]" style={font}>
                {rep.distinct_suburbs.join(', ')}
                {rep.suburbs_count_total !== undefined &&
                 rep.suburbs_count_total > rep.distinct_suburbs.length && (
                  <span className="text-[#931220] ml-1">
                    (+{rep.suburbs_count_total - rep.distinct_suburbs.length} more)
                  </span>
                )}
              </div>
            </div>
          )}

          {/* Sample transactions */}
          {rep.sample_rows && rep.sample_rows.length > 0 && (
            <div>
              <div className="text-[10px] font-semibold text-amber-800 mb-1" style={font}>
                Sample transactions
              </div>
              <table className="w-full text-[10px]" style={font}>
                <thead>
                  <tr className="text-left text-[#505052]/70 border-b border-amber-100">
                    <th className="py-1 pr-2 font-medium">Customer</th>
                    <th className="py-1 pr-2 font-medium">Suburb</th>
                    <th className="py-1 pr-2 font-medium">SKU</th>
                    <th className="py-1 pr-2 font-medium text-right">Qty</th>
                    <th className="py-1 pr-2 font-medium text-right">Amount</th>
                  </tr>
                </thead>
                <tbody>
                  {rep.sample_rows.map((s, i) => (
                    <tr key={i} className="text-[#1F1F1F]">
                      <td className="py-1 pr-2 truncate max-w-[120px]" title={s.customer_name}>
                        {s.customer_name || '—'}
                      </td>
                      <td className="py-1 pr-2 truncate max-w-[80px]" title={s.suburb}>
                        {s.suburb || '—'}
                      </td>
                      <td className="py-1 pr-2 truncate max-w-[140px]" title={s.sku_or_description}>
                        {s.sku_or_description || '—'}
                      </td>
                      <td className="py-1 pr-2 text-right font-mono">{s.qty}</td>
                      <td className="py-1 pr-2 text-right font-mono">
                        ${s.total_amount.toFixed(2)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
