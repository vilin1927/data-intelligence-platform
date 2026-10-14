'use client';

// ---------------------------------------------------------------------------
// ImportPreviewContext
// ---------------------------------------------------------------------------
// BUG-22: DASH-07 refactor. Previously ImportPreview.tsx was a single 1,430-line
// component with 22+ useState calls. This context owns all of that state and
// exposes it to the four sub-components (Form / Table / Overrides / Results)
// via useImportPreviewContext(). Behaviour is intentionally byte-identical to
// the pre-split component — this file is a pure move, not a rewrite.
// ---------------------------------------------------------------------------

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react';
import { apiPost, apiGet } from '@/lib/api';

// ---------------------------------------------------------------------------
// Shared types (public, re-used by all sub-components)
// ---------------------------------------------------------------------------

export interface PreviewRow {
  row_num: number;
  raw_sku: string;
  raw_customer: string;
  sale_date: string | null;
  quantity: number | null;
  unit_price: number | null;
  discount: number;
  rebate: number;
  net_revenue: number | null;
  source_ref: string;
  sku_id: number | null;
  sku_name: string | null;
  customer_id: number | null;
  customer_name: string | null;
  is_duplicate: boolean;
  is_sample?: boolean;
  match_method?: 'code' | 'saved' | 'name' | '';
  status: 'matched' | 'unmatched' | 'duplicate' | 'error';
  errors: string[];
}

export interface SkuSuggestion {
  sku_id: number;
  sku_code: string;
  description: string;
  canonical_name: string | null;
  score: number;
}

export interface UnmatchedSku {
  external_code: string;
  description?: string;
  row_count: number;
  total_revenue: number;
  suggestions?: SkuSuggestion[];
}

// F4 (May 10): per-rep transaction sample row. Surfaced inside UnmatchedRep
// expanded view so Vladimir/the owner can sanity-check rep→territory before
export interface UnmatchedRepSampleRow {
  customer_name: string;
  suburb: string;
  sku_or_description: string;
  qty: number;
  total_amount: number;
}

export interface UnmatchedRep {
  rep_name: string;
  meta_territory: string;
  row_count: number;
  // F4: drill-down fields. All optional — older preview payloads (cached
  // from a previous deploy) won't include them, in which case the panel
  // gracefully falls back to the original 3-field collapsed render.
  customers?: string[];                  // up to 20 distinct names
  customers_count_total?: number;
  transactions_count?: number;           // == row_count, surfaced separately for clarity
  distinct_suburbs?: string[];           // up to 10 distinct suburbs
  suburbs_count_total?: number;
  sample_rows?: UnmatchedRepSampleRow[]; // up to 5 sample transactions
}

export interface CustomerSuggestion {
  customer_id: number;
  display_name: string;
  score: number;
  // B8 (May 8 / Apr 13 loop): extra context so the picker UI can show
  // suburb + state + channel inline — the owner flagged Customer 106
  // collapsing to wrong matches because the suggestion list lacked locale
  // disambiguation. All fields optional for backward compatibility with
  // older preview payloads.
  suburb?: string;
  postcode?: string;
  state?: string;
  channel?: string;
}

export interface UnmatchedCustomer {
  external_name: string;
  external_code?: string;
  row_count: number;
  total_revenue: number;
  is_sample?: boolean;
  meta_territory?: string;
  meta_rep?: string;
  meta_group?: string;
  meta_category?: string;
  meta_suburb?: string;
  meta_postcode?: string;
  suggestions?: CustomerSuggestion[];
}

export interface SkuOption {
  sku_id: number;
  sku_code: string;
  description: string;
  canonical_name: string | null;
  variety?: string;
  region?: string;
}

export interface CustomerOption {
  customer_id: number;
  customer_name: string;
  display_name?: string;
  suburb?: string;
  territory?: string;
  rep?: string;
  canonical_customer_id?: number | null;
}

