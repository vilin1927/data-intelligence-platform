'use client';

// ---------------------------------------------------------------------------
// ImportPreviewResults
// ---------------------------------------------------------------------------
// BUG-22: DASH-07 split — post-import confirmation card (BUG-10 structured
// payload) + view-imported drill-through link + dead-letter panel. Rendered
// in place of the preview UI once importResult is non-null.
//
// Pure move from ImportPreview.tsx, zero behaviour changes.
// ---------------------------------------------------------------------------

import Link from 'next/link';
import {
  useImportPreviewContext,
  font,
  headingFont,
} from './ImportPreviewContext';

export default function ImportPreviewResults() {
  const { importResult, onReset, assignedSkuCount, createdReps } = useImportPreviewContext();

  if (!importResult) return null;

  // C16: post-upload success banner — direct nav to verify uploaded data.
  // Counts pulled from existing confirmation payload (BUG-10) — no new fields.
  const conf = importResult.confirmation;
  const bannerImported = conf?.imported ?? importResult.rows_imported ?? 0;
  const bannerNewCustomers = conf?.new_customers.count ?? 0;
  const bannerNewSkus = conf?.new_sku_matches.count ?? (assignedSkuCount || 0);

  return (
    <div className="space-y-4">
      {importResult.success && (
        <div
          className="rounded-xl border border-green-200 bg-green-50 p-4 flex flex-wrap items-center gap-x-4 gap-y-2"
          role="status"
          style={font}
        >
          <span className="text-sm font-semibold text-green-800">
            Upload complete — {bannerNewCustomers} customers, {bannerNewSkus} SKUs, {bannerImported} rows imported.
          </span>
          <div className="flex gap-2 ml-auto">
            <Link
              href="/reference?tab=customers"
              className="inline-flex items-center px-3 py-1.5 rounded-lg text-[11px] font-medium bg-white border border-green-300 text-green-800 hover:bg-green-100 transition-colors"
            >
              View Customers
            </Link>
            <Link
              href="/reference?tab=skus"
              className="inline-flex items-center px-3 py-1.5 rounded-lg text-[11px] font-medium bg-white border border-green-300 text-green-800 hover:bg-green-100 transition-colors"
            >
              View SKUs
            </Link>
          </div>
        </div>
      )}
      <div className={`rounded-xl border p-5 ${
        importResult.success
          ? 'border-green-200 bg-green-50'
          : 'border-red-200 bg-red-50'
      }`}>
        <h3 className="text-base font-semibold mb-3" style={{ ...headingFont, color: importResult.success ? '#166534' : '#931220' }}>
          {importResult.success ? 'Import Complete' : 'Import Failed'}
        </h3>

        {importResult.success ? (
          <div className="space-y-4 text-xs" style={font}>
            {/* BUG-10: Post-import confirmation screen with structured metrics */}
            {(() => {
              const conf = importResult.confirmation;
              const imported = conf?.imported ?? importResult.rows_imported ?? 0;
              const totalRows = conf?.total_rows ?? ((importResult.rows_imported ?? 0) + (importResult.rows_skipped ?? 0));
              const skippedCount = conf?.skipped.count ?? importResult.rows_skipped ?? 0;
              const nullSku = conf?.null_sku_rows ?? 0;
              const nullCust = conf?.null_customer_rows ?? 0;
              const newCustomers = conf?.new_customers.count ?? 0;
              const newSkus = conf?.new_sku_matches.count ?? (assignedSkuCount || 0);
              const newReps = conf?.new_reps.count ?? Object.keys(createdReps).length;
              const uploadMin = conf?.upload_id_min ?? null;
              const uploadMax = conf?.upload_id_max ?? null;
              const verifyHref = uploadMin != null && uploadMax != null
                ? `/legacy-data?upload_id_min=${uploadMin}&upload_id_max=${uploadMax}`
                : '/legacy-data';
              const skippedRows = conf?.skipped.rows ?? [];

              return (
                <>
                  <div className="grid grid-cols-4 gap-3 max-w-3xl">
                    <div className="bg-white rounded-lg border border-[#EBEBEC] p-3 text-center">
                      <div className="text-lg font-semibold text-[#1F1F1F] font-mono">{totalRows}</div>
                      <div className="text-[10px] text-[#505052]">Total Rows</div>
                    </div>
                    <div className="bg-white rounded-lg border border-green-200 p-3 text-center">
                      <div className="text-lg font-semibold text-green-700 font-mono">{imported}</div>
                      <div className="text-[10px] text-[#505052]">Imported</div>
                    </div>
                    <div className="bg-white rounded-lg border border-[#EBEBEC] p-3 text-center">
                      <div className="text-lg font-semibold text-[#505052] font-mono">{skippedCount}</div>
                      <div className="text-[10px] text-[#505052]">Skipped</div>
                    </div>
                    <div className={`bg-white rounded-lg border p-3 text-center ${nullSku > 0 ? 'border-amber-300' : 'border-[#EBEBEC]'}`}>
                      <div className={`text-lg font-semibold font-mono ${nullSku > 0 ? 'text-amber-700' : 'text-[#505052]'}`}>{nullSku}</div>
                      <div className="text-[10px] text-[#505052]">NULL SKU rows</div>
                    </div>
                  </div>

                  <div className="grid grid-cols-4 gap-3 max-w-3xl">
                    <div className={`bg-white rounded-lg border p-3 text-center ${nullCust > 0 ? 'border-amber-300' : 'border-[#EBEBEC]'}`}>
                      <div className={`text-lg font-semibold font-mono ${nullCust > 0 ? 'text-amber-700' : 'text-[#505052]'}`}>{nullCust}</div>
                      <div className="text-[10px] text-[#505052]">NULL Customer</div>
                    </div>
                    <div className="bg-white rounded-lg border border-[#EBEBEC] p-3 text-center">
                      <div className="text-lg font-semibold text-[#1F1F1F] font-mono">{newCustomers}</div>
                      <div className="text-[10px] text-[#505052]">New Customers</div>
                    </div>
                    <div className="bg-white rounded-lg border border-[#EBEBEC] p-3 text-center">
                      <div className="text-lg font-semibold text-[#1F1F1F] font-mono">{newSkus}</div>
                      <div className="text-[10px] text-[#505052]">New SKU Matches</div>
                    </div>
                    <div className="bg-white rounded-lg border border-[#EBEBEC] p-3 text-center">
                      <div className="text-lg font-semibold text-[#1F1F1F] font-mono">{newReps}</div>
                      <div className="text-[10px] text-[#505052]">New Reps</div>
                    </div>
                  </div>

                  {(nullSku > 0 || nullCust > 0) && (
                    <div className="bg-amber-50 border border-amber-200 rounded-lg p-3 text-[11px] text-amber-900" style={font}>
                      <strong>Warning:</strong> {nullSku > 0 && <>{nullSku} row{nullSku !== 1 ? 's were' : ' was'} inserted with NULL SKU (unmatched new vintage?). </>}
                      {nullCust > 0 && <>{nullCust} row{nullCust !== 1 ? 's were' : ' was'} inserted with NULL customer. </>}
                      These rows will appear blank in Combined Data. Click the link below to review and assign them.
                    </div>
                  )}

                  {importResult.cogs_assigned && (
                    <p className="text-[#505052] text-[10px]">COGS assigned: {importResult.cogs_assigned.total} rows ({importResult.cogs_assigned.vintage_matched} vintage, {importResult.cogs_assigned.fallback} fallback)</p>
                  )}

                  {skippedRows.length > 0 && (
                    <details>
                      <summary className="text-amber-700 cursor-pointer text-xs">
                        {skippedRows.length} skipped/flagged row{skippedRows.length !== 1 ? 's' : ''} — click to see reasons
                      </summary>
                      <ul className="mt-2 space-y-1 text-[10px] text-[#505052] font-mono max-h-40 overflow-y-auto">
                        {skippedRows.slice(0, 30).map((r, i) => (
                          <li key={`sk${i}`}>Row {r.row_index}: {r.reason}</li>
                        ))}
                      </ul>
                    </details>
                  )}

                  {importResult.errors && importResult.errors.length > 0 && !conf && (() => {
                    // Fallback: old-format warnings display for when confirmation payload is missing.
                    const customerWarnings: Record<string, number> = {};
                    const otherWarnings: string[] = [];
                    for (const e of importResult.errors!) {
                      const m = e.match(/unrecognised \w+ outlet '([^']+)'/);
                      if (m) {
                        customerWarnings[m[1]] = (customerWarnings[m[1]] || 0) + 1;
                      } else {
                        otherWarnings.push(e);
                      }
                    }
                    const custKeys = Object.keys(customerWarnings);
                    return (
                      <details>
                        <summary className="text-amber-700 cursor-pointer text-xs">{importResult.errors!.length} warnings</summary>
                        <ul className="mt-2 space-y-1 text-[10px] text-[#505052] font-mono max-h-40 overflow-y-auto">
                          {custKeys.map((name, i) => <li key={`c${i}`}>{name} — {customerWarnings[name]} rows imported with customer_id=NULL</li>)}
                          {otherWarnings.slice(0, 15).map((e, i) => <li key={`o${i}`}>{e}</li>)}
                        </ul>
                      </details>
                    );
                  })()}

                  <div className="border-t border-green-200 pt-3">
                    <p className="text-[11px] font-semibold text-[#1F1F1F] mb-2">Verify imported data:</p>
                    <div className="flex flex-wrap gap-2">
                      <a href={verifyHref} className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-[11px] font-medium bg-white border border-[#D8D9DA] text-[#1F1F1F] hover:bg-[#FAF9F7] transition-colors" style={font}>
                        {uploadMin != null && uploadMax != null
                          ? `View imported transactions (${uploadMin}-${uploadMax})`
                          : 'Combined Data — check imported rows'}
                      </a>
                    </div>
                  </div>
                </>
              );
            })()}
          </div>
        ) : (
          <p className="text-xs text-[#931220]" style={font}>{importResult.error}</p>
        )}
      </div>

      <button onClick={onReset} className="px-4 py-2 rounded-lg bg-[#FAF9F7] border border-[#D8D9DA] text-[#505052] hover:bg-white text-xs" style={font}>
        Import Another File
      </button>
    </div>
  );
}
