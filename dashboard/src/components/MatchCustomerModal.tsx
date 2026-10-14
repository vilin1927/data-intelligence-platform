'use client';

/**
 * MatchCustomerModal
 *
 * "Add as new canonical customer" modal opened from /admin/unmatched-customers.
 * Pre-populated from the unmatched sales row (JC-370). 11 fields:
 *   customer_code, customer_name, suburb, postcode, address, group, rep,
 *   territory, warehouse, channel, state.
 *
 * Auto-fill rules:
 *   - Selecting a rep auto-assigns that rep's territory (editable) — JC-018, JC-371.
 *   - Typing a suburb auto-fills postcode + state from the AU postcode dataset — JC-019.
 *   - Address pre-fills from ALM EDI outlet_address when seed source is ALM
 *     (D1 schema/165). Non-ALM rows leave Address blank.
 *
 * Known limitations:
 *   - Rep field stays blank for ALM-sourced seeds: ALM EDI 5|2 line does not
 *     carry a sales-rep field. User picks rep manually. NOT a bug — genuine
 *     source-system gap.
 *
 * Apply emits `onApply(form)` to the parent. The actual POST that creates the
 * canonical_customer row is wired by the parent (or deferred to a follow-up
 * bundle if no endpoint exists).
 */

import { useEffect, useState, useCallback, useRef } from 'react';
import Modal from './Modal';
import Button from './Button';
import { apiGet, apiPost } from '@/lib/api';
import { lookupPostcodeBySuburb, searchSuburbs, SuburbEntry } from '@/lib/postcodeLookup';

// ─── Types ──────────────────────────────────────────────────────────────────

export interface MatchCustomerForm {
  customer_code: string;
  customer_name: string;
  suburb: string;
  postcode: string;
  address: string;  // D1 (schema/165): from ALM EDI outlet_address when seed is ALM
  group: string;
  rep_id: number | null;
  rep_name: string;
  territory_id: number | null;
  territory_name: string;
  warehouse: string;
  channel: string;
  state: string;
}

interface RepOption {
  id: number;
  name: string;
  territory_id: number | null;
  territory_name: string;
}

export interface UnmatchedRowSeed {
  customer_id: number;
  customer_name: string;
  suburb: string | null;
  postcode: string | null;
  address: string | null;          // D1 (schema/165): ALM EDI outlet_address
  source_system: string | null;   // → warehouse / channel hint
  territory_id: number | null;
}

interface MatchCustomerModalProps {
  isOpen: boolean;
  onClose: () => void;
  seed: UnmatchedRowSeed | null;
  onApply: (form: MatchCustomerForm) => Promise<void> | void;
}

const AU_STATES = ['NSW', 'VIC', 'QLD', 'SA', 'WA', 'TAS', 'NT', 'ACT'] as const;
const WAREHOUSES = ['DWS', 'ALM', 'Direct', 'ILG'] as const;
const CHANNELS = ['On-Premise', 'Off-Premise', 'Direct', 'Other'] as const;

// ─── Component ──────────────────────────────────────────────────────────────