export interface PreviewData {
  success: boolean;
  channel: string;
  file: string;
  saved_path: string;
  summary: {
    total_rows: number;
    matched: number;
    unmatched: number;
    duplicates: number;
    errors: number;
    total_revenue: number;
    sample_rows?: number;
    matched_by_code?: number;
    matched_by_saved?: number;
    matched_by_name?: number;
  };
  unmatched_skus: UnmatchedSku[];
  unmatched_customers: UnmatchedCustomer[];
  unmatched_reps?: UnmatchedRep[];
  customer_suggestions?: Record<string, CustomerSuggestion[]>;
  sku_suggestions?: Record<string, SkuSuggestion[]>;
  sku_list: SkuOption[];
  customer_list: CustomerOption[];
  rows: PreviewRow[];
}

export interface ImportResult {
  success: boolean;
  rows_imported?: number;
  rows_skipped?: number;
  errors?: string[];
  error?: string;
  cogs_assigned?: { total: number; vintage_matched: number; fallback: number };
  // BUG-10: structured post-import confirmation payload
  confirmation?: {
    total_rows: number;
    imported: number;
    skipped: { count: number; rows: { row_index: number; reason: string }[] };
    new_customers: { count: number; names: string[] };
    new_sku_matches: { count: number; codes: string[] };
    new_reps: { count: number };
    null_sku_rows: number;
    null_customer_rows: number;
    upload_id_min: number | null;
    upload_id_max: number | null;
  } | null;
}

export const font = { fontFamily: 'Inter, system-ui, sans-serif' };
export const headingFont = { fontFamily: 'Cardo, serif' };

// ---------------------------------------------------------------------------
// Context shape
// ---------------------------------------------------------------------------

interface ImportPreviewContextValue {
  // Original props
  data: PreviewData;
  onReset: () => void;

  // Derived references to common data slices
  summary: PreviewData['summary'];
  unmatched_skus: UnmatchedSku[];
  unmatched_customers: UnmatchedCustomer[];
  rows: PreviewRow[];

  // Assignments
  skuAssignments: Record<string, number>;
  setSkuAssignments: React.Dispatch<React.SetStateAction<Record<string, number>>>;
  customerAssignments: Record<string, number>;
  setCustomerAssignments: React.Dispatch<React.SetStateAction<Record<string, number>>>;
  assignedSkuCount: number;
  assignedCustomerCount: number;

  // Import flow
  importing: boolean;
  importResult: ImportResult | null;
  handleConfirm: () => Promise<void>;

  // Search state (per-row picker inputs)
  skuSearch: Record<string, string>;
  setSkuSearch: React.Dispatch<React.SetStateAction<Record<string, string>>>;
  customerSearch: Record<string, string>;
  setCustomerSearch: React.Dispatch<React.SetStateAction<Record<string, string>>>;
  skuPickerOpen: Record<string, boolean>;
  setSkuPickerOpen: React.Dispatch<React.SetStateAction<Record<string, boolean>>>;
  getFilteredSkus: (search: string) => SkuOption[];
  getFilteredCustomers: (search: string) => CustomerOption[];

  // Row preview
  showAllRows: boolean;
  setShowAllRows: React.Dispatch<React.SetStateAction<boolean>>;
  rowSearch: string;
  setRowSearch: React.Dispatch<React.SetStateAction<string>>;
  displayRows: PreviewRow[];
  effectiveImportCount: number;
  readyToImport: boolean;

  // Manual unmatch (from row table -> overrides)
  unmatchedOverrides: Set<string>;
  setUnmatchedOverrides: React.Dispatch<React.SetStateAction<Set<string>>>;
  unmatchedSkuOverrides: Set<string>;
  setUnmatchedSkuOverrides: React.Dispatch<React.SetStateAction<Set<string>>>;

  // Toast
  toast: string | null;
  setToast: React.Dispatch<React.SetStateAction<string | null>>;

  // Row exclusion
  excludedRows: Set<number>;
  autoExcludedRows: Set<number>;
  excludeReasons: Record<number, string>;
  toggleRowExclusion: (rowNum: number) => void;

