'use client';

// ---------------------------------------------------------------------------
// ImportPreviewTable
// ---------------------------------------------------------------------------
// BUG-22: DASH-07 split — owns the row preview table. Reads its slice of state
// via useImportPreviewContext(). Pure move from ImportPreview.tsx, zero
// behaviour changes.
// ---------------------------------------------------------------------------

import {
  useImportPreviewContext,
  font,
  StatusBadge,
} from './ImportPreviewContext';

export default function ImportPreviewTable() {
  const {
    rows,
    displayRows,
    rowSearch,
    setRowSearch,
    showAllRows,
    setShowAllRows,
    autoExcludedRows,
    excludedRows,
    excludeReasons,
    skuAssignments,
    customerAssignments,
    unmatchedOverrides,
    setUnmatchedOverrides,
    unmatchedSkuOverrides,
    setUnmatchedSkuOverrides,
    toggleRowExclusion,
    setToast,
  } = useImportPreviewContext();

  return (
    <div className="rounded-xl border border-[#EBEBEC] bg-white overflow-hidden">
      <div className="px-4 py-3 border-b border-[#EBEBEC] flex items-center justify-between gap-3 flex-wrap">
        <h3 className="text-xs font-semibold text-[#1F1F1F] shrink-0 flex items-center gap-2" style={font}>
          <span>Row Preview {rowSearch.length >= 2 ? `(${displayRows.length} of ${rows.length})` : !showAllRows && rows.length > 100 ? `(showing 100 of ${rows.length})` : ''}</span>
          {autoExcludedRows.size > 0 && (
            <span
              className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-semibold bg-red-50 text-[#931220] border border-red-200"
              title="Rows auto-excluded by business rule (e.g. ALM warehouse on DWS imports)"
            >
              <span className="w-1.5 h-1.5 rounded-full bg-[#931220]" />
              {autoExcludedRows.size} auto-excluded
            </span>
          )}
          {(excludedRows.size - autoExcludedRows.size) > 0 && (
            <span
              className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-semibold bg-amber-50 text-amber-800 border border-amber-200"
              title="Rows manually unchecked by you"
            >
              <span className="w-1.5 h-1.5 rounded-full bg-amber-500" />
              {excludedRows.size - autoExcludedRows.size} manually excluded
            </span>
          )}
        </h3>
        <input
          type="text"
          placeholder="Search by SKU, customer, or status..."
          value={rowSearch}
          onChange={(e) => setRowSearch(e.target.value)}
          className="flex-1 max-w-xs bg-white border border-[#D8D9DA] rounded-lg px-3 py-1.5 text-[11px] text-[#1F1F1F] placeholder-[#505052]/50 focus:border-[#931220] focus:outline-none"
          style={font}
        />
        {rows.length > 100 && (
          <button onClick={() => setShowAllRows(!showAllRows)} className="px-3 py-1.5 rounded-lg text-[11px] font-medium border border-[#931220] text-[#931220] hover:bg-[#931220] hover:text-white transition-colors shrink-0" style={font}>
            {showAllRows ? 'Show first 100' : `Show all ${rows.length} rows`}
          </button>
        )}
      </div>
      <div className="overflow-x-auto max-h-[400px] overflow-y-auto">
        <table className="w-full text-[11px]" style={font}>
          <thead className="sticky top-0 bg-[#FAF9F7]">
            <tr className="text-[#505052] border-b border-[#EBEBEC]">
              <th className="px-2 py-2 text-center font-medium w-8">
                <span className="text-[9px]" title="Include in import">Inc</span>
              </th>
              <th className="px-3 py-2 text-left font-medium w-10">#</th>
              <th className="px-3 py-2 text-left font-medium">Status</th>
              <th className="px-3 py-2 text-left font-medium">Date</th>
              <th className="px-3 py-2 text-left font-medium">SKU</th>
              <th className="px-3 py-2 text-left font-medium">Customer</th>
              <th className="px-3 py-2 text-right font-medium">Cases</th>
              <th className="px-3 py-2 text-right font-medium">Revenue</th>
            </tr>
          </thead>
          <tbody>
            {displayRows.map((row) => {
              const isExcluded = excludedRows.has(row.row_num);
              const isAutoExcluded = autoExcludedRows.has(row.row_num);
              const isManuallyExcluded = isExcluded && !isAutoExcluded;
              const exclusionReason = excludeReasons[row.row_num] || '';
              const isOverridden = unmatchedOverrides.has(row.raw_customer) && row.status === 'matched';
              const isSkuOverridden = unmatchedSkuOverrides.has(row.raw_sku) && row.sku_id !== null;
              // Reflect client-side assignments in row status
              const skuResolved = !isSkuOverridden && (row.sku_id !== null || skuAssignments[row.raw_sku]);
              const custResolved = !row.raw_customer || row.customer_id !== null || customerAssignments[row.raw_customer];
              const effectiveStatus = isExcluded ? 'excluded'
                : isOverridden || isSkuOverridden ? 'unmatched'
                : row.status === 'unmatched' && skuResolved && custResolved ? 'matched'
                : row.status;
              // JF-20: Differentiate visual treatment for auto vs manual exclusion
              const rowBgClass = isAutoExcluded
                ? 'bg-gray-100 opacity-60 border-l-4 border-l-[#931220]'
                : isManuallyExcluded
                ? 'bg-gray-100 opacity-60 border-l-4 border-l-amber-500'
                : effectiveStatus === 'matched' ? ''
                : effectiveStatus === 'unmatched' ? 'bg-amber-50/50'
                : effectiveStatus === 'duplicate' ? 'bg-gray-50 opacity-50'
                : 'bg-red-50/50';
              const checkboxTitle = isAutoExcluded
                ? 'ALM warehouse — auto-excluded by business rule. Click to override and include.'
                : isManuallyExcluded
                ? `Manually excluded${exclusionReason ? `: ${exclusionReason}` : ''}. Click to re-include.`
                : 'Click to exclude from import';
              return (
                <tr
                  key={row.row_num}
                  className={`border-b border-[#EBEBEC]/60 ${rowBgClass}`}
                >
                  <td className="px-2 py-1.5 text-center">
                    <input
                      type="checkbox"
                      checked={!isExcluded}
                      onChange={() => toggleRowExclusion(row.row_num)}
                      className="w-3.5 h-3.5 rounded border-[#D8D9DA] text-[#931220] focus:ring-[#931220] cursor-pointer"
                      title={checkboxTitle}
                    />
                  </td>
                  <td className="px-3 py-1.5 text-[#505052] font-mono">{row.row_num}</td>
                  <td className="px-3 py-1.5">
                    {isAutoExcluded ? (
                      <span
                        className="inline-block px-1.5 py-0.5 rounded text-[9px] font-semibold bg-red-100 text-[#931220] border border-red-200"
                        title="Auto-excluded by business rule"
                      >
                        AUTO
                      </span>
                    ) : isManuallyExcluded ? (
                      <span
                        className="inline-block px-1.5 py-0.5 rounded text-[9px] font-semibold bg-amber-100 text-amber-800 border border-amber-200"
                        title={exclusionReason || 'Manually excluded'}
                      >
                        SKIP
                      </span>
                    ) : (
                      <StatusBadge status={effectiveStatus} />
                    )}
                  </td>
                  <td className="px-3 py-1.5 text-[#1F1F1F] font-mono">{row.sale_date || '\u2014'}</td>
                  <td className="px-3 py-1.5">
                    <span className={!isSkuOverridden && row.sku_id ? 'text-[#1F1F1F]' : 'text-amber-700'}>{row.raw_sku}</span>
                    {row.sku_name && !isSkuOverridden && <span className="ml-1 text-[#505052]">&rarr; {row.sku_name}</span>}
                    {!isExcluded && row.sku_id !== null && row.raw_sku && !unmatchedSkuOverrides.has(row.raw_sku) && (
                      <span className="ml-1 inline-flex items-center gap-0.5 px-1 py-0.5 rounded text-[8px] font-semibold group cursor-help bg-gray-100 text-gray-500" title="Auto-matched SKU — click ✕ to reassign">
                        AUTO
                        <button
                          onClick={(e) => {
                            e.stopPropagation();
                            const code = row.raw_sku;
                            const count = rows.filter(r => r.raw_sku === code).length;
                            setUnmatchedSkuOverrides(prev => { const next = new Set(Array.from(prev)); next.add(code); return next; });
                            setToast(`${code} unmatched — reassign above (${count} rows)`);
                            setTimeout(() => setToast(null), 4000);
                          }}
                          className="ml-0.5 hover:text-red-600 text-[9px] leading-none text-gray-400"
                          title="Unmatch and reassign"
                        >&#x2715;</button>
                      </span>
                    )}
                  </td>
                  <td className="px-3 py-1.5">
                    <span className={!isOverridden && (row.customer_id || !row.raw_customer) ? 'text-[#1F1F1F]' : 'text-amber-700'}>{row.raw_customer || '\u2014'}</span>
                    {row.customer_name && row.customer_name !== row.raw_customer && !isOverridden && <span className="ml-1 text-[#505052]">&rarr; {row.customer_name}</span>}
                    {isExcluded && exclusionReason && <span className="ml-1 text-[9px] text-gray-400 italic">{exclusionReason}</span>}
                    {!isExcluded && row.status === 'matched' && row.raw_customer && !unmatchedOverrides.has(row.raw_customer) && (
                      <span className={`ml-1 inline-flex items-center gap-0.5 px-1 py-0.5 rounded text-[8px] font-semibold group cursor-help ${row.match_method === 'name' ? 'bg-yellow-100 text-yellow-700' : 'bg-gray-100 text-gray-500'}`} title={`Matched by ${row.match_method || 'auto'} \u2014 click \u2715 to reassign`}>
                        {row.match_method === 'name' ? 'NAME' : row.match_method === 'code' ? 'CODE' : 'AUTO'}
                        <button
                          onClick={(e) => {
                            e.stopPropagation();
                            const name = row.raw_customer;
                            const count = rows.filter(r => r.raw_customer === name).length;
                            setUnmatchedOverrides(prev => { const next = new Set(Array.from(prev)); next.add(name); return next; });
                            setToast(`${name} unmatched \u2014 reassign above (${count} rows)`);
                            setTimeout(() => setToast(null), 4000);
                          }}
                          className={`ml-0.5 hover:text-red-600 text-[9px] leading-none ${row.match_method === 'name' ? 'text-yellow-500' : 'text-gray-400'}`}
                          title="Unmatch and reassign"
                        >&#x2715;</button>
                      </span>
                    )}
                  </td>
                  <td className="px-3 py-1.5 text-right text-[#1F1F1F] font-mono">{row.quantity?.toFixed(1) || '\u2014'}</td>
                  <td className="px-3 py-1.5 text-right text-[#1F1F1F] font-mono">
                    {row.net_revenue != null ? `$${row.net_revenue.toLocaleString(undefined, { minimumFractionDigits: 2 })}` : '\u2014'}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