export default function MatchCustomerModal({
  isOpen,
  onClose,
  seed,
  onApply,
}: MatchCustomerModalProps) {
  const [form, setForm] = useState<MatchCustomerForm>(emptyForm());
  const [reps, setReps] = useState<RepOption[]>([]);
  const [suburbSuggestions, setSuburbSuggestions] = useState<SuburbEntry[]>([]);
  const [showSuburbDropdown, setShowSuburbDropdown] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const subSearchTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  // JC-020: inline new-rep dialog state. Triggered when user picks
  // "+ Add new rep…" from the Rep <select>. POSTs to /api/reps, then
  // refreshes the local reps[] state and auto-selects the new id.
  const [showNewRepDialog, setShowNewRepDialog] = useState(false);
  const [newRepName, setNewRepName] = useState('');
  const [creatingRep, setCreatingRep] = useState(false);
  const [newRepError, setNewRepError] = useState<string | null>(null);

  // Pre-populate from seed when modal opens (JC-370, C3 ship-state matrix 2026-05-11)
  useEffect(() => {
    if (!isOpen) return;
    if (!seed) {
      setForm(emptyForm());
      return;
    }
    const seededSuburb = (seed.suburb ?? '').trim().toUpperCase();
    const lookup = seededSuburb ? lookupPostcodeBySuburb(seededSuburb) : null;
    setForm({
      customer_code: '',
      customer_name: seed.customer_name ?? '',
      suburb: seededSuburb,
      postcode: seed.postcode ?? lookup?.postcode ?? '',
      address: (seed.address ?? '').trim(),  // D1: blank for non-ALM rows
      group: '',
      rep_id: null,
      rep_name: '',
      territory_id: seed.territory_id ?? null,
      territory_name: '',
      warehouse: warehouseFromSource(seed.source_system),
      channel: channelFromSource(seed.source_system),
      state: lookup?.state ?? '',
    });
    setError(null);
  }, [isOpen, seed]);

  // C3 ship-state matrix 2026-05-11 — once reps load (or seed/reps change),
  // derive territory_name from seed.territory_id and auto-pick the rep when
  // exactly one canonical rep maps to that territory. Conservative defaults:
  // leave rep/territory blank if territory_id missing, no matching rep, or
  // ≥2 reps share the territory (don't guess — let user pick).
  useEffect(() => {
    if (!isOpen) return;
    if (!seed) return;
    if (reps.length === 0) return;
    const tid = seed.territory_id ?? null;
    if (tid == null) return;
    setForm(f => {
      // Don't clobber user edits — only fill if still blank.
      if (f.territory_name || f.rep_id != null) return f;
      const matches = reps.filter(r => r.territory_id === tid);
      const territoryName = matches[0]?.territory_name || '';
      // Auto-select rep ONLY when unambiguous (exactly one rep on this territory).
      if (matches.length === 1) {
        return {
          ...f,
          rep_id: matches[0].id,
          rep_name: matches[0].name,
          territory_id: matches[0].territory_id,
          territory_name: matches[0].territory_name,
        };
      }
      return { ...f, territory_name: territoryName };
    });
  }, [isOpen, seed, reps]);

  // Load reps on mount (canonical_representative — B5)
  useEffect(() => {
    if (!isOpen) return;
    let cancelled = false;
    (async () => {
      try {
        const res = await apiGet('/api/reps');
        if (!res.ok) return;
        const data = await res.json();
        if (cancelled) return;
        const opts: RepOption[] = (data.reps || []).map((r: {
          id: number;
          name: string;
          territory_id: number | null;
          territory_name: string;
        }) => ({
          id: r.id,
          name: r.name,
          territory_id: r.territory_id,
          territory_name: r.territory_name || '',
        }));
        setReps(opts);
      } catch {
        // ignore
      }
    })();
    return () => { cancelled = true; };
  }, [isOpen]);

  // Rep change → auto-fill territory (editable) — JC-018, JC-371
  const handleRepChange = useCallback((repId: number | null) => {
    if (repId == null) {
      setForm(f => ({ ...f, rep_id: null, rep_name: '', territory_id: null, territory_name: '' }));
      return;
    }
    const rep = reps.find(r => r.id === repId);
    if (!rep) return;
    setForm(f => ({
      ...f,
      rep_id: rep.id,
      rep_name: rep.name,
      // Auto-assign rep's default territory; user can edit if needed.
      territory_id: rep.territory_id,
      territory_name: rep.territory_name,
    }));
  }, [reps]);

  // JC-020: create a new rep without leaving the customer-add flow.
  // On success: append to reps[], auto-select the new rep on the form
  // (handleRepChange auto-fills territory if the new rep has one — here
  // it's a fresh rep so territory stays null until user edits or rep is
  // updated separately).
  const handleCreateNewRep = useCallback(async () => {
    const name = newRepName.trim();
    if (!name) {
      setNewRepError('Rep name is required');
      return;
    }
    setCreatingRep(true);
    setNewRepError(null);
    try {
      const res = await apiPost('/api/reps', { name });
      const data = await res.json();
      // 409 means the rep already exists — API returns existing rep_id; treat as success.
      if (res.status === 409 && data.rep_id) {
        const existing: RepOption = { id: data.rep_id, name, territory_id: null, territory_name: '' };
        setReps(prev => prev.find(r => r.id === existing.id) ? prev : [...prev, existing]);
        setForm(f => ({ ...f, rep_id: existing.id, rep_name: existing.name }));
        setShowNewRepDialog(false);
        setNewRepName('');
        return;
      }
      if (!res.ok || !data.rep_id) {
        setNewRepError(data.error || 'Failed to create rep');
        return;
      }
      const created: RepOption = { id: data.rep_id, name: data.rep_name || name, territory_id: null, territory_name: '' };
      setReps(prev => [...prev, created]);
      setForm(f => ({ ...f, rep_id: created.id, rep_name: created.name, territory_id: null, territory_name: '' }));
      setShowNewRepDialog(false);
      setNewRepName('');
    } catch {
      setNewRepError('Network error creating rep');
    } finally {
      setCreatingRep(false);
    }
  }, [newRepName]);

  // Suburb change → typeahead + auto-fill postcode + state — JC-019
  const handleSuburbChange = useCallback((value: string) => {
    const upper = value.toUpperCase();
    setForm(f => ({ ...f, suburb: upper }));
    if (subSearchTimer.current) clearTimeout(subSearchTimer.current);
    subSearchTimer.current = setTimeout(() => {
      const matches = searchSuburbs(upper, 8);
      setSuburbSuggestions(matches);
      setShowSuburbDropdown(matches.length > 0);
      // Direct exact match → auto-fill
      const exact = lookupPostcodeBySuburb(upper);
      if (exact) {
        setForm(f => ({
          ...f,
          suburb: exact.suburb,
          postcode: f.postcode || exact.postcode, // don't clobber if user already typed
          state: f.state || exact.state,
        }));
      }
    }, 200);
  }, []);

  const handlePickSuburb = (entry: SuburbEntry) => {
    setForm(f => ({
      ...f,
      suburb: entry.suburb,
      postcode: entry.postcode,
      state: entry.state,
    }));
    setShowSuburbDropdown(false);
  };

  const handleApply = async () => {
    setError(null);
    if (!form.customer_name.trim()) {
      setError('Customer name is required.');
      return;
    }
    if (!form.suburb.trim()) {
      setError('Suburb is required.');
      return;
    }
    setSubmitting(true);
    try {
      await onApply(form);
      onClose();
    } catch (e) {
      setError((e as Error).message || 'Apply failed.');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Add as new canonical customer"
      size="xl"
      footer={
        <>
          <Button variant="ghost" onClick={onClose} disabled={submitting}>
            Cancel
          </Button>
          <Button variant="primary" onClick={handleApply} loading={submitting}>
            Apply
          </Button>
        </>
      }
    >
      {seed && (
        <p className="text-xs text-gray-500 mb-3">
          Pre-populated from unmatched sales row{' '}
          <span className="font-mono">#{seed.customer_id}</span>. Adjust any field
          before applying — selecting a rep will auto-fill territory; typing a
          suburb will auto-fill postcode and state.
        </p>
      )}

      {error && (
        <div className="mb-3 px-3 py-2 rounded-lg bg-red-50 border border-red-200 text-red-700 text-sm">
          {error}
        </div>
      )}

      <div className="grid grid-cols-2 gap-x-4 gap-y-3">
        {/* 1. Customer code */}
        <Field label="Customer code">
          <input
            type="text"
            className="form-input"
            value={form.customer_code}
            placeholder="e.g. MOLKSH21F"
            onChange={e => setForm(f => ({ ...f, customer_code: e.target.value }))}
          />
        </Field>

        {/* 2. Customer name */}
        <Field label="Customer name *">
          <input
            type="text"
            className="form-input"
            value={form.customer_name}
            onChange={e => setForm(f => ({ ...f, customer_name: e.target.value }))}
          />
        </Field>

        {/* 3. Suburb (typeahead) */}
        <Field label="Suburb *">
          <div className="relative">
            <input
              type="text"
              className="form-input"
              value={form.suburb}
              onChange={e => handleSuburbChange(e.target.value)}
              onFocus={() => suburbSuggestions.length > 0 && setShowSuburbDropdown(true)}
              onBlur={() => setTimeout(() => setShowSuburbDropdown(false), 150)}
            />
            {showSuburbDropdown && suburbSuggestions.length > 0 && (
              <div className="absolute z-50 top-full left-0 right-0 mt-1 bg-white border border-gray-200 rounded-lg shadow-lg max-h-48 overflow-auto">
                {suburbSuggestions.map(s => (
                  <button
                    key={`${s.suburb}-${s.state}-${s.postcode}`}
                    type="button"
                    className="w-full text-left px-3 py-1.5 hover:bg-gray-50 text-sm"
                    onMouseDown={() => handlePickSuburb(s)}
                  >
                    <span className="font-medium">{s.suburb}</span>
                    <span className="text-gray-400 ml-2">{s.state} · {s.postcode}</span>
                  </button>
                ))}
              </div>
            )}
          </div>
        </Field>

        {/* 4. Postcode */}
        <Field label="Postcode" hint="Auto-filled from suburb">
          <input
            type="text"
            className="form-input"
            value={form.postcode}
            maxLength={4}
            onChange={e => setForm(f => ({ ...f, postcode: e.target.value }))}
          />
        </Field>

        {/* 5. Address — D1 (schema/165): pre-filled from ALM EDI outlet_address.
              Non-ALM seeds leave this blank. */}
        <Field label="Address" hint="Pre-filled from ALM source when available">
          <input
            type="text"
            className="form-input"
            value={form.address}
            placeholder="Street address"
            onChange={e => setForm(f => ({ ...f, address: e.target.value }))}
          />
        </Field>

        {/* 6. State */}
        <Field label="State">
          <select
            className="form-input"
            value={form.state}
            onChange={e => setForm(f => ({ ...f, state: e.target.value }))}
          >
            <option value="">—</option>
            {AU_STATES.map(s => <option key={s} value={s}>{s}</option>)}
          </select>
        </Field>

        {/* 7. Group */}
        <Field label="Group">
          <input
            type="text"
            className="form-input"
            value={form.group}
            placeholder="e.g. CELLARBRATIONS"
            onChange={e => setForm(f => ({ ...f, group: e.target.value }))}
          />
        </Field>

        {/* 8. Rep — JC-020: inline "+ Add new rep" creates without leaving the modal.
              D1 (2026-05-11): for ALM-sourced seeds, Rep starts blank because
              ALM EDI 5|2 line carries no sales-rep field. User picks manually.
              Known limitation — NOT a bug. */}
        <Field label="Rep">
          <select
            className="form-input"
            value={form.rep_id ?? ''}
            onChange={e => {
              if (e.target.value === '__new__') {
                setNewRepName('');
                setNewRepError(null);
                setShowNewRepDialog(true);
                return;
              }
              handleRepChange(e.target.value ? parseInt(e.target.value, 10) : null);
            }}
          >
            <option value="">— None —</option>
            {reps.map(r => (
              <option key={r.id} value={r.id}>{r.name}{r.territory_name ? ` · ${r.territory_name}` : ''}</option>
            ))}
            <option value="__new__">+ Add new rep…</option>
          </select>

          {showNewRepDialog && (
            <div className="mt-2 rounded-lg border border-[#D8D9DA] bg-[#FAF9F7] p-3 space-y-2">
              <div className="text-[11px] text-[#505052] font-medium">Create new rep</div>
              <input
                type="text"
                value={newRepName}
                onChange={e => setNewRepName(e.target.value)}
                placeholder="e.g. NATALIE HEDRICK"
                autoFocus
                className="w-full bg-white border border-[#D8D9DA] rounded-md px-2 py-1 text-xs text-[#1F1F1F] focus:border-[#931220] focus:outline-none"
                onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); handleCreateNewRep(); } }}
              />
              {newRepError && (
                <div className="text-[11px] text-[#931220]">{newRepError}</div>
              )}
              <div className="text-[10px] text-[#8A8A8D]">
                Territory left blank — set it later via Reps admin if needed.
              </div>
              <div className="flex items-center justify-end gap-2">
                <button
                  type="button"
                  onClick={() => { setShowNewRepDialog(false); setNewRepName(''); setNewRepError(null); }}
                  className="px-3 py-1 rounded-md text-[11px] text-[#505052] bg-white border border-[#D8D9DA] hover:bg-[#FAF9F7]"
                >
                  Cancel
                </button>
                <button
                  type="button"
                  onClick={handleCreateNewRep}
                  disabled={!newRepName.trim() || creatingRep}
                  className={`px-3 py-1 rounded-md text-[11px] font-medium ${
                    newRepName.trim() && !creatingRep
                      ? 'bg-[#931220] text-white hover:bg-[#7a0f1a]'
                      : 'bg-[#FAF9F7] border border-[#D8D9DA] text-[#505052] cursor-not-allowed'
                  }`}
                >
                  {creatingRep ? 'Creating…' : 'Create'}
                </button>
              </div>
            </div>
          )}
        </Field>

        {/* 9. Territory (editable) */}
        <Field label="Territory" hint="Auto-filled from rep; editable">
          <input
            type="text"
            className="form-input"
            value={form.territory_name}
            onChange={e => setForm(f => ({ ...f, territory_name: e.target.value, territory_id: null }))}
          />
        </Field>

        {/* 10. Warehouse */}
        <Field label="Warehouse">
          <select
            className="form-input"
            value={form.warehouse}
            onChange={e => setForm(f => ({ ...f, warehouse: e.target.value }))}
          >
            <option value="">—</option>
            {WAREHOUSES.map(w => <option key={w} value={w}>{w}</option>)}
          </select>
        </Field>

        {/* 11. Channel */}
        <Field label="Channel">
          <select
            className="form-input"
            value={form.channel}
            onChange={e => setForm(f => ({ ...f, channel: e.target.value }))}
          >
            <option value="">—</option>
            {CHANNELS.map(c => <option key={c} value={c}>{c}</option>)}
          </select>
        </Field>
      </div>

      {/* Local input style (shadcn-ish, matches Modal aesthetic) */}
      <style jsx>{`
        :global(.form-input) {
          width: 100%;
          padding: 0.375rem 0.625rem;
          border: 1px solid #d8d9da;
          border-radius: 0.5rem;
          font-size: 0.875rem;
          color: #1f1f1f;
          background-color: #ffffff;
        }
        :global(.form-input:focus) {
          outline: none;
          border-color: #3b82f6;
          box-shadow: 0 0 0 2px rgba(59, 130, 246, 0.2);
        }
      `}</style>
    </Modal>
  );
}