  // Create New Customer modal
  createForExternal: string | null;
  setCreateForExternal: React.Dispatch<React.SetStateAction<string | null>>;
  openCreateCustomer: (externalName: string) => void;
  handleCreateCustomer: () => Promise<void>;
  newCustName: string;
  setNewCustName: React.Dispatch<React.SetStateAction<string>>;
  newCustSuburb: string;
  setNewCustSuburb: React.Dispatch<React.SetStateAction<string>>;
  newCustPostcode: string;
  setNewCustPostcode: React.Dispatch<React.SetStateAction<string>>;
  newCustRep: number | null;
  setNewCustRep: React.Dispatch<React.SetStateAction<number | null>>;
  newCustTerritory: number | null;
  setNewCustTerritory: React.Dispatch<React.SetStateAction<number | null>>;
  newCustGroup: string;
  setNewCustGroup: React.Dispatch<React.SetStateAction<string>>;
  newCustPremise: string;
  setNewCustPremise: React.Dispatch<React.SetStateAction<string>>;
  newCustSaving: boolean;

  // Reference data for forms
  refTerritories: Array<{ id: number; name: string; state?: string }>;
  refGroups: string[];
  refReps: Array<{ id: number; name: string }>;

  // Create New Rep modal
  createRepForName: string | null;
  setCreateRepForName: React.Dispatch<React.SetStateAction<string | null>>;
  openCreateRep: (repName: string, metaTerritory: string) => void;
  handleCreateRep: () => Promise<void>;
  newRepName: string;
  setNewRepName: React.Dispatch<React.SetStateAction<string>>;
  newRepTerritory: number | null;
  setNewRepTerritory: React.Dispatch<React.SetStateAction<number | null>>;
  newRepSaving: boolean;
  createdReps: Record<string, number>;

  // Persistence helper (used inline by SKU / customer pickers)
  persistMatch: (
    type: 'customer' | 'sku',
    externalCode: string,
    internalId: number,
    customerExternalCode?: string,
  ) => Promise<void>;
}

const ImportPreviewContext = createContext<ImportPreviewContextValue | null>(null);

