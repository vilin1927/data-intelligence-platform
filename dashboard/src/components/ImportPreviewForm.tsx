'use client';

// ---------------------------------------------------------------------------
// ImportPreviewForm
// ---------------------------------------------------------------------------
// BUG-22: DASH-07 split — owns the "form-like" parts of the wizard:
//   - Header: preview banner + summary stats bar + cancel link
//   - Footer: the submit button + unmatched warnings
//   - Modals: create-new-customer + create-new-rep dialogs
//
// The parent (ImportPreview.tsx) renders these in the correct order so the
// visual layout is byte-identical to the pre-split component. Pure move, zero
// behaviour changes.
// ---------------------------------------------------------------------------

import { useCallback } from 'react';
import {
  useImportPreviewContext,
  font,
  headingFont,
  SummaryCard,
} from './ImportPreviewContext';
import { apiGet } from '@/lib/api';

// ---------------------------------------------------------------------------
// Header — preview banner + summary stats
// ---------------------------------------------------------------------------

export function ImportPreviewFormHeader() {
  const {
    data,
    onReset,
    summary,
    unmatched_skus,
    unmatched_customers,
    toast,
  } = useImportPreviewContext();

  return (
    <>
      {/* Toast notification */}
      {toast && (
        <div className="fixed top-4 right-4 z-50 bg-[#1F1F1F] text-white text-xs px-4 py-2.5 rounded-lg shadow-lg animate-fade-in" style={font}>
          {toast}
        </div>
      )}

      {/* Preview mode banner */}
      <div className="flex items-center gap-2 text-xs text-[#7A6C5B]" style={font}>
        <span className="inline-block w-2 h-2 rounded-full bg-amber-400 animate-pulse" />
        Preview Mode — review data before importing
      </div>

      {/* Summary Bar */}
      <div className="rounded-xl border border-[#EBEBEC] bg-white p-4">
        <div className="flex items-center justify-between mb-3">
          <h3 className="text-sm font-semibold text-[#1F1F1F]" style={headingFont}>
            Preview: {data.file} <span className="text-[#505052] font-normal">({data.channel.toUpperCase()})</span>
          </h3>
          <button onClick={onReset} className="text-[10px] text-[#505052] hover:text-[#931220]" style={font}>Cancel</button>
        </div>

        <div className="grid grid-cols-5 gap-3">
          <SummaryCard label="Total Rows" value={summary.total_rows} subtitle={summary.sample_rows ? `${summary.total_rows - summary.sample_rows} sales + ${summary.sample_rows} samples` : undefined} />
          <SummaryCard label="Matched" value={summary.matched} color="green" subtitle={summary.matched_by_name ? `${(summary.matched_by_code || 0) + (summary.matched_by_saved || 0)} by code + ${summary.matched_by_name} by name` : undefined} />
          <SummaryCard
            label="Unmatched"
            value={unmatched_customers.length + unmatched_skus.length}
            color={(unmatched_customers.length + unmatched_skus.length) > 0 ? 'amber' : 'default'}
            subtitle={summary.unmatched > 0 ? `${summary.unmatched} rows across ${unmatched_customers.length} customers` : undefined}
          />
          <SummaryCard label="Duplicates" value={summary.duplicates} />
          <SummaryCard
            label="Revenue"
            value={`$${summary.total_revenue.toLocaleString(undefined, { minimumFractionDigits: 2 })}`}
            isText
          />
        </div>
      </div>
    </>
  );
}

// ---------------------------------------------------------------------------
// Footer — submit button + unmatched-NULL warnings
// ---------------------------------------------------------------------------