// ─── Helpers ────────────────────────────────────────────────────────────────

function emptyForm(): MatchCustomerForm {
  return {
    customer_code: '',
    customer_name: '',
    suburb: '',
    postcode: '',
    address: '',
    group: '',
    rep_id: null,
    rep_name: '',
    territory_id: null,
    territory_name: '',
    warehouse: '',
    channel: '',
    state: '',
  };
}

function warehouseFromSource(src: string | null): string {
  if (!src) return '';
  const u = src.toUpperCase();
  if (u.includes('DWS')) return 'DWS';
  if (u.includes('ALM')) return 'ALM';
  if (u.includes('DIRECT')) return 'Direct';
  if (u.includes('ILG')) return 'ILG';
  return '';
}

function channelFromSource(src: string | null): string {
  if (!src) return '';
  const u = src.toUpperCase();
  if (u.includes('DIRECT')) return 'Direct';
  // C3 ship-state matrix 2026-05-11: DWS + ALM default → Off-Premise per
  // backfill; 2026-04-29 ALM→OFF PREMISE re-map). User can flip in form.
  if (u.includes('DWS')) return 'Off-Premise';
  if (u.includes('ALM')) return 'Off-Premise';
  return '';
}

// ─── Sub-components ─────────────────────────────────────────────────────────

interface FieldProps {
  label: string;
  hint?: string;
  children: React.ReactNode;
}

function Field({ label, hint, children }: FieldProps) {
  return (
    <div>
      <label className="block text-xs font-semibold text-gray-600 mb-1">
        {label}
      </label>
      {children}
      {hint && <p className="mt-0.5 text-[11px] text-gray-400">{hint}</p>}
    </div>
  );
}