export function useImportPreviewContext(): ImportPreviewContextValue {
  const ctx = useContext(ImportPreviewContext);
  if (!ctx) {
    throw new Error('useImportPreviewContext must be used inside <ImportPreviewProvider>');
  }
  return ctx;
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

export function ImportPreviewProvider({
  data,
  onReset,
  children,
}: {
  data: PreviewData;
  onReset: () => void;
  children: ReactNode;
}) {
  const [skuAssignments, setSkuAssignments] = useState<Record<string, number>>({});
  const [customerAssignments, setCustomerAssignments] = useState<Record<string, number>>({});
  const [importing, setImporting] = useState(false);
  const [importResult, setImportResult] = useState<ImportResult | null>(null);
  const [skuSearch, setSkuSearch] = useState<Record<string, string>>({});
  const [customerSearch, setCustomerSearch] = useState<Record<string, string>>({});
  const [showAllRows, setShowAllRows] = useState(true);
  const [rowSearch, setRowSearch] = useState('');
  const [unmatchedOverrides, setUnmatchedOverrides] = useState<Set<string>>(new Set());
  const [unmatchedSkuOverrides, setUnmatchedSkuOverrides] = useState<Set<string>>(new Set());
  const [toast, setToast] = useState<string | null>(null);

  // Create New Customer state
  const [createForExternal, setCreateForExternal] = useState<string | null>(null);
  const [newCustName, setNewCustName] = useState('');
  const [newCustSuburb, setNewCustSuburb] = useState('');
  const [newCustPostcode, setNewCustPostcode] = useState('');
  const [newCustRep, setNewCustRep] = useState<number | null>(null);
  const [newCustTerritory, setNewCustTerritory] = useState<number | null>(null);
  const [newCustGroup, setNewCustGroup] = useState('');
  const [newCustPremise, setNewCustPremise] = useState('On Premise');
  const [newCustSaving, setNewCustSaving] = useState(false);
  const [refTerritories, setRefTerritories] = useState<Array<{ id: number; name: string; state?: string }>>([]);
  const [refGroups, setRefGroups] = useState<string[]>([]);
  const [refReps, setRefReps] = useState<Array<{ id: number; name: string }>>([]);
  const [refLoaded, setRefLoaded] = useState(false);

  // JF-26: Browse-all toggle for the Vinsight SKU picker.
  // When the search input is focused (or user clicks the "Browse all" button),
  // the picker lists SKUs even with <2 chars typed so users can scroll the full
  // Vinsight catalogue. Create-new-SKU state was removed — SKUs now only
  // originate in Vinsight and must be matched, never created from the wizard.
  const [skuPickerOpen, setSkuPickerOpen] = useState<Record<string, boolean>>({});

  // JF-13: Row exclusion state
  // excludedRows contains ALL excluded rows (auto + manual). Used for effectiveImportCount
  // and the backend API call.
  // JF-20: autoExcludedRows tracks rows excluded by business rules (e.g. ALM warehouse on DWS).
  // Manually excluded = excludedRows \ autoExcludedRows.
  const [excludedRows, setExcludedRows] = useState<Set<number>>(new Set());
  const [autoExcludedRows, setAutoExcludedRows] = useState<Set<number>>(new Set());
  const [excludeReasons, setExcludeReasons] = useState<Record<number, string>>({});

  // JF-14: Create New Rep state
  const [createRepForName, setCreateRepForName] = useState<string | null>(null);
  const [newRepName, setNewRepName] = useState('');
  const [newRepTerritory, setNewRepTerritory] = useState<number | null>(null);
  const [newRepSaving, setNewRepSaving] = useState(false);
  const [createdReps, setCreatedReps] = useState<Record<string, number>>({});

  // Persist a match to the database so it survives import failures and re-uploads.
  // For customers, also saves the external_code mapping (e.g. DWS customer code) if available.
  const persistMatch = useCallback(
    async (type: 'customer' | 'sku', externalCode: string, internalId: number, customerExternalCode?: string) => {
      try {
        await apiPost('/api/upload/save-match', {
          type,
          source_system: data.channel,
          external_code: externalCode,
          internal_id: internalId,
        });
        // For customers with a separate external_code (DWS customer codes), save that mapping too
        if (type === 'customer' && customerExternalCode) {
          await apiPost('/api/upload/save-match', {
            type: 'customer',
            source_system: data.channel,
            external_code: customerExternalCode,
            internal_id: internalId,
          });
        }
      } catch (err) {
        console.error(`[ImportPreview] Failed to persist ${type} match:`, err);
        // Non-fatal: match is still in React state for this session
      }
    },
    [data.channel],
  );

  const { summary, unmatched_skus: originalUnmatchedSkus, unmatched_customers: originalUnmatchedCustomers, rows } = data;

  // BUG-31: Merge manually unmatched SKUs into the unmatched list.
  // When a user unmatches an auto-matched SKU, pull pre-computed
  // suggestions from the sku_suggestions map so chips appear.
  const unmatched_skus = useMemo(() => {
    if (unmatchedSkuOverrides.size === 0) return originalUnmatchedSkus;
    const existing = new Set(originalUnmatchedSkus.map(s => s.external_code));
    const extras: typeof originalUnmatchedSkus = [];
    const suggestionsMap = data.sku_suggestions || {};
    Array.from(unmatchedSkuOverrides).forEach(skuCode => {
      if (!existing.has(skuCode)) {
        const skuRows = rows.filter(r => r.raw_sku === skuCode);
        extras.push({
          external_code: skuCode,
          description: skuRows[0]?.sku_name || '',
          row_count: skuRows.length,
          total_revenue: skuRows.reduce((s, r) => s + (r.net_revenue || 0), 0),
          suggestions: suggestionsMap[skuCode] || [],
        });
      }
    });
    return [...originalUnmatchedSkus, ...extras];
  }, [originalUnmatchedSkus, unmatchedSkuOverrides, rows, data.sku_suggestions]);

  // Merge manually unmatched customers into the unmatched list.
  // When a user unmatches an auto-matched customer, pull pre-computed
  // suggestions from the customer_suggestions map so chips appear.
  const unmatched_customers = useMemo(() => {
    if (unmatchedOverrides.size === 0) return originalUnmatchedCustomers;
    const existing = new Set(originalUnmatchedCustomers.map(c => c.external_name));
    const extras: typeof originalUnmatchedCustomers = [];
    const suggestionsMap = data.customer_suggestions || {};
    Array.from(unmatchedOverrides).forEach(custName => {
      if (!existing.has(custName)) {
        const custRows = rows.filter(r => r.raw_customer === custName);
        extras.push({
          external_name: custName,
          external_code: '',
          row_count: custRows.length,
          total_revenue: custRows.reduce((s, r) => s + (r.net_revenue || 0), 0),
          suggestions: suggestionsMap[custName] || [],
        });
      }
    });
    return [...originalUnmatchedCustomers, ...extras];
  }, [originalUnmatchedCustomers, unmatchedOverrides, rows, data.customer_suggestions]);

  // Load reference data for Create New Customer / Create New Rep forms.
  // JF-26: Variety/region no longer loaded — Create-New-SKU path was removed.
  useEffect(() => {
    if (!refLoaded && (unmatched_customers.length > 0 || unmatched_skus.length > 0)) {
      apiGet('/api/reference').then(r => r.json()).then(d => {
        setRefTerritories(d.territories || []);
        setRefGroups(d.groups || []);
        setRefReps(d.reps || []);
        setRefLoaded(true);
      }).catch(() => {});
    }
  }, [refLoaded, unmatched_customers.length, unmatched_skus.length]);

  // JF-13: Auto-exclude ALM warehouse rows from DWS imports
  // JF-20: Track auto-excluded rows separately from manually excluded rows
  useEffect(() => {
    if (data.channel === 'dws') {
      const almPrefixes = ['ALM '];
      const autoExcluded = new Set<number>();
      const reasons: Record<number, string> = {};
      rows.forEach(row => {
        if (row.raw_customer && almPrefixes.some(p => row.raw_customer.toUpperCase().startsWith(p))) {
          autoExcluded.add(row.row_num);
          reasons[row.row_num] = 'ALM warehouse — auto-excluded by business rule';
        }
      });
      if (autoExcluded.size > 0) {
        setAutoExcludedRows(autoExcluded);
        setExcludedRows(prev => {
          const next = new Set(Array.from(prev));
          autoExcluded.forEach(n => next.add(n));
          return next;
        });
        setExcludeReasons(prev => ({ ...prev, ...reasons }));
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const openCreateCustomer = useCallback(
    (externalName: string) => {
      setCreateForExternal(externalName);
      setNewCustName(externalName);

      // F5: Pre-fill from DWS metadata if available
      const cust = unmatched_customers.find(c => c.external_name === externalName);
      const metaTerritory = cust?.meta_territory || '';
      const metaRep = cust?.meta_rep || '';

      // Match territory name or state code to dropdown ID
      const matchedTerritory = metaTerritory
        ? refTerritories.find(t =>
            t.name.toLowerCase() === metaTerritory.toLowerCase() ||
            (t.state && t.state.toLowerCase() === metaTerritory.toLowerCase())
          )
        : null;
      setNewCustTerritory(matchedTerritory?.id ?? null);

      // Match rep name to dropdown ID
      const matchedRep = metaRep
        ? refReps.find(r => r.name.toLowerCase() === metaRep.toLowerCase())
        : null;
      setNewCustRep(matchedRep?.id ?? null);

      setNewCustSuburb(cust?.meta_suburb || '');
      setNewCustPostcode(cust?.meta_postcode || '');
      setNewCustGroup(cust?.meta_group || '');
      // F25: Pre-fill premise from DWS category
      const cat = cust?.meta_category?.toLowerCase() || '';
      setNewCustPremise(cat.includes('off') ? 'Off Premise' : 'On Premise');
    },
    [unmatched_customers, refTerritories, refReps],
  );

  const handleCreateCustomer = useCallback(async () => {
    // BUG-80: territory is optional — POST /api/customers already allows NULL
    // territory_id, and the rep-create modal below also allows NULL territory.
    // Blocking here just reproduced the owner's "select territory error" on
    // new-rep DWS uploads.
    if (!createForExternal || !newCustName.trim() || !newCustRep) return;
    setNewCustSaving(true);
    try {
      const res = await apiPost('/api/customers', {
        name: newCustName.trim(),
        suburb: newCustSuburb || null,
        postcode: newCustPostcode || null,
        rep_id: newCustRep,
        territory_id: newCustTerritory || null,
        customer_group: newCustGroup || null,
        source_system: data.channel,
        external_name: createForExternal,
      });
      const result = await res.json();
      if (result.success || result.customer_id) {
        const custId = result.customer_id;
        setCustomerAssignments(prev => ({ ...prev, [createForExternal!]: custId }));
        setCreateForExternal(null);
      } else {
        alert(result.error || 'Failed to create customer');
      }
    } catch {
      alert('Network error creating customer');
    } finally {
      setNewCustSaving(false);
    }
  }, [createForExternal, newCustName, newCustSuburb, newCustPostcode, newCustRep, newCustTerritory, newCustGroup, data.channel]);

  // JF-26: openCreateSku / handleCreateSku removed — SKUs only originate in
  // Vinsight, the wizard can match to an existing sku but never create one.

  // JF-14: Rep creation handler
  const openCreateRep = useCallback(
    (repName: string, metaTerritory: string) => {
      setCreateRepForName(repName);
      setNewRepName(repName);
      const matchedTerritory = metaTerritory
        ? refTerritories.find(t =>
            t.name.toLowerCase() === metaTerritory.toLowerCase() ||
            (t.state && t.state.toLowerCase() === metaTerritory.toLowerCase())
          )
        : null;
      setNewRepTerritory(matchedTerritory?.id ?? null);
    },
    [refTerritories],
  );

  const handleCreateRep = useCallback(async () => {
    if (!createRepForName || !newRepName.trim()) return;
    setNewRepSaving(true);
    try {
      const res = await apiPost('/api/reps', {
        name: newRepName.trim(),
        territory_id: newRepTerritory,
      });
      const result = await res.json();
      if (result.success || result.rep_id) {
        setCreatedReps(prev => ({ ...prev, [createRepForName!]: result.rep_id }));
        // Also add to refReps so it's available in customer forms
        setRefReps(prev => [...prev, { id: result.rep_id, name: newRepName.trim() }]);
        setCreateRepForName(null);
      } else {
        alert(result.error || 'Failed to create rep');
      }
    } catch {
      alert('Network error creating rep');
    } finally {
      setNewRepSaving(false);
    }
  }, [createRepForName, newRepName, newRepTerritory]);

  // JF-13: Toggle row exclusion
  // JF-20: If the user re-includes an auto-excluded row, promote it out of
  // autoExcludedRows so it's no longer flagged as auto. Re-excluding later
  // will make it manual.
  const toggleRowExclusion = useCallback((rowNum: number) => {
    setExcludedRows(prev => {
      const next = new Set(Array.from(prev));
      if (next.has(rowNum)) {
        next.delete(rowNum);
      } else {
        next.add(rowNum);
      }
      return next;
    });
    setAutoExcludedRows(prev => {
      if (!prev.has(rowNum)) return prev;
      const next = new Set(Array.from(prev));
      next.delete(rowNum);
      return next;
    });
  }, []);

  const assignedSkuCount = Object.keys(skuAssignments).length;
  const assignedCustomerCount = Object.keys(customerAssignments).length;

  // Compute effective importable count: original matched (minus unmatched overrides) + newly resolved rows
  // JF-13: Subtract excluded rows
  // BUG-09 fix (2026-04-11): NULL-SKU rows WILL import with sku_id=NULL per the
  // amber warning's promise — do not gate on skuResolved here. The backend
  // confirm route preserves them (see null_sku_rows count in route.ts) and the
  // post-import card surfaces them to the user for later SKU mapping.
  const effectiveImportCount = useMemo(() => {
    return rows.filter(row => {
      if (excludedRows.has(row.row_num)) return false;
      if (row.status === 'duplicate' || row.status === 'error') return false;
      if (row.status === 'matched' && unmatchedOverrides.has(row.raw_customer)) return false;
      const custResolved = !row.raw_customer || row.customer_id !== null || customerAssignments[row.raw_customer];
      return custResolved;
    }).length;
    // skuAssignments listed to match pre-split dependency array exactly (the
    // original also referenced it here even though the body no longer reads
    // it after the BUG-09 fix). Pure-refactor rule: preserve behaviour incl.
    // any reactive re-computation triggered by skuAssignments changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rows, skuAssignments, customerAssignments, unmatchedOverrides, excludedRows]);

  const readyToImport = effectiveImportCount > 0;

  // JF-26: Fuzzy search across the full canonical Vinsight SKU list.
  // Returns up to 30 matches (exact substring first, then loose word-overlap)
  // when the user has typed something, otherwise the first 30 rows so the
  // user can scroll the full catalogue when they open the picker empty.
  const getFilteredSkus = useCallback(
    (search: string) => {
      if (!search || search.trim().length < 1) return data.sku_list.slice(0, 30);
      const q = search.toLowerCase().trim();
      const getText = (s: SkuOption) =>
        `${s.sku_code} ${s.description || ''} ${s.canonical_name || ''}`.toLowerCase();
      const exact = data.sku_list.filter(s => getText(s).includes(q));
      if (exact.length >= 8) return exact.slice(0, 30);
      const searchWords = q.split(/\s+/).filter(w => w.length >= 2);
      const fuzzy = searchWords.length === 0
        ? []
        : data.sku_list
            .filter(s => !getText(s).includes(q))
            .map(s => {
              const text = getText(s);
              const score = searchWords.reduce((acc, w) => acc + (text.includes(w) ? 1 : 0), 0) / searchWords.length;
              return { s, score };
            })
            .filter(x => x.score > 0.3)
            .sort((a, b) => b.score - a.score)
            .map(x => x.s);
      return [...exact, ...fuzzy].slice(0, 30);
    },
    [data.sku_list],
  );

  const getFilteredCustomers = useCallback(
    (search: string) => {
      // Search against display_name (NAME @ SUBURB) for better disambiguation.
      const getName = (c: CustomerOption) => (c.display_name || c.customer_name).toLowerCase();
      if (!search || search.length < 2) return data.customer_list.slice(0, 20);
      const lower = search.toLowerCase();
      // Exact substring matches first
      const exact = data.customer_list.filter(c => getName(c).includes(lower));
      if (exact.length >= 5) return exact.slice(0, 20);
      // Fuzzy: score each customer by word overlap
      const searchWords = lower.split(/\s+/).filter(w => w.length >= 2);
      const fuzzy = data.customer_list
        .filter(c => !getName(c).includes(lower))
        .map(c => {
          const name = getName(c);
          const score = searchWords.reduce((s, w) => s + (name.includes(w) ? 1 : 0), 0) / Math.max(searchWords.length, 1);
          return { ...c, _score: score };
        })
        .filter(c => c._score > 0.3)
        .sort((a, b) => b._score - a._score)
        .slice(0, 10 - exact.length);
      return [...exact.slice(0, 10), ...fuzzy].slice(0, 20);
    },
    [data.customer_list],
  );

  const displayRows = useMemo(() => {
    let filtered = rows;
    if (rowSearch.length >= 2) {
      const q = rowSearch.toLowerCase();
      filtered = rows.filter(r =>
        r.raw_sku?.toLowerCase().includes(q) ||
        r.sku_name?.toLowerCase().includes(q) ||
        r.raw_customer?.toLowerCase().includes(q) ||
        r.customer_name?.toLowerCase().includes(q) ||
        r.status.toLowerCase().includes(q) ||
        r.match_method?.toLowerCase().includes(q)
      );
    }
    if (showAllRows || rowSearch.length >= 2) return filtered;
    return filtered.slice(0, 100);
  }, [rows, showAllRows, rowSearch]);

  const handleConfirm = useCallback(async () => {
    setImporting(true);
    setImportResult(null);

    try {
      const overrides: { sku?: Record<string, number>; customer?: Record<string, number>; customer_code?: Record<string, number> } = {};
      if (Object.keys(skuAssignments).length > 0) overrides.sku = skuAssignments;
      if (Object.keys(customerAssignments).length > 0) overrides.customer = customerAssignments;

      // F2: When user assigns a customer, also save the code→customer mapping
      // so future imports match instantly by code.
      const customerCodeOverrides: Record<string, number> = {};
      for (const cust of unmatched_customers) {
        const assignedId = customerAssignments[cust.external_name];
        if (assignedId && cust.external_code) {
          customerCodeOverrides[cust.external_code] = assignedId;
        }
      }
      if (Object.keys(customerCodeOverrides).length > 0) overrides.customer_code = customerCodeOverrides;

      // BUG-03: Send unmatchedOverrides as null customer mappings
      // so backend knows to set customer_id=NULL for these rows
      Array.from(unmatchedOverrides).forEach(name => {
        if (!customerAssignments[name]) {
          if (!overrides.customer) overrides.customer = {};
          (overrides.customer as Record<string, number | null>)[name] = null;
        }
      });

      // BUG-31: Send unmatchedSkuOverrides as null sku mappings
      // so backend knows to set sku_id=NULL for these rows
      Array.from(unmatchedSkuOverrides).forEach(code => {
        if (!skuAssignments[code]) {
          if (!overrides.sku) overrides.sku = {};
          (overrides.sku as Record<string, number | null>)[code] = null;
        }
      });

      const res = await apiPost('/api/upload/confirm', {
        channel: data.channel,
        saved_path: data.saved_path,
        overrides: Object.keys(overrides).length > 0 ? overrides : undefined,
        excluded_rows: excludedRows.size > 0 ? Array.from(excludedRows) : undefined,
      });

      const result: ImportResult = await res.json();
      setImportResult(result);
    } catch (err) {
      setImportResult({
        success: false,
        error: err instanceof Error ? err.message : 'Import failed',
      });
    } finally {
      setImporting(false);
    }
  }, [skuAssignments, customerAssignments, unmatched_customers, unmatchedOverrides, unmatchedSkuOverrides, excludedRows, data.channel, data.saved_path]);

  const value: ImportPreviewContextValue = {
    data,
    onReset,
    summary,
    unmatched_skus,
    unmatched_customers,
    rows,
    skuAssignments,
    setSkuAssignments,
    customerAssignments,
    setCustomerAssignments,
    assignedSkuCount,
    assignedCustomerCount,
    importing,
    importResult,
    handleConfirm,
    skuSearch,
    setSkuSearch,
    customerSearch,
    setCustomerSearch,
    skuPickerOpen,
    setSkuPickerOpen,
    getFilteredSkus,
    getFilteredCustomers,
    showAllRows,
    setShowAllRows,
    rowSearch,
    setRowSearch,
    displayRows,
    effectiveImportCount,
    readyToImport,
    unmatchedOverrides,
    setUnmatchedOverrides,
    unmatchedSkuOverrides,
    setUnmatchedSkuOverrides,
    toast,
    setToast,
    excludedRows,
    autoExcludedRows,
    excludeReasons,
    toggleRowExclusion,
    createForExternal,
    setCreateForExternal,
    openCreateCustomer,
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
    openCreateRep,
    handleCreateRep,
    newRepName,
    setNewRepName,
    newRepTerritory,
    setNewRepTerritory,
    newRepSaving,
    createdReps,
    persistMatch,
  };

  return (
    <ImportPreviewContext.Provider value={value}>
      {children}
    </ImportPreviewContext.Provider>
  );
}

// ---------------------------------------------------------------------------
// Presentational helpers (shared between sub-components)
// ---------------------------------------------------------------------------

export function SummaryCard({ label, value, color = 'default', isText = false, subtitle }: {
  label: string; value: number | string; color?: 'green' | 'amber' | 'red' | 'default'; isText?: boolean; subtitle?: string;
}) {
  const colorMap = { green: 'text-green-700', amber: 'text-amber-700', red: 'text-[#931220]', default: 'text-[#1F1F1F]' };
  return (
    <div className="text-center">
      <div className={`text-lg font-semibold font-mono ${colorMap[color]}`}>
        {isText ? value : value.toLocaleString()}
      </div>
      <div className="text-[10px] text-[#505052]" style={font}>{label}</div>
      {subtitle && <div className="text-[9px] text-[#505052]/70 mt-0.5" style={font}>{subtitle}</div>}
    </div>
  );
}

export function StatusBadge({ status }: { status: string }) {
  const config: Record<string, { label: string; cls: string }> = {
    matched: { label: 'OK', cls: 'bg-green-100 text-green-700' },
    unmatched: { label: '?', cls: 'bg-amber-100 text-amber-700' },
    duplicate: { label: 'DUP', cls: 'bg-gray-100 text-gray-500' },
    error: { label: 'ERR', cls: 'bg-red-100 text-[#931220]' },
  };
  const c = config[status] || config.error;
  return <span className={`inline-block px-1.5 py-0.5 rounded text-[9px] font-semibold ${c.cls}`}>{c.label}</span>;
}