export function ImportPreviewFormFooter() {
  const {
    assignedSkuCount,
    assignedCustomerCount,
    effectiveImportCount,
    importing,
    readyToImport,
    handleConfirm,
    unmatched_skus,
    unmatched_customers,
  } = useImportPreviewContext();

  return (
    <div className="flex items-center gap-4">
      <button
        onClick={handleConfirm}
        disabled={!readyToImport || importing}
        className={`px-6 py-2.5 rounded-lg text-xs font-medium transition-colors ${
          readyToImport && !importing
            ? 'bg-[#931220] text-white hover:bg-[#7a0f1a]'
            : 'bg-[#FAF9F7] border border-[#D8D9DA] text-[#505052] cursor-not-allowed'
        }`}
        style={font}
      >
        {importing ? (
          <span className="flex items-center gap-2">
            <span className="w-3.5 h-3.5 border-2 border-white border-t-transparent rounded-full animate-spin" />
            Importing...
          </span>
        ) : (
          `Import ${effectiveImportCount} rows`
        )}
      </button>

      {unmatched_skus.length > 0 && assignedSkuCount < unmatched_skus.length && (
        <span className="text-[10px] text-amber-700" style={font}>
          {unmatched_skus.length - assignedSkuCount} unmatched SKU{unmatched_skus.length - assignedSkuCount !== 1 ? 's' : ''} will import with sku_id=NULL
        </span>
      )}
      {unmatched_customers.length > 0 && assignedCustomerCount < unmatched_customers.length && (
        <span className="text-[10px] text-amber-700" style={font}>
          {unmatched_customers.length - assignedCustomerCount} unmatched customer{unmatched_customers.length - assignedCustomerCount !== 1 ? 's' : ''} will import with customer_id=NULL
        </span>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Modals — create-new-customer + create-new-rep dialogs
// ---------------------------------------------------------------------------

export function ImportPreviewFormModals() {
  const {
    createForExternal,
    setCreateForExternal,
    handleCreateCustomer,
    newCustName,
    setNewCustName,
    newCustSuburb,
    setNewCustSuburb,
    newCustPostcode,
    setNewCustPostcode,
    newCustRep,
    setNewCustRep,
    newCustTerritory,
    setNewCustTerritory,
    newCustGroup,
    setNewCustGroup,
    newCustPremise,
    setNewCustPremise,
    newCustSaving,
    refTerritories,
    refGroups,
    refReps,
    createRepForName,
    setCreateRepForName,
    handleCreateRep,
    newRepName,
    setNewRepName,
    newRepTerritory,
    setNewRepTerritory,
    newRepSaving,
  } = useImportPreviewContext();

  // JF-24: Auto-populate postcode when suburb is entered
  const lookupPostcode = useCallback(async (suburb: string) => {
    if (!suburb || suburb.trim().length < 2) return;
    try {
      const res = await apiGet(`/api/suburb-postcode?suburb=${encodeURIComponent(suburb.trim())}`);
      const data = await res.json();
      if (data.results && data.results.length > 0) {
        // Use the first result (Delivery Area preferred by API)
        setNewCustPostcode(data.results[0].postcode);
      }
    } catch {
      // Silent fail — postcode is optional, user can type manually
    }
  }, [setNewCustPostcode]);

  return (
    <>
      {/* Create New Customer Modal */}
      {createForExternal && (
        <div className="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
          <div className="bg-white rounded-xl border border-[#D8D9DA] p-6 w-full max-w-md shadow-xl">
            <h3 className="text-sm font-semibold text-[#1F1F1F] mb-4" style={headingFont}>
              Create New Customer
            </h3>
            <p className="text-[10px] text-[#505052] mb-4" style={font}>
              For: <span className="font-medium text-[#1F1F1F]">{createForExternal}</span>
            </p>

            <div className="space-y-3">
              <div>
                <label className="text-[10px] text-[#505052] block mb-1" style={font}>Customer Name *</label>
                <input
                  type="text"
                  value={newCustName}
                  onChange={(e) => setNewCustName(e.target.value)}
                  className="w-full bg-white border border-[#D8D9DA] rounded-lg px-3 py-1.5 text-xs text-[#1F1F1F] focus:border-[#931220] focus:outline-none"
                  style={font}
                />
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="text-[10px] text-[#505052] block mb-1" style={font}>Suburb</label>
                  <input
                    type="text"
                    value={newCustSuburb}
                    onChange={(e) => setNewCustSuburb(e.target.value)}
                    onBlur={(e) => lookupPostcode(e.target.value)}
                    placeholder="e.g. Bungendore"
                    className="w-full bg-white border border-[#D8D9DA] rounded-lg px-3 py-1.5 text-xs text-[#1F1F1F] focus:border-[#931220] focus:outline-none"
                    style={font}
                  />
                </div>
                <div>
                  <label className="text-[10px] text-[#505052] block mb-1" style={font}>Postcode</label>
                  <input
                    type="text"
                    value={newCustPostcode}
                    onChange={(e) => setNewCustPostcode(e.target.value)}
                    placeholder="e.g. 2621"
                    className="w-full bg-white border border-[#D8D9DA] rounded-lg px-3 py-1.5 text-xs text-[#1F1F1F] focus:border-[#931220] focus:outline-none"
                    style={font}
                  />
                </div>
              </div>

              <div>
                <label className="text-[10px] text-[#505052] block mb-1" style={font}>Rep * <span className="text-[#931220]">(required)</span></label>
                <select
                  value={newCustRep || ''}
                  onChange={(e) => {
                    const repId = e.target.value ? Number(e.target.value) : null;
                    setNewCustRep(repId);
                    // F24: Auto-cascade rep → territory
                    if (repId) {
                      const rep = refReps.find(r => r.id === repId) as { id: number; name: string; territory_id?: number | null } | undefined;
                      if (rep?.territory_id) setNewCustTerritory(rep.territory_id);
                    }
                  }}
                  className="w-full bg-white border border-[#D8D9DA] rounded-lg px-3 py-1.5 text-xs text-[#1F1F1F] focus:border-[#931220] focus:outline-none"
                  style={font}
                >
                  <option value="">Select rep...</option>
                  {refReps.map(r => (
                    <option key={r.id} value={r.id}>{r.name}</option>
                  ))}
                </select>
              </div>

              <div>
                {/* BUG-80: territory is optional on new-customer create — DB allows NULL,
                    and the rep-create modal below also allows NULL territory. Keeping
                    both modals aligned so the new-rep → new-customer upload flow works
                    without forcing a territory guess. */}
                <label className="text-[10px] text-[#505052] block mb-1" style={font}>Territory</label>
                <select
                  value={newCustTerritory || ''}
                  onChange={(e) => setNewCustTerritory(e.target.value ? Number(e.target.value) : null)}
                  className="w-full bg-white border border-[#D8D9DA] rounded-lg px-3 py-1.5 text-xs text-[#1F1F1F] focus:border-[#931220] focus:outline-none"
                  style={font}
                >
                  <option value="">Select territory...</option>
                  {refTerritories.map(t => (
                    <option key={t.id} value={t.id}>{t.name}</option>
                  ))}
                </select>
              </div>

              <div>
                <label className="text-[10px] text-[#505052] block mb-1" style={font}>Customer Group</label>
                <input
                  type="text"
                  value={newCustGroup}
                  onChange={(e) => setNewCustGroup(e.target.value)}
                  list="customer-groups"
                  placeholder="e.g. LIQUOR LEGENDS, IGA LIQUOR..."
                  className="w-full bg-white border border-[#D8D9DA] rounded-lg px-3 py-1.5 text-xs text-[#1F1F1F] focus:border-[#931220] focus:outline-none"
                  style={font}
                />
                <datalist id="customer-groups">
                  {refGroups.map(g => <option key={g} value={g} />)}
                </datalist>
              </div>

              <div>
                <label className="text-[10px] text-[#505052] block mb-1" style={font}>Channel</label>
                <select
                  value={newCustPremise}
                  onChange={(e) => setNewCustPremise(e.target.value)}
                  className="w-full bg-white border border-[#D8D9DA] rounded-lg px-3 py-1.5 text-xs text-[#1F1F1F] focus:border-[#931220] focus:outline-none"
                  style={font}
                >
                  <option value="On Premise">On Premise</option>
                  <option value="Off Premise">Off Premise</option>
                  <option value="Other">Other</option>
                </select>
              </div>
            </div>

            <div className="flex items-center justify-end gap-2 mt-5">
              <button
                onClick={() => setCreateForExternal(null)}
                className="px-4 py-1.5 rounded-lg text-xs text-[#505052] bg-[#FAF9F7] border border-[#D8D9DA] hover:bg-white"
                style={font}
              >
                Cancel
              </button>
              <button
                onClick={handleCreateCustomer}
                disabled={!newCustName.trim() || !newCustRep || newCustSaving}
                className={`px-4 py-1.5 rounded-lg text-xs font-medium transition-colors ${
                  newCustName.trim() && newCustRep && !newCustSaving
                    ? 'bg-[#931220] text-white hover:bg-[#7a0f1a]'
                    : 'bg-[#FAF9F7] border border-[#D8D9DA] text-[#505052] cursor-not-allowed'
                }`}
                style={font}
              >
                {newCustSaving ? 'Creating...' : 'Create & Assign'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* JF-26: Create New SKU Modal removed — SKUs only originate in Vinsight. */}

      {/* JF-14: Create New Rep Modal */}
      {createRepForName && (
        <div className="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
          <div className="bg-white rounded-xl border border-[#D8D9DA] p-6 w-full max-w-sm shadow-xl">
            <h3 className="text-sm font-semibold text-[#1F1F1F] mb-4" style={headingFont}>
              Create New Rep
            </h3>
            <p className="text-[10px] text-[#505052] mb-4" style={font}>
              From DWS data: <span className="font-medium text-[#1F1F1F]">{createRepForName}</span>
            </p>

            <div className="space-y-3">
              <div>
                <label className="text-[10px] text-[#505052] block mb-1" style={font}>Rep Name *</label>
                <input
                  type="text"
                  value={newRepName}
                  onChange={(e) => setNewRepName(e.target.value)}
                  className="w-full bg-white border border-[#D8D9DA] rounded-lg px-3 py-1.5 text-xs text-[#1F1F1F] focus:border-[#931220] focus:outline-none"
                  style={font}
                />
              </div>

              <div>
                <label className="text-[10px] text-[#505052] block mb-1" style={font}>Territory</label>
                <select
                  value={newRepTerritory || ''}
                  onChange={(e) => setNewRepTerritory(e.target.value ? Number(e.target.value) : null)}
                  className="w-full bg-white border border-[#D8D9DA] rounded-lg px-3 py-1.5 text-xs text-[#1F1F1F] focus:border-[#931220] focus:outline-none"
                  style={font}
                >
                  <option value="">Select territory...</option>
                  {refTerritories.map(t => (
                    <option key={t.id} value={t.id}>{t.name}</option>
                  ))}
                </select>
              </div>
            </div>

            <div className="flex items-center justify-end gap-2 mt-5">
              <button
                onClick={() => setCreateRepForName(null)}
                className="px-4 py-1.5 rounded-lg text-xs text-[#505052] bg-[#FAF9F7] border border-[#D8D9DA] hover:bg-white"
                style={font}
              >
                Cancel
              </button>
              <button
                onClick={handleCreateRep}
                disabled={!newRepName.trim() || newRepSaving}
                className={`px-4 py-1.5 rounded-lg text-xs font-medium transition-colors ${
                  newRepName.trim() && !newRepSaving
                    ? 'bg-[#931220] text-white hover:bg-[#7a0f1a]'
                    : 'bg-[#FAF9F7] border border-[#D8D9DA] text-[#505052] cursor-not-allowed'
                }`}
                style={font}
              >
                {newRepSaving ? 'Creating...' : 'Create Rep'}
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}

// Default export: a composite for callers that want the whole thing.
// The shell (ImportPreview.tsx) uses the named pieces instead because it
// needs to interleave Overrides/Table between header and footer.
export default function ImportPreviewForm() {
  return (
    <>
      <ImportPreviewFormHeader />
      <ImportPreviewFormFooter />
      <ImportPreviewFormModals />
    </>
  );
}
