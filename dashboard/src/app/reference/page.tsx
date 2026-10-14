'use client';

import { useEffect, useState, useCallback } from 'react';
import Link from 'next/link';
import { apiGet, apiPost, apiPut, apiDelete } from '@/lib/api';
import AppLayout from '@/components/AppLayout';
import Badge from '@/components/Badge';
import InfoTooltip from '@/components/InfoTooltip';
import {
  DollarSign,
  Plus,
  Pencil,
  Trash2,
  Save,
  X,
  RefreshCw,
  Users,
  Package,
  Search,
  ChevronRight,
  UserCog,
  Map as MapIcon,
  AlertTriangle,
  HelpCircle,
  Download,
} from 'lucide-react';

// ─── Types ───────────────────────────────────────────────────────────────

interface WholesalePrice {
  id: number;
  canonical_sku_id: number | null;
  sku_name: string;
  price_per_case: number;
  effective_from: string;
  effective_to: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
}

interface CanonicalSku {
  id: number;
  sku_name: string;
}

interface FormData {
  canonical_sku_id: number | null;
  sku_name: string;
  price_per_case: string;
  effective_from: string;
  effective_to: string;
  notes: string;
}

interface CustomerRow {
  id: number;
  canonical_id: number | null;
  name: string;
  group: string;
  suburb: string;
  postcode: string;
  channel: string;
  // BUG-127 / ADR-017: warehouse channel (DWS/ALM/Direct/null) — orthogonal to
  // venue type stored in `channel`. NULL when no signal (no sales activity AND
  // no canonical code OR ambiguous codes).
  warehouse_channel: string;
  territory: string;
  // B4 JC-003: TerritoryGroup column (Access master).
  territory_group: string;
  rep: string;
  // BUG-135: Owner-master canonical rep (joined from canonical_representative
  // via customer.canonical_rep_id — the Phase H / BUG-95 surface). Distinct
  // from `rep` which is the Access-side freetext on canonical_customer.rep_name.
  // Comma-separated when a canonical_customer spans satellites with different
  // canonical_rep_ids (rare).
  canonical_rep: string;
  canonical_rep_count: number;
  // B4 JC-003: master CustomerCode (Access).
  customer_code: string;
  // B4 JC-004: 5 channel cross-ref codes from canonical_customer (Access master).
  alm_customer_code: string;
  dir_customer_code: string;
  ilg_customer_code: string;
  ynr_customer_code: string;
  ynr_alm_customer_code: string;
  // B4 JC-008: distinct Notes (long form) + Remark (short status).
  remark: string;
  notes: string;
  // B4 JC-007: alternate xCustomerName.
  x_customer_name: string;
  // B4 JC-006: audit timestamps + MaxID surrogate.
  edited_on: string;
  added_on: string;
  max_id: number | null;
  // B4 JC-005: soft-delete flag (Access IsDelete).
  is_deleted: boolean;
  // B4 JC-035 + JC-051: Vinsight Contact Category JSONB tag bag.
  contact_category: string[];
  // BUG-171: legacy dws_code / alm_code / vinsight_code (customer_code_map
  // aggregates) removed. Customer table now binds the 5 master channel codes
  // above (alm/dir/ilg/ynr/ynr_alm_customer_code) from canonical_customer
  // (the owner's Access master).
  satellite_count: number;
}

// Phase R / BUG-148: 3-level canonical > vintage > code tree.
interface CodeRow {
  source: string;           // 'moppity' | 'vinsight' | 'dws' | 'alm' | 'ilg' | 'access' | ...
  external_code: string;
}

interface VintageNode {
  vintage: number | null;   // null → "NV" (non-vintage) bucket
  description: string;
  codes: CodeRow[];
}

interface SkuRow {
  id: number;
  sku_name: string;         // canonical_sku.sku_name (e.g. "COPPABELLA ROSE")
  range: string;
  range_group: string;
  units_per_case: number;
  variety: string;
  region: string;
  vintage_count: number;
  code_count: number;
  vintages: VintageNode[];
}

interface RepRow {
  id: number;
  name: string;
  full_rep_display?: string;
  short_rep?: string | null;
  active: boolean;
  is_active_dws?: boolean;
  is_active_allchannel?: boolean;
  territory_id: number | null;
  territory_name: string;
  territory_group?: string;
  representative_details?: string;
  customer_count: number;
  territories: string[];
  // Per-rep performance metrics (B5 JC-057, 26-col Access verbatim).
  members_growth?: number | null;
  ty_distrn?: number | null;
  range_mtd?: number | null;
  ly_dollar?: number | null;
  ty_dollar?: number | null;
  y_dollar_per?: number | null;
  ly_mtd_dollar?: number | null;
  ty_mtd_dollar?: number | null;
  mtd_per?: number | null;
  ly_mqt_dollar?: number | null;
  ty_mqt_dollar?: number | null;
  mqt_dollar_per?: number | null;
  ranges_per_member?: number | null;
  distrn_per_member?: number | null;
  sales_per_member_mat?: number | null;
  sales_growth_per_member_mat?: number | null;
}

// M17: drill-down rows for the Reps accordion (customer + suburb so the owner can
// verify new-rep transaction attribution before re-assigning).
interface RepCustomerRow {
  customer_name: string;
  suburb: string;
  postcode: string;
  channel: string;
  territory_name: string;
  last_txn_date: string | null;
}

interface TerritoryRow {
  id: number;
  name: string;
  customer_count: number;
  rep_count: number;
  rep_names: string[];
}

interface UnmatchedTerritory {
  name: string;
  customer_count: number;
}

// BUG-81: dead-letter surface for DWS uploads where SKU lookup falls through.
interface UnmatchedCode {
  external_code: string;
  source: string;
  occurrences: number;
  first_seen: string | null;
  last_seen: string | null;
  sample_error: string;
}

interface OrphanSummaryRow {
  source_system: string;
  orphan_count: number;
  first_sale: string | null;
  last_sale: string | null;
}

interface OrphanSampleRow {
  transaction_id: number;
  source_system: string;
  sale_date: string;
  customer_name: string | null;
  quantity: number;
  net_revenue: number | null;
  source_ref: string | null;
}

const emptyForm: FormData = {
  canonical_sku_id: null,
  sku_name: '',
  price_per_case: '',
  effective_from: '',
  effective_to: '',
  notes: '',
};

type TabId = 'prices' | 'customers' | 'skus' | 'reps' | 'territories' | 'unmatched';

// ─── Styles ──────────────────────────────────────────────────────────────

const font = { fontFamily: 'Inter, sans-serif' };
const headingFont = { fontFamily: 'Cardo, serif' };

// Cosmetic VIEW_ONLY demo flag — hides add/edit controls (dead buttons in the
// read-only mirror; real enforcement is the middleware 403). Unset on the live
// editor => controls render as before.
const VIEW_ONLY = process.env.NEXT_PUBLIC_VIEW_ONLY === 'true';

// ─── Helpers ─────────────────────────────────────────────────────────────

// B5 / JC-057: format per-rep MAT sales dollar value. Returns AUD-formatted
// string with thousands separators, or em-dash for null/zero/missing data.
function formatRepMatDollar(v: number | null | undefined): string {
  if (v === null || v === undefined || v === 0) return '—';
  if (!Number.isFinite(v)) return '—';
  return v.toLocaleString('en-AU', {
    style: 'currency',
    currency: 'AUD',
    maximumFractionDigits: 0,
  });
}

// B5 / JC-057: format per-rep growth %. Access stores growth as a fraction
// (0.12 = 12%). Returns "+12.3%" / "-4.5%" / em-dash for null/zero/missing.
function formatRepMatGrowth(v: number | null | undefined): string {
  if (v === null || v === undefined) return '—';
  if (!Number.isFinite(v) || v === 0) return '—';
  const pct = v * 100;
  const sign = pct > 0 ? '+' : '';
  const colorClass = pct > 0 ? 'text-[#1B7A33]' : 'text-[#B42318]';
  // The caller renders this string inside a <td>; the colour wrap is
  // applied via a span at format-time so we don't need to import React.
  return `${sign}${pct.toFixed(1)}%`;
  // colorClass left in place for future styling iteration (kept simple now).
  void colorClass;
}

// Phase R / BUG-148: CSV export for the 3-level SKU tree. One row per external
// code, carrying the canonical + vintage up-columns so the owner can pivot by any
// level in Excel. Preserves the hierarchy that the UI shows.
function downloadSkuTreeCsv(rows: SkuRow[]) {
  const header = [
    'canonical_sku',
    'range',
    'range_group',
    'variety',
    'region',
    'units_per_case',
    'vintage',
    'source_system',
    'external_code',
    'vintage_description',
  ];
  const escape = (val: string | number | null | undefined) => {
    if (val == null) return '';
    const s = String(val);
    return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const lines: string[] = [header.join(',')];
  for (const s of rows) {
    if (s.vintages.length === 0) {
      lines.push([s.sku_name, s.range, s.range_group, s.variety, s.region, s.units_per_case, '', '', '', ''].map(escape).join(','));
      continue;
    }
    for (const v of s.vintages) {
      const vintageLabel = v.vintage == null ? 'NV' : String(v.vintage);
      if (v.codes.length === 0) {
        lines.push([s.sku_name, s.range, s.range_group, s.variety, s.region, s.units_per_case, vintageLabel, '', '', v.description].map(escape).join(','));
        continue;
      }
      for (const code of v.codes) {
        lines.push([
          s.sku_name, s.range, s.range_group, s.variety, s.region, s.units_per_case,
          vintageLabel, code.source, code.external_code, v.description,
        ].map(escape).join(','));
      }
    }
  }
  const blob = new Blob([lines.join('\n')], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `sku-hierarchy-${new Date().toISOString().slice(0, 10)}.csv`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

// ─── Component ───────────────────────────────────────────────────────────

export default function ReferencePage() {
  const [activeTab, setActiveTab] = useState<TabId>('prices');

  // Wholesale Prices state
  const [prices, setPrices] = useState<WholesalePrice[]>([]);
  const [skus, setSkus] = useState<CanonicalSku[]>([]);
  const [pricesLoading, setPricesLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editingId, setEditingId] = useState<number | null>(null);
  const [showAddForm, setShowAddForm] = useState(false);
  const [formData, setFormData] = useState<FormData>(emptyForm);
  const [saving, setSaving] = useState(false);

  // Customer table state
  const [customers, setCustomers] = useState<CustomerRow[]>([]);
  const [customersTotal, setCustomersTotal] = useState(0);
  const [customersLoading, setCustomersLoading] = useState(false);
  const [customersLoaded, setCustomersLoaded] = useState(false);
  const [customerSearch, setCustomerSearch] = useState('');
  const [customerPage, setCustomerPage] = useState(1);
  const [customerTotalPages, setCustomerTotalPages] = useState(1);

  // SKU table state
  const [skuRows, setSkuRows] = useState<SkuRow[]>([]);
  const [skusTotal, setSkusTotal] = useState(0);
  const [skusLoading, setSkusLoading] = useState(false);
  const [skusLoaded, setSkusLoaded] = useState(false);
  const [skuSearch, setSkuSearch] = useState('');
  // Phase R / BUG-148: two collapse levels. Keys:
  //  - canonical id  (level 1 → expands to show its vintages)
  //  - `${canonicalId}|${vintage ?? 'NV'}`  (level 2 → expands to show code rows)
  const [expandedSkus, setExpandedSkus] = useState<Set<number>>(new Set());
  const [expandedVintages, setExpandedVintages] = useState<Set<string>>(new Set());

  // Reps table state
  const [repRows, setRepRows] = useState<RepRow[]>([]);
  const [repsTotal, setRepsTotal] = useState(0);
  const [repsLoading, setRepsLoading] = useState(false);
  const [repsLoaded, setRepsLoaded] = useState(false);
  const [repSearch, setRepSearch] = useState('');
  // M17: Reps accordion — expanded rep id + per-rep customer drill-down cache.
  const [expandedRepId, setExpandedRepId] = useState<number | null>(null);
  const [repCustomers, setRepCustomers] = useState<Record<number, RepCustomerRow[]>>({});
  const [repCustomersLoading, setRepCustomersLoading] = useState<Record<number, boolean>>({});
  const [repCustomersError, setRepCustomersError] = useState<Record<number, string>>({});

  // Territories table state
  const [territoryRows, setTerritoryRows] = useState<TerritoryRow[]>([]);
  const [territoriesTotal, setTerritoriesTotal] = useState(0);
  const [unmatchedTerritories, setUnmatchedTerritories] = useState<UnmatchedTerritory[]>([]);
  const [territoriesLoading, setTerritoriesLoading] = useState(false);
  const [territoriesLoaded, setTerritoriesLoaded] = useState(false);
  const [territorySearch, setTerritorySearch] = useState('');
  const [showUnmatched, setShowUnmatched] = useState(false);

  // BUG-81 Unmatched Products state
  const [unmatchedCodes, setUnmatchedCodes] = useState<UnmatchedCode[]>([]);
  const [orphanSummary, setOrphanSummary] = useState<OrphanSummaryRow[]>([]);
  const [orphanSamples, setOrphanSamples] = useState<OrphanSampleRow[]>([]);
  const [totalOrphanRows, setTotalOrphanRows] = useState(0);
  const [unmatchedLoading, setUnmatchedLoading] = useState(false);
  const [unmatchedLoaded, setUnmatchedLoaded] = useState(false);
  const [showOrphanSamples, setShowOrphanSamples] = useState(false);

  // ─── Wholesale Prices fetch ─────────────────────────────────────────

  const fetchPrices = useCallback(async () => {
    setPricesLoading(true);
    setError(null);
    try {
      const res = await apiGet('/api/wholesale-prices');
      if (!res.ok) {
        const errJson = await res.json().catch(() => null);
        throw new Error(errJson?.error || 'Failed to load data');
      }
      const data = await res.json();
      setPrices(data.prices || []);
      setSkus(data.skus || []);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load data');
    } finally {
      setPricesLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchPrices();
  }, [fetchPrices]);

  // ─── Customer table fetch ───────────────────────────────────────────

  const fetchCustomers = useCallback(async (search = '', page = 1) => {
    setCustomersLoading(true);
    try {
      let url = `/api/reference-tables?table=customers&page=${page}`;
      if (search.length >= 2) {
        url += `&search=${encodeURIComponent(search)}`;
      }
      const res = await apiGet(url);
      if (!res.ok) throw new Error('Failed to load customers');
      const data = await res.json();
      setCustomers(data.rows || []);
      setCustomersTotal(data.total || 0);
      setCustomerPage(data.page || 1);
      setCustomerTotalPages(data.totalPages || 1);
      setCustomersLoaded(true);
    } catch {
      setError('Failed to load customer data');
    } finally {
      setCustomersLoading(false);
    }
  }, []);

  // ─── SKU table fetch ────────────────────────────────────────────────

  const fetchSkus = useCallback(async (search = '') => {
    setSkusLoading(true);
    try {
      const url = search.length >= 2
        ? `/api/reference-tables?table=skus&search=${encodeURIComponent(search)}`
        : '/api/reference-tables?table=skus';
      const res = await apiGet(url);
      if (!res.ok) throw new Error('Failed to load SKUs');
      const data = await res.json();
      setSkuRows(data.rows || []);
      setSkusTotal(data.total || 0);
      setSkusLoaded(true);
    } catch {
      setError('Failed to load SKU data');
    } finally {
      setSkusLoading(false);
    }
  }, []);

  // ─── Reps table fetch ───────────────────────────────────────────────

  const fetchReps = useCallback(async (search = '') => {
    setRepsLoading(true);
    try {
      const url = search.length >= 2
        ? `/api/reps?search=${encodeURIComponent(search)}`
        : '/api/reps';
      const res = await apiGet(url);
      if (!res.ok) throw new Error('Failed to load reps');
      const data = await res.json();
      setRepRows(data.reps || []);
      setRepsTotal(data.total || 0);
      setRepsLoaded(true);
    } catch {
      setError('Failed to load rep data');
    } finally {
      setRepsLoading(false);
    }
  }, []);

  // ─── M17: Reps drill-down (customer + suburb per rep) ──────────────

  const toggleRepExpand = useCallback(async (repId: number) => {
    // Collapse if already open.
    if (expandedRepId === repId) {
      setExpandedRepId(null);
      return;
    }
    setExpandedRepId(repId);
    // Cache hit — skip refetch.
    if (repCustomers[repId]) return;
    setRepCustomersLoading((prev) => ({ ...prev, [repId]: true }));
    setRepCustomersError((prev) => {
      const next = { ...prev };
      delete next[repId];
      return next;
    });
    try {
      const res = await apiGet(`/api/reps/${repId}/customers`);
      if (!res.ok) throw new Error('Failed to load rep customers');
      const data = await res.json();
      const rows: RepCustomerRow[] = (data.customers || []) as RepCustomerRow[];
      // Order: suburb asc, then customer_name asc (case-insensitive).
      rows.sort((a, b) => {
        const sa = (a.suburb || '').toLowerCase();
        const sb = (b.suburb || '').toLowerCase();
        if (sa !== sb) return sa < sb ? -1 : 1;
        const na = (a.customer_name || '').toLowerCase();
        const nb = (b.customer_name || '').toLowerCase();
        return na < nb ? -1 : na > nb ? 1 : 0;
      });
      setRepCustomers((prev) => ({ ...prev, [repId]: rows }));
    } catch (err) {
      setRepCustomersError((prev) => ({
        ...prev,
        [repId]: err instanceof Error ? err.message : 'Failed to load',
      }));
    } finally {
      setRepCustomersLoading((prev) => ({ ...prev, [repId]: false }));
    }
  }, [expandedRepId, repCustomers]);

  // ─── Territories table fetch ────────────────────────────────────────

  const fetchTerritories = useCallback(async (search = '') => {
    setTerritoriesLoading(true);
    try {
      const url = search.length >= 2
        ? `/api/territories?search=${encodeURIComponent(search)}`
        : '/api/territories';
      const res = await apiGet(url);
      if (!res.ok) throw new Error('Failed to load territories');
      const data = await res.json();
      setTerritoryRows(data.territories || []);
      setTerritoriesTotal(data.total || 0);
      setUnmatchedTerritories(data.unmatched_territories || []);
      setTerritoriesLoaded(true);
    } catch {
      setError('Failed to load territory data');
    } finally {
      setTerritoriesLoading(false);
    }
  }, []);

  // ─── BUG-81 Unmatched Products fetch ────────────────────────────────

  const fetchUnmatched = useCallback(async () => {
    setUnmatchedLoading(true);
    try {
      const res = await apiGet('/api/unmatched-products');
      if (!res.ok) throw new Error('Failed to load unmatched products');
      const data = await res.json();
      setUnmatchedCodes(data.unmatched_codes || []);
      setOrphanSummary(data.orphan_summary || []);
      setOrphanSamples(data.orphan_samples || []);
      setTotalOrphanRows(data.total_orphan_rows || 0);
      setUnmatchedLoaded(true);
    } catch {
      setError('Failed to load unmatched-product data');
    } finally {
      setUnmatchedLoading(false);
    }
  }, []);

  // C16: deep-link tab from ?tab= query param so post-upload banner can land
  // user directly on Customers / SKUs view. Runs once on mount.
  useEffect(() => {
    if (typeof window === 'undefined') return;
    const tab = new URLSearchParams(window.location.search).get('tab');
    if (tab === 'customers' || tab === 'skus' || tab === 'reps' || tab === 'territories' || tab === 'unmatched' || tab === 'prices') {
      setActiveTab(tab);
    }
  }, []);

  // Lazy-load tab data on first visit
  useEffect(() => {
    if (activeTab === 'customers' && !customersLoaded) fetchCustomers();
    if (activeTab === 'skus' && !skusLoaded) fetchSkus();
    if (activeTab === 'reps' && !repsLoaded) fetchReps();
    if (activeTab === 'territories' && !territoriesLoaded) fetchTerritories();
    if (activeTab === 'unmatched' && !unmatchedLoaded) fetchUnmatched();
  }, [activeTab, customersLoaded, skusLoaded, repsLoaded, territoriesLoaded, unmatchedLoaded, fetchCustomers, fetchSkus, fetchReps, fetchTerritories, fetchUnmatched]);

  // Debounced search for customers — reset to page 1 on search change
  useEffect(() => {
    if (!customersLoaded) return;
    setCustomerPage(1);
    const timer = setTimeout(() => fetchCustomers(customerSearch, 1), 300);
    return () => clearTimeout(timer);
  }, [customerSearch, customersLoaded, fetchCustomers]);

  // Debounced search for SKUs
  useEffect(() => {
    if (!skusLoaded) return;
    const timer = setTimeout(() => fetchSkus(skuSearch), 300);
    return () => clearTimeout(timer);
  }, [skuSearch, skusLoaded, fetchSkus]);

  // Debounced search for Reps
  useEffect(() => {
    if (!repsLoaded) return;
    const timer = setTimeout(() => fetchReps(repSearch), 300);
    return () => clearTimeout(timer);
  }, [repSearch, repsLoaded, fetchReps]);

  // Debounced search for Territories
  useEffect(() => {
    if (!territoriesLoaded) return;
    const timer = setTimeout(() => fetchTerritories(territorySearch), 300);
    return () => clearTimeout(timer);
  }, [territorySearch, territoriesLoaded, fetchTerritories]);

  // ─── Wholesale Price CRUD handlers ──────────────────────────────────

  const handleAdd = async () => {
    if (!formData.price_per_case || !formData.effective_from) {
      setError('Price and effective from date are required');
      return;
    }
    if (!formData.canonical_sku_id && !formData.sku_name) {
      setError('Select a SKU or enter a SKU name');
      return;
    }

    setSaving(true);
    try {
      const res = await apiPost('/api/wholesale-prices', {
        canonical_sku_id: formData.canonical_sku_id,
        sku_name: formData.sku_name || null,
        price_per_case: parseFloat(formData.price_per_case),
        effective_from: formData.effective_from,
        effective_to: formData.effective_to || null,
        notes: formData.notes || null,
      });
      if (!res.ok) {
        const errJson = await res.json().catch(() => null);
        throw new Error(errJson?.error || 'Failed to add price');
      }
      setFormData(emptyForm);
      setShowAddForm(false);
      fetchPrices();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to add price');
    } finally {
      setSaving(false);
    }
  };

  const handleUpdate = async (id: number) => {
    setSaving(true);
    try {
      const res = await apiPut('/api/wholesale-prices', {
        id,
        canonical_sku_id: formData.canonical_sku_id,
        sku_name: formData.sku_name || null,
        price_per_case: formData.price_per_case ? parseFloat(formData.price_per_case) : undefined,
        effective_from: formData.effective_from || undefined,
        effective_to: formData.effective_to || null,
        notes: formData.notes,
      });
      if (!res.ok) {
        const errJson = await res.json().catch(() => null);
        throw new Error(errJson?.error || 'Failed to update price');
      }
      setEditingId(null);
      setFormData(emptyForm);
      fetchPrices();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to update price');
    } finally {
      setSaving(false);
    }
  };

  const handleDelete = async (id: number) => {
    if (!confirm('Delete this price entry?')) return;
    try {
      const res = await apiDelete(`/api/wholesale-prices?id=${id}`);
      if (!res.ok) {
        const errJson = await res.json().catch(() => null);
        throw new Error(errJson?.error || 'Failed to delete price');
      }
      fetchPrices();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete price');
    }
  };

  const startEdit = (price: WholesalePrice) => {
    setEditingId(price.id);
    setFormData({
      canonical_sku_id: price.canonical_sku_id,
      sku_name: price.sku_name || '',
      price_per_case: String(price.price_per_case),
      effective_from: price.effective_from?.split('T')[0] || '',
      effective_to: price.effective_to?.split('T')[0] || '',
      notes: price.notes || '',
    });
  };

  const cancelEdit = () => {
    setEditingId(null);
    setFormData(emptyForm);
  };

  const formatDate = (dateStr: string | null) => {
    if (!dateStr) return '\u2014';
    return new Date(dateStr).toLocaleDateString('en-AU', {
      day: 'numeric',
      month: 'short',
      year: 'numeric',
    });
  };

  const formatCurrency = (amount: number) => {
    return new Intl.NumberFormat('en-AU', {
      style: 'currency',
      currency: 'AUD',
    }).format(amount);
  };

  // ─── Tab definitions ────────────────────────────────────────────────

  const tabs: { id: TabId; label: string; icon: React.ReactNode; count?: number }[] = [
    { id: 'prices', label: 'Wholesale Prices', icon: <DollarSign size={16} />, count: prices.length },
    { id: 'customers', label: 'Customers', icon: <Users size={16} />, count: customersTotal },
    { id: 'skus', label: 'SKUs', icon: <Package size={16} />, count: skusTotal },
    { id: 'reps', label: 'Reps', icon: <UserCog size={16} />, count: repsTotal },
    { id: 'territories', label: 'Territories', icon: <MapIcon size={16} />, count: territoriesTotal },
    { id: 'unmatched', label: 'Unmatched', icon: <HelpCircle size={16} />, count: unmatchedCodes.length + totalOrphanRows },
  ];

  return (
    <AppLayout>
      <div className="p-6 space-y-6">
        {/* Header */}
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-2xl text-[#1F1F1F] font-semibold" style={headingFont}>
              Reference Data
            </h1>
            <p className="text-sm text-[#8A8A8D] mt-1" style={font}>
              Browse and manage reference tables — verify data after import
            </p>
          </div>
          {activeTab === 'prices' && (
            <button
              onClick={fetchPrices}
              disabled={pricesLoading}
              className="flex items-center gap-2 px-3 py-2 rounded-lg text-sm font-medium border border-[#D8D9DA] text-[#505052] hover:bg-[#FAF9F7] transition-colors"
              style={font}
            >
              <RefreshCw size={16} className={pricesLoading ? 'animate-spin' : ''} />
              Refresh
            </button>
          )}
          {activeTab === 'customers' && (
            <button
              onClick={() => fetchCustomers(customerSearch, customerPage)}
              disabled={customersLoading}
              className="flex items-center gap-2 px-3 py-2 rounded-lg text-sm font-medium border border-[#D8D9DA] text-[#505052] hover:bg-[#FAF9F7] transition-colors"
              style={font}
            >
              <RefreshCw size={16} className={customersLoading ? 'animate-spin' : ''} />
              Refresh
            </button>
          )}
          {activeTab === 'skus' && (
            <button
              onClick={() => fetchSkus(skuSearch)}
              disabled={skusLoading}
              className="flex items-center gap-2 px-3 py-2 rounded-lg text-sm font-medium border border-[#D8D9DA] text-[#505052] hover:bg-[#FAF9F7] transition-colors"
              style={font}
            >
              <RefreshCw size={16} className={skusLoading ? 'animate-spin' : ''} />
              Refresh
            </button>
          )}
          {activeTab === 'reps' && (
            <button
              onClick={() => fetchReps(repSearch)}
              disabled={repsLoading}
              className="flex items-center gap-2 px-3 py-2 rounded-lg text-sm font-medium border border-[#D8D9DA] text-[#505052] hover:bg-[#FAF9F7] transition-colors"
              style={font}
            >
              <RefreshCw size={16} className={repsLoading ? 'animate-spin' : ''} />
              Refresh
            </button>
          )}
          {activeTab === 'territories' && (
            <button
              onClick={() => fetchTerritories(territorySearch)}
              disabled={territoriesLoading}
              className="flex items-center gap-2 px-3 py-2 rounded-lg text-sm font-medium border border-[#D8D9DA] text-[#505052] hover:bg-[#FAF9F7] transition-colors"
              style={font}
            >
              <RefreshCw size={16} className={territoriesLoading ? 'animate-spin' : ''} />
              Refresh
            </button>
          )}
          {activeTab === 'unmatched' && (
            <button
              onClick={fetchUnmatched}
              disabled={unmatchedLoading}
              className="flex items-center gap-2 px-3 py-2 rounded-lg text-sm font-medium border border-[#D8D9DA] text-[#505052] hover:bg-[#FAF9F7] transition-colors"
              style={font}
            >
              <RefreshCw size={16} className={unmatchedLoading ? 'animate-spin' : ''} />
              Refresh
            </button>
          )}
        </div>

        {error && (
          <div className="bg-[#FEF3F2] border border-[#FECACA] rounded-lg px-4 py-3 text-[#B42318] text-sm" style={font}>
            {error}
            <button onClick={() => setError(null)} className="ml-2 underline">
              Dismiss
            </button>
          </div>
        )}

        {/* Tab Navigation */}
        <div className="flex gap-1 border-b border-[#EBEBEC]">
          {tabs.map((tab) => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              className={`flex items-center gap-2 px-4 py-2.5 text-sm font-medium transition-colors border-b-2 -mb-px ${
                activeTab === tab.id
                  ? 'border-[#931220] text-[#931220]'
                  : 'border-transparent text-[#8A8A8D] hover:text-[#505052] hover:border-[#D8D9DA]'
              }`}
              style={font}
            >
              {tab.icon}
              {tab.label}
              {tab.count !== undefined && tab.count > 0 && (
                <span className={`text-xs px-1.5 py-0.5 rounded-full ${
                  activeTab === tab.id
                    ? 'bg-[#931220]/10 text-[#931220]'
                    : 'bg-[#F5F4F2] text-[#8A8A8D]'
                }`}>
                  {tab.count}
                </span>
              )}
            </button>
          ))}
        </div>

        {/* ═══════════════════════════════════════════════════════════════ */}
        {/* TAB: Wholesale Prices                                         */}
        {/* ═══════════════════════════════════════════════════════════════ */}
        {activeTab === 'prices' && (
          <div className="bg-white rounded-xl border border-[#EBEBEC] shadow-sm overflow-hidden">
            {/* Card Header */}
            <div className="p-5 border-b border-[#EBEBEC] flex items-center justify-between">
              <div>
                <h2 className="text-base text-[#1F1F1F] font-semibold flex items-center gap-2" style={headingFont}>
                  <DollarSign size={18} className="text-[#931220]" />
                  Wholesale Prices
                  <InfoTooltip
                    text="Historical wholesale prices by SKU and date range. Used to calculate discount = wholesale_price - net_revenue. Add future price rises here."
                    size={10}
                    className="inline-flex ml-1"
                  />
                </h2>
                <p className="text-xs text-[#8A8A8D] mt-0.5" style={font}>
                  {prices.length} price entries configured
                </p>
              </div>
              {!showAddForm && !VIEW_ONLY && (
                <button
                  onClick={() => {
                    setShowAddForm(true);
                    setFormData(emptyForm);
                  }}
                  className="flex items-center gap-2 px-3 py-1.5 rounded-lg text-xs font-medium bg-[#931220] text-white hover:bg-[#7a0f1a] transition-colors"
                  style={font}
                >
                  <Plus size={14} />
                  Add Price
                </button>
              )}
            </div>

            {/* Add Form */}
            {showAddForm && (
              <div className="p-5 bg-[#FAF9F7] border-b border-[#EBEBEC]">
                <div className="grid grid-cols-6 gap-4 items-end">
                  <div>
                    <label className="block text-[11px] text-[#505052] font-medium uppercase tracking-wider mb-1" style={font}>
                      SKU
                    </label>
                    <select
                      value={formData.canonical_sku_id || ''}
                      onChange={(e) =>
                        setFormData({
                          ...formData,
                          canonical_sku_id: e.target.value ? parseInt(e.target.value) : null,
                          sku_name: '',
                        })
                      }
                      className="w-full px-3 py-2 bg-white border border-[#D8D9DA] rounded-lg text-sm text-[#1F1F1F] focus:outline-none focus:ring-2 focus:ring-[#931220]/20 focus:border-[#931220]"
                      style={font}
                    >
                      <option value="">Select SKU...</option>
                      {skus.map((sku) => (
                        <option key={sku.id} value={sku.id}>
                          {sku.sku_name}
                        </option>
                      ))}
                    </select>
                  </div>
                  <div>
                    <label className="block text-[11px] text-[#505052] font-medium uppercase tracking-wider mb-1" style={font}>
                      Or SKU Name
                    </label>
                    <input
                      type="text"
                      value={formData.sku_name}
                      onChange={(e) =>
                        setFormData({ ...formData, sku_name: e.target.value, canonical_sku_id: null })
                      }
                      placeholder="Manual entry..."
                      className="w-full px-3 py-2 bg-white border border-[#D8D9DA] rounded-lg text-sm text-[#1F1F1F] placeholder-[#8A8A8D] focus:outline-none focus:ring-2 focus:ring-[#931220]/20 focus:border-[#931220]"
                      style={font}
                    />
                  </div>
                  <div>
                    <label className="block text-[11px] text-[#505052] font-medium uppercase tracking-wider mb-1" style={font}>
                      Price/Case *
                    </label>
                    <input
                      type="number"
                      step="0.01"
                      value={formData.price_per_case}
                      onChange={(e) => setFormData({ ...formData, price_per_case: e.target.value })}
                      placeholder="0.00"
                      className="w-full px-3 py-2 bg-white border border-[#D8D9DA] rounded-lg text-sm text-[#1F1F1F] placeholder-[#8A8A8D] focus:outline-none focus:ring-2 focus:ring-[#931220]/20 focus:border-[#931220]"
                      style={font}
                    />
                  </div>
                  <div>
                    <label className="block text-[11px] text-[#505052] font-medium uppercase tracking-wider mb-1" style={font}>
                      From *
                    </label>
                    <input
                      type="date"
                      value={formData.effective_from}
                      onChange={(e) => setFormData({ ...formData, effective_from: e.target.value })}
                      className="w-full px-3 py-2 bg-white border border-[#D8D9DA] rounded-lg text-sm text-[#1F1F1F] focus:outline-none focus:ring-2 focus:ring-[#931220]/20 focus:border-[#931220]"
                      style={font}
                    />
                  </div>
                  <div>
                    <label className="block text-[11px] text-[#505052] font-medium uppercase tracking-wider mb-1" style={font}>
                      To
                    </label>
                    <input
                      type="date"
                      value={formData.effective_to}
                      onChange={(e) => setFormData({ ...formData, effective_to: e.target.value })}
                      className="w-full px-3 py-2 bg-white border border-[#D8D9DA] rounded-lg text-sm text-[#1F1F1F] focus:outline-none focus:ring-2 focus:ring-[#931220]/20 focus:border-[#931220]"
                      style={font}
                    />
                  </div>
                  <div className="flex gap-2">
                    <button
                      onClick={handleAdd}
                      disabled={saving}
                      className="flex items-center gap-1 px-3 py-2 rounded-lg text-xs font-medium bg-[#931220] text-white hover:bg-[#7a0f1a] transition-colors disabled:opacity-50"
                      style={font}
                    >
                      <Save size={14} />
                      Save
                    </button>
                    <button
                      onClick={() => {
                        setShowAddForm(false);
                        setFormData(emptyForm);
                      }}
                      className="flex items-center gap-1 px-3 py-2 rounded-lg text-xs font-medium border border-[#D8D9DA] text-[#505052] hover:bg-[#FAF9F7] transition-colors"
                      style={font}
                    >
                      <X size={14} />
                    </button>
                  </div>
                </div>
              </div>
            )}

            {/* Prices Table */}
            <div className="overflow-x-auto">
              <table className="w-full text-xs" style={font}>
                <thead>
                  <tr className="border-b border-[#D8D9DA] bg-[#F5F4F2]">
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      SKU Name
                    </th>
                    <th className="py-2 px-5 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Price/Case
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Effective From
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Effective To
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Notes
                    </th>
                    <th className="py-2 px-5 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider w-24">
                      Actions
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {pricesLoading ? (
                    <tr>
                      <td colSpan={6} className="px-5 py-8 text-center text-[#8A8A8D]">
                        Loading...
                      </td>
                    </tr>
                  ) : prices.length === 0 ? (
                    <tr>
                      <td colSpan={6} className="px-5 py-8 text-center text-[#8A8A8D]">
                        No wholesale prices configured yet. Click &quot;Add Price&quot; to add one.
                      </td>
                    </tr>
                  ) : (
                    prices.map((price) =>
                      editingId === price.id ? (
                        <tr key={price.id} className="border-b border-[#EBEBEC] bg-[#FAF9F7]">
                          <td className="px-5 py-3">
                            <select
                              value={formData.canonical_sku_id || ''}
                              onChange={(e) =>
                                setFormData({
                                  ...formData,
                                  canonical_sku_id: e.target.value ? parseInt(e.target.value) : null,
                                })
                              }
                              className="w-full px-2 py-1 bg-white border border-[#D8D9DA] rounded text-[#1F1F1F] focus:outline-none focus:ring-2 focus:ring-[#931220]/20"
                            >
                              <option value="">Select SKU...</option>
                              {skus.map((sku) => (
                                <option key={sku.id} value={sku.id}>
                                  {sku.sku_name}
                                </option>
                              ))}
                            </select>
                          </td>
                          <td className="px-5 py-3">
                            <input
                              type="number"
                              step="0.01"
                              value={formData.price_per_case}
                              onChange={(e) =>
                                setFormData({ ...formData, price_per_case: e.target.value })
                              }
                              className="w-24 px-2 py-1 bg-white border border-[#D8D9DA] rounded text-[#1F1F1F] text-right focus:outline-none focus:ring-2 focus:ring-[#931220]/20"
                            />
                          </td>
                          <td className="px-5 py-3">
                            <input
                              type="date"
                              value={formData.effective_from}
                              onChange={(e) =>
                                setFormData({ ...formData, effective_from: e.target.value })
                              }
                              className="px-2 py-1 bg-white border border-[#D8D9DA] rounded text-[#1F1F1F] focus:outline-none focus:ring-2 focus:ring-[#931220]/20"
                            />
                          </td>
                          <td className="px-5 py-3">
                            <input
                              type="date"
                              value={formData.effective_to}
                              onChange={(e) =>
                                setFormData({ ...formData, effective_to: e.target.value })
                              }
                              className="px-2 py-1 bg-white border border-[#D8D9DA] rounded text-[#1F1F1F] focus:outline-none focus:ring-2 focus:ring-[#931220]/20"
                            />
                          </td>
                          <td className="px-5 py-3">
                            <input
                              type="text"
                              value={formData.notes}
                              onChange={(e) => setFormData({ ...formData, notes: e.target.value })}
                              className="w-full px-2 py-1 bg-white border border-[#D8D9DA] rounded text-[#1F1F1F] focus:outline-none focus:ring-2 focus:ring-[#931220]/20"
                            />
                          </td>
                          <td className="px-5 py-3">
                            <div className="flex gap-1 justify-end">
                              <button
                                onClick={() => handleUpdate(price.id)}
                                disabled={saving}
                                className="p-1.5 text-[#1B7A3D] hover:bg-[#ECFDF3] rounded transition-colors"
                                title="Save"
                              >
                                <Save size={14} />
                              </button>
                              <button
                                onClick={cancelEdit}
                                className="p-1.5 text-[#505052] hover:bg-[#F5F4F2] rounded transition-colors"
                                title="Cancel"
                              >
                                <X size={14} />
                              </button>
                            </div>
                          </td>
                        </tr>
                      ) : (
                        <tr key={price.id} className="border-b border-[#EBEBEC] hover:bg-[#FAF9F7]">
                          <td className="px-5 py-2.5 text-[#1F1F1F]">{price.sku_name}</td>
                          <td className="px-5 py-2.5 text-[#1F1F1F] text-right font-mono">
                            {formatCurrency(price.price_per_case)}
                          </td>
                          <td className="px-5 py-2.5 text-[#505052]">
                            {formatDate(price.effective_from)}
                          </td>
                          <td className="px-5 py-2.5 text-[#505052]">
                            {price.effective_to ? (
                              formatDate(price.effective_to)
                            ) : (
                              <Badge variant="success">Current</Badge>
                            )}
                          </td>
                          <td className="px-5 py-2.5 text-[#8A8A8D] truncate max-w-[200px]">
                            {price.notes || '\u2014'}
                          </td>
                          <td className="px-5 py-2.5">
                            <div className="flex gap-1 justify-end">
                              <button
                                onClick={() => startEdit(price)}
                                className="p-1.5 text-[#505052] hover:text-[#1F1F1F] hover:bg-[#F5F4F2] rounded transition-colors"
                                title="Edit"
                              >
                                <Pencil size={14} />
                              </button>
                              <button
                                onClick={() => handleDelete(price.id)}
                                className="p-1.5 text-[#505052] hover:text-[#B42318] hover:bg-[#FEF3F2] rounded transition-colors"
                                title="Delete"
                              >
                                <Trash2 size={14} />
                              </button>
                            </div>
                          </td>
                        </tr>
                      )
                    )
                  )}
                </tbody>
              </table>
            </div>

            {/* Footer Help */}
            <div className="p-4 bg-[#FAF9F7] border-t border-[#EBEBEC]">
              <p className="text-[11px] text-[#8A8A8D]" style={font}>
                <strong>Tip:</strong> Leave &quot;Effective To&quot; empty for the current price.
                When you add a price rise, set the new &quot;Effective From&quot; date and the old price will automatically apply to earlier sales.
              </p>
            </div>
          </div>
        )}

        {/* ═══════════════════════════════════════════════════════════════ */}
        {/* TAB: Customers                                                */}
        {/* ═══════════════════════════════════════════════════════════════ */}
        {activeTab === 'customers' && (
          <div className="bg-white rounded-xl border border-[#EBEBEC] shadow-sm overflow-hidden">
            {/* Card Header */}
            <div className="p-5 border-b border-[#EBEBEC] flex items-center justify-between">
              <div>
                <h2 className="text-base text-[#1F1F1F] font-semibold flex items-center gap-2" style={headingFont}>
                  <Users size={18} className="text-[#931220]" />
                  Customer Table
                  <InfoTooltip
                    text="Read-only view of all customers in the database. Use this to verify data after importing DWS/ALM/Direct files. Search by name, suburb, channel, territory, or rep."
                    size={10}
                    className="inline-flex ml-1"
                  />
                </h2>
                <p className="text-xs text-[#8A8A8D] mt-0.5" style={font}>
                  {customersTotal} customers total
                  {customerTotalPages > 1 && ` (page ${customerPage} of ${customerTotalPages})`}
                </p>
              </div>
              <div className="flex items-center gap-2">
                <a
                  href={`/api/customers/export${customerSearch ? `?search=${encodeURIComponent(customerSearch)}` : ''}`}
                  className="px-3 py-2 rounded-lg text-xs font-medium border border-[#D8D9DA] text-[#505052] hover:bg-white transition-colors whitespace-nowrap"
                  style={font}
                  title="Download all customers as CSV with the full 22-column schema."
                  download
                >
                  Export CSV
                </a>
                <div className="relative">
                  <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-[#8A8A8D]" />
                  <input
                    type="text"
                    value={customerSearch}
                    onChange={(e) => setCustomerSearch(e.target.value)}
                    placeholder="Search customers..."
                    className="pl-9 pr-3 py-2 bg-white border border-[#D8D9DA] rounded-lg text-sm text-[#1F1F1F] placeholder-[#8A8A8D] focus:outline-none focus:ring-2 focus:ring-[#931220]/20 focus:border-[#931220] w-64"
                    style={font}
                  />
                </div>
              </div>
            </div>

            {/* Customer Table — BUG-79: 1 row per canonical_customer with all channel codes */}
            <div className="overflow-x-auto">
              <table className="w-full text-xs" style={font}>
                <thead>
                  <tr className="border-b border-[#D8D9DA] bg-[#F5F4F2]">
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Customer Name
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider" title="Master customer code.">
                      Customer Code
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider" title="ALM cross-reference customer code.">
                      ALM Code
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider" title="Direct (Vinsight) cross-reference customer code. Replaces the legacy 'Vinsight Code' column.">
                      Direct Code
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider" title="Independent Liquor Group cross-reference customer code.">
                      ILG Code
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider" title="Young & Rashleigh (YNR / DWS) cross-reference customer code. Replaces the legacy 'DWS Code' column.">
                      YNR Code
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider" title="YNR-ALM hybrid cross-reference customer code.">
                      YNR-ALM Code
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider" title="Venue type (ON/OFF Premise / Wholesale / Direct / Hybrid).">
                      Channel
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Warehouse
                      <InfoTooltip
                        text="Customer's dominant warehouse channel — the one they trade through most frequently across all transactions. Customer may buy from multiple warehouses; this column shows the primary by transaction count."
                        size={10}
                        className="inline-flex ml-1"
                      />
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Territory
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider" title="Territory group rollup.">
                      Territory Group
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Rep
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider" title="Master rep assignment. Distinct from the Rep column, which is the free-text value from the legacy source.">
                      Canonical Rep
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Suburb
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Postcode
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider" title="Long-form free-text notes and history. Hover a row to see the full text.">
                      Notes
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider" title="Last-edited timestamp.">
                      Edited On
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {customersLoading ? (
                    <tr>
                      <td colSpan={17} className="px-5 py-8 text-center text-[#8A8A8D]">
                        Loading customers...
                      </td>
                    </tr>
                  ) : customers.length === 0 ? (
                    <tr>
                      <td colSpan={17} className="px-5 py-8 text-center text-[#8A8A8D]">
                        {customerSearch ? 'No customers match your search.' : 'No customers in the database yet.'}
                      </td>
                    </tr>
                  ) : (
                    customers.map((c) => (
                      <tr key={`${c.canonical_id ?? 'u'}-${c.id}`} className={`border-b border-[#EBEBEC] hover:bg-[#FAF9F7] ${c.is_deleted ? 'opacity-60' : ''}`}>
                        <td className="px-5 py-2.5 text-[#1F1F1F] font-medium">
                          <div className="flex items-center gap-1.5 min-w-0">
                            <span className="truncate" title={c.x_customer_name && c.x_customer_name !== c.name ? `xCustomerName: ${c.x_customer_name}` : undefined}>
                              {c.name}
                            </span>
                            {c.satellite_count > 1 && (
                              <span className="text-[10px] bg-[#F0F0F0] text-[#666] px-1.5 py-0.5 rounded-full whitespace-nowrap flex-shrink-0">
                                {c.satellite_count} variants
                              </span>
                            )}
                            {c.is_deleted && (
                              <span className="text-[10px] bg-[#FCEAEA] text-[#931220] px-1.5 py-0.5 rounded-full whitespace-nowrap flex-shrink-0" title="Marked as deleted in the source system. History preserved.">
                                deleted
                              </span>
                            )}
                            {c.remark && (
                              <span className="text-[10px] bg-[#FFF5DC] text-[#7A5A00] px-1.5 py-0.5 rounded-full whitespace-nowrap flex-shrink-0" title={`Remark: ${c.remark}`}>
                                remark
                              </span>
                            )}
                          </div>
                        </td>
                        <td className="px-5 py-2.5 text-[#505052] font-mono text-[11px]">{c.customer_code || '\u2014'}</td>
                        {/* BUG-171: bind 5 channel-code columns to canonical_customer
                            Access-master fields. Legacy code_map aggregates removed. */}
                        <td className="px-5 py-2.5 text-[#505052] font-mono text-[11px]">{c.alm_customer_code || '\u2014'}</td>
                        <td className="px-5 py-2.5 text-[#505052] font-mono text-[11px]">{c.dir_customer_code || '\u2014'}</td>
                        <td className="px-5 py-2.5 text-[#505052] font-mono text-[11px]">{c.ilg_customer_code || '\u2014'}</td>
                        <td className="px-5 py-2.5 text-[#505052] font-mono text-[11px]">{c.ynr_customer_code || '\u2014'}</td>
                        <td className="px-5 py-2.5 text-[#505052] font-mono text-[11px]">{c.ynr_alm_customer_code || '\u2014'}</td>
                        <td className="px-5 py-2.5 text-[#505052]">
                          {c.channel ? (
                            <Badge variant="neutral">{c.channel}</Badge>
                          ) : (
                            <span className="text-[#8A8A8D]">{'\u2014'}</span>
                          )}
                        </td>
                        <td className="px-5 py-2.5 text-[#505052]">
                          {c.warehouse_channel ? (
                            <Badge variant="neutral">{c.warehouse_channel}</Badge>
                          ) : (
                            <span className="text-[#8A8A8D]">{'\u2014'}</span>
                          )}
                        </td>
                        <td className="px-5 py-2.5 text-[#505052]">{c.territory || '\u2014'}</td>
                        <td className="px-5 py-2.5 text-[#505052]">{c.territory_group || '\u2014'}</td>
                        <td className="px-5 py-2.5 text-[#505052]">{c.rep || '\u2014'}</td>
                        <td className="px-5 py-2.5 text-[#505052]" title={c.canonical_rep_count > 1 ? `${c.canonical_rep_count} distinct master reps across this customer's variants` : undefined}>
                          {c.canonical_rep ? (
                            <span className="truncate inline-block max-w-[14rem]">{c.canonical_rep}</span>
                          ) : (
                            <span className="text-[#8A8A8D]">(unassigned)</span>
                          )}
                        </td>
                        <td className="px-5 py-2.5 text-[#505052]">{c.suburb || '\u2014'}</td>
                        <td className="px-5 py-2.5 text-[#505052] font-mono text-[11px]">{c.postcode || '\u2014'}</td>
                        <td className="px-5 py-2.5 text-[#505052] truncate max-w-[14rem]" title={c.notes || undefined}>
                          {c.notes ? c.notes : <span className="text-[#8A8A8D]">{'\u2014'}</span>}
                        </td>
                        <td className="px-5 py-2.5 text-[#8A8A8D] font-mono text-[10px] whitespace-nowrap" title={c.added_on ? `Added: ${c.added_on}` : undefined}>
                          {c.edited_on ? c.edited_on.slice(0, 10) : '\u2014'}
                        </td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>

            {/* Footer with pagination */}
            <div className="p-4 bg-[#FAF9F7] border-t border-[#EBEBEC] flex items-center justify-between">
              <p className="text-[11px] text-[#8A8A8D]" style={font}>
                <strong>Read-only view.</strong> Customers are created during data import (DWS/ALM/Direct file upload).
                To edit customer details, use the full Admin Grids (coming in Phase 2).
              </p>
              {customerTotalPages > 1 && (
                <div className="flex items-center gap-3" style={font}>
                  <button
                    onClick={() => {
                      const prev = customerPage - 1;
                      setCustomerPage(prev);
                      fetchCustomers(customerSearch, prev);
                    }}
                    disabled={customerPage <= 1 || customersLoading}
                    className="px-3 py-1.5 rounded-lg text-xs font-medium border border-[#D8D9DA] text-[#505052] hover:bg-white transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
                  >
                    Previous
                  </button>
                  <span className="text-xs text-[#505052]">
                    Page {customerPage} of {customerTotalPages}
                  </span>
                  <button
                    onClick={() => {
                      const next = customerPage + 1;
                      setCustomerPage(next);
                      fetchCustomers(customerSearch, next);
                    }}
                    disabled={customerPage >= customerTotalPages || customersLoading}
                    className="px-3 py-1.5 rounded-lg text-xs font-medium border border-[#D8D9DA] text-[#505052] hover:bg-white transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
                  >
                    Next
                  </button>
                </div>
              )}
            </div>
          </div>
        )}

        {/* ═══════════════════════════════════════════════════════════════ */}
        {/* TAB: SKUs                                                     */}
        {/* ═══════════════════════════════════════════════════════════════ */}
        {activeTab === 'skus' && (
          <div className="bg-white rounded-xl border border-[#EBEBEC] shadow-sm overflow-hidden">
            {/* Card Header */}
            <div className="p-5 border-b border-[#EBEBEC] flex items-center justify-between">
              <div>
                <h2 className="text-base text-[#1F1F1F] font-semibold flex items-center gap-2" style={headingFont}>
                  <Package size={18} className="text-[#931220]" />
                  SKU Hierarchy
                  <InfoTooltip
                    text={VIEW_ONLY
                      ? 'Canonical SKU > Vintage > external codes per source system (Vinsight / DWS / ALM / ILG / Access / Internal). Click a row to expand. Search matches name, variety, region, description, and any external code.'
                      : 'Canonical SKU > Vintage > external codes per source system (Vinsight / DWS / ALM / ILG / Access / Moppity). Click a row to expand. Search matches name, variety, region, description, and any external code.'}
                    size={10}
                    className="inline-flex ml-1"
                  />
                </h2>
                <p className="text-xs text-[#8A8A8D] mt-0.5" style={font}>
                  {skusTotal} canonical SKUs
                  {skuRows.length < skusTotal && ` (showing ${skuRows.length})`}
                </p>
              </div>
              <div className="flex items-center gap-2">
                <div className="relative">
                  <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-[#8A8A8D]" />
                  <input
                    type="text"
                    value={skuSearch}
                    onChange={(e) => setSkuSearch(e.target.value)}
                    placeholder="Search canonical, code, variety..."
                    className="pl-9 pr-3 py-2 bg-white border border-[#D8D9DA] rounded-lg text-sm text-[#1F1F1F] placeholder-[#8A8A8D] focus:outline-none focus:ring-2 focus:ring-[#931220]/20 focus:border-[#931220] w-72"
                    style={font}
                  />
                </div>
                <button
                  onClick={() => downloadSkuTreeCsv(skuRows)}
                  disabled={skuRows.length === 0}
                  className="flex items-center gap-1.5 px-3 py-2 rounded-lg text-xs font-medium border border-[#D8D9DA] text-[#505052] hover:bg-[#FAF9F7] transition-colors disabled:opacity-50"
                  style={font}
                  title="Export the current (filtered) tree as CSV. One row per external code, with canonical + vintage columns."
                >
                  <Download size={14} />
                  Export CSV
                </button>
              </div>
            </div>

            {/* SKU Tree */}
            <div className="overflow-x-auto">
              <table className="w-full text-xs" style={font}>
                <thead>
                  <tr className="border-b border-[#D8D9DA] bg-[#F5F4F2]">
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider w-8"></th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Canonical / Vintage / Code
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Source
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Variety
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Region
                    </th>
                    <th className="py-2 px-5 text-center text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Vintages
                    </th>
                    <th className="py-2 px-5 text-center text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Codes
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider" title="Source systems that have at least one external code for this canonical SKU. Vinsight = ops; DWS / ALM / ILG = wholesale channels; Access = legacy import.">
                      Sources
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Range
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {skusLoading ? (
                    <tr>
                      <td colSpan={9} className="px-5 py-8 text-center text-[#8A8A8D]">
                        Loading SKUs...
                      </td>
                    </tr>
                  ) : skuRows.length === 0 ? (
                    <tr>
                      <td colSpan={9} className="px-5 py-8 text-center text-[#8A8A8D]">
                        {skuSearch ? 'No SKUs match your search.' : 'No canonical SKUs in the database yet.'}
                      </td>
                    </tr>
                  ) : (
                    skuRows.flatMap((s) => {
                      const hasVintages = s.vintages.length > 0;
                      const isExpanded = expandedSkus.has(s.id);
                      const rows: React.ReactNode[] = [];

                      // Level 1: canonical row
                      rows.push(
                        <tr
                          key={`c-${s.id}`}
                          className={`border-b border-[#EBEBEC] ${hasVintages ? 'cursor-pointer' : ''} hover:bg-[#FAF9F7]`}
                          onClick={hasVintages ? () => setExpandedSkus(prev => {
                            const next = new Set(prev);
                            if (next.has(s.id)) next.delete(s.id); else next.add(s.id);
                            return next;
                          }) : undefined}
                        >
                          <td className="px-2 py-2.5 text-center w-8">
                            {hasVintages && (
                              <ChevronRight
                                size={14}
                                className={`text-[#8A8A8D] transition-transform ${isExpanded ? 'rotate-90' : ''}`}
                              />
                            )}
                          </td>
                          <td className="px-5 py-2.5 text-[#1F1F1F] font-semibold">{s.sku_name}</td>
                          <td className="px-5 py-2.5 text-[#505052]">
                            <Badge variant="neutral">canonical</Badge>
                          </td>
                          <td className="px-5 py-2.5 text-[#505052]">{s.variety || '\u2014'}</td>
                          <td className="px-5 py-2.5 text-[#505052]">{s.region || '\u2014'}</td>
                          <td className="px-5 py-2.5 text-[#505052] text-center">
                            <span className="inline-block text-[10px] bg-[#F0F0F0] text-[#666] px-1.5 py-0.5 rounded-full">
                              {s.vintage_count}
                            </span>
                          </td>
                          <td className="px-5 py-2.5 text-[#505052] text-center">
                            <span className="inline-block text-[10px] bg-[#F0F0F0] text-[#666] px-1.5 py-0.5 rounded-full">
                              {s.code_count}
                            </span>
                          </td>
                          <td className="px-5 py-2.5">
                            {(() => {
                              const sourceSet = new Set<string>();
                              s.vintages.forEach((v) => v.codes.forEach((c) => sourceSet.add(c.source)));
                              const ORDER = ['vinsight', 'moppity', 'dws', 'alm', 'ilg', 'access'];
                              const sorted = ORDER.filter((src) => sourceSet.has(src));
                              if (sorted.length === 0) return <span className="text-[#8A8A8D] text-[10px]">&mdash;</span>;
                              return (
                                <div className="flex flex-wrap gap-1">
                                  {sorted.map((src) => (
                                    <span
                                      key={src}
                                      className="inline-block text-[9px] uppercase font-medium px-1.5 py-0.5 rounded bg-[#EEF2F5] text-[#3F4855] border border-[#D8DEE3]"
                                    >
                                      {src === 'vinsight' ? 'VS'
                                        : src === 'moppity' ? 'MO'
                                        : src.toUpperCase()}
                                    </span>
                                  ))}
                                </div>
                              );
                            })()}
                          </td>
                          <td className="px-5 py-2.5 text-[#505052]">
                            {s.range ? (
                              <Badge variant="neutral">{s.range}</Badge>
                            ) : (
                              <span className="text-[#8A8A8D]">{'\u2014'}</span>
                            )}
                          </td>
                        </tr>
                      );

                      // Level 2 + 3: vintage rows, each collapsible into its codes
                      if (hasVintages && isExpanded) {
                        s.vintages.forEach((v, vIdx) => {
                          const vintageKey = `${s.id}|${v.vintage == null ? 'NV' : v.vintage}`;
                          const vintageExpanded = expandedVintages.has(vintageKey);
                          const vintageLabel = v.vintage == null ? 'NV' : String(v.vintage);
                          const hasCodes = v.codes.length > 0;

                          rows.push(
                            <tr
                              key={`c-${s.id}-v-${vIdx}`}
                              className={`border-b border-[#EBEBEC] bg-[#FAFAF8] ${hasCodes ? 'cursor-pointer' : ''} hover:bg-[#F5F4F2]`}
                              onClick={hasCodes ? () => setExpandedVintages(prev => {
                                const next = new Set(prev);
                                if (next.has(vintageKey)) next.delete(vintageKey); else next.add(vintageKey);
                                return next;
                              }) : undefined}
                            >
                              <td className="px-2 py-2 text-center w-8">
                                {hasCodes && (
                                  <ChevronRight
                                    size={12}
                                    className={`text-[#8A8A8D] transition-transform ${vintageExpanded ? 'rotate-90' : ''}`}
                                  />
                                )}
                              </td>
                              <td className="px-5 py-2 text-[#1F1F1F] text-[11px] pl-10">
                                <span className="font-mono font-semibold">{vintageLabel}</span>
                                {v.description && <span className="ml-2 text-[#8A8A8D]">{v.description}</span>}
                              </td>
                              <td className="px-5 py-2 text-[#8A8A8D] text-[11px]">vintage</td>
                              <td className="px-5 py-2"></td>
                              <td className="px-5 py-2"></td>
                              <td className="px-5 py-2"></td>
                              <td className="px-5 py-2 text-[#505052] text-center text-[11px]">
                                <span className="inline-block text-[10px] bg-[#F0F0F0] text-[#666] px-1.5 py-0.5 rounded-full">
                                  {v.codes.length}
                                </span>
                              </td>
                              <td className="px-5 py-2"></td>
                              <td className="px-5 py-2"></td>
                            </tr>
                          );

                          if (hasCodes && vintageExpanded) {
                            v.codes.forEach((code, cIdx) => {
                              rows.push(
                                <tr
                                  key={`c-${s.id}-v-${vIdx}-code-${cIdx}`}
                                  className="border-b border-[#EBEBEC] bg-[#F5F4F2]"
                                >
                                  <td className="px-2 py-1.5 w-8"></td>
                                  <td className="px-5 py-1.5 pl-16 font-mono text-[11px] text-[#1F1F1F]">
                                    {code.external_code}
                                  </td>
                                  <td className="px-5 py-1.5 text-[11px]">
                                    <Badge variant={code.source === 'moppity' ? 'success' : 'neutral'}>
                                      {VIEW_ONLY && code.source === 'moppity' ? 'internal' : code.source}
                                    </Badge>
                                  </td>
                                  <td className="px-5 py-1.5"></td>
                                  <td className="px-5 py-1.5"></td>
                                  <td className="px-5 py-1.5"></td>
                                  <td className="px-5 py-1.5"></td>
                                  <td className="px-5 py-1.5"></td>
                                  <td className="px-5 py-1.5"></td>
                                </tr>
                              );
                            });
                          }
                        });
                      }

                      return rows;
                    })
                  )}
                </tbody>
              </table>
            </div>

            {/* Footer */}
            <div className="p-4 bg-[#FAF9F7] border-t border-[#EBEBEC]">
              <p className="text-[11px] text-[#8A8A8D]" style={font}>
                <strong>Read-only.</strong> Hierarchy: master SKU &rarr; vintage &rarr; external code per source
                system. Master count is 102 active SKUs (97 wines + N/A + VOLUME REBATE + 3 documented exceptions). Dry goods are excluded from this view.
              </p>
            </div>
          </div>
        )}

        {/* ═══════════════════════════════════════════════════════════════ */}
        {/* TAB: Reps                                                     */}
        {/* ═══════════════════════════════════════════════════════════════ */}
        {activeTab === 'reps' && (
          <div className="bg-white rounded-xl border border-[#EBEBEC] shadow-sm overflow-hidden">
            {/* Card Header */}
            <div className="p-5 border-b border-[#EBEBEC] flex items-center justify-between">
              <div>
                <h2 className="text-base text-[#1F1F1F] font-semibold flex items-center gap-2" style={headingFont}>
                  <UserCog size={18} className="text-[#931220]" />
                  Representatives
                  <InfoTooltip
                    text="All sales representatives in the database. Customer count matches on the rep name. Use this to spot-check rep attribution after import."
                    size={10}
                    className="inline-flex ml-1"
                  />
                </h2>
                <p className="text-xs text-[#8A8A8D] mt-0.5" style={font}>
                  {repsTotal} reps total
                  {repRows.length < repsTotal && ` (showing ${repRows.length})`}
                </p>
              </div>
              <div className="relative">
                <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-[#8A8A8D]" />
                <input
                  type="text"
                  value={repSearch}
                  onChange={(e) => setRepSearch(e.target.value)}
                  placeholder="Search reps..."
                  className="pl-9 pr-3 py-2 bg-white border border-[#D8D9DA] rounded-lg text-sm text-[#1F1F1F] placeholder-[#8A8A8D] focus:outline-none focus:ring-2 focus:ring-[#931220]/20 focus:border-[#931220] w-64"
                  style={font}
                />
              </div>
            </div>

            {/* Reps Table */}
            <div className="overflow-x-auto">
              <table className="w-full text-xs" style={font}>
                <thead>
                  <tr className="border-b border-[#D8D9DA] bg-[#F5F4F2]">
                    <th className="py-2 px-2 text-center text-[#505052] font-semibold text-[11px] uppercase tracking-wider w-8">
                      {/* M17: expand chevron column */}
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Rep Name
                    </th>
                    <th className="py-2 px-3 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Short
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Primary Territory
                    </th>
                    <th className="py-2 px-3 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Group
                    </th>
                    <th className="py-2 px-5 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Customers
                    </th>
                    <th className="py-2 px-5 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Sales MAT
                      <InfoTooltip
                        text="Moving Annual Total \u2014 per-member sales attributed to this rep over the trailing 12 months. From Access SalesPerMemberMAT."
                        size={10}
                        className="inline-flex ml-1"
                      />
                    </th>
                    <th className="py-2 px-5 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Growth MAT
                      <InfoTooltip
                        text="Year-on-year MAT growth %. From Access SalesGrowthPerMemberMAT."
                        size={10}
                        className="inline-flex ml-1"
                      />
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Territory Coverage
                    </th>
                    <th className="py-2 px-5 text-center text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Active
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {repsLoading ? (
                    <tr>
                      <td colSpan={10} className="px-5 py-8 text-center text-[#8A8A8D]">
                        Loading reps...
                      </td>
                    </tr>
                  ) : repRows.length === 0 ? (
                    <tr>
                      <td colSpan={10} className="px-5 py-8 text-center text-[#8A8A8D]">
                        {repSearch ? 'No reps match your search.' : 'No reps in the database yet.'}
                      </td>
                    </tr>
                  ) : (
                    repRows.flatMap((r) => {
                      const isExpanded = expandedRepId === r.id;
                      const isLoadingDrill = !!repCustomersLoading[r.id];
                      const drillRows = repCustomers[r.id];
                      const drillError = repCustomersError[r.id];
                      const rows: React.ReactNode[] = [];

                      rows.push(
                        <tr
                          key={`rep-${r.id}`}
                          className="border-b border-[#EBEBEC] hover:bg-[#FAF9F7] cursor-pointer"
                          onClick={() => toggleRepExpand(r.id)}
                        >
                          <td className="px-2 py-2.5 text-center w-8">
                            <ChevronRight
                              size={14}
                              className={`text-[#8A8A8D] transition-transform ${isExpanded ? 'rotate-90' : ''}`}
                            />
                          </td>
                          <td className="px-5 py-2.5 text-[#1F1F1F] font-medium">
                            {r.full_rep_display || r.name}
                          </td>
                          <td className="px-3 py-2.5 text-[#8A8A8D] font-mono uppercase">
                            {r.short_rep || '\u2014'}
                          </td>
                          <td className="px-5 py-2.5 text-[#505052]">{r.territory_name || '\u2014'}</td>
                          <td className="px-3 py-2.5 text-[#505052]">{r.territory_group || '\u2014'}</td>
                          <td className="px-5 py-2.5 text-[#1F1F1F] text-right font-mono">{r.customer_count}</td>
                          <td className="px-5 py-2.5 text-[#1F1F1F] text-right font-mono">
                            {formatRepMatDollar(r.sales_per_member_mat)}
                          </td>
                          <td className="px-5 py-2.5 text-right font-mono">
                            {formatRepMatGrowth(r.sales_growth_per_member_mat)}
                          </td>
                          <td className="px-5 py-2.5 text-[#505052] max-w-[360px]">
                            {r.territories.length > 0 ? (
                              <span className="truncate inline-block" title={r.territories.join(', ')}>
                                {r.territories.slice(0, 3).join(', ')}
                                {r.territories.length > 3 && (
                                  <span className="ml-1.5 text-[10px] bg-[#F0F0F0] text-[#666] px-1.5 py-0.5 rounded-full">
                                    +{r.territories.length - 3}
                                  </span>
                                )}
                              </span>
                            ) : (
                              <span className="text-[#8A8A8D]">{'\u2014'}</span>
                            )}
                          </td>
                          <td className="px-5 py-2.5 text-center">
                            {r.active ? (
                              <Badge variant="success">Yes</Badge>
                            ) : (
                              <Badge variant="neutral">No</Badge>
                            )}
                          </td>
                        </tr>
                      );

                      if (isExpanded) {
                        rows.push(
                          <tr key={`rep-${r.id}-drill`} className="border-b border-[#EBEBEC] bg-[#FAFAF8]">
                            <td colSpan={10} className="px-5 py-3">
                              {isLoadingDrill ? (
                                <div className="text-[11px] text-[#8A8A8D] py-2">Loading customers...</div>
                              ) : drillError ? (
                                <div className="text-[11px] text-[#B42318] py-2">{drillError}</div>
                              ) : !drillRows || drillRows.length === 0 ? (
                                <div className="text-[11px] text-[#8A8A8D] py-2">
                                  No customers attributed to this rep yet.
                                </div>
                              ) : (
                                <div className="overflow-x-auto">
                                  <table className="w-full text-[11px]" style={font}>
                                    <thead>
                                      <tr className="border-b border-[#EBEBEC]">
                                        <th className="py-1.5 px-3 text-left text-[#505052] font-semibold uppercase tracking-wider">
                                          Customer
                                        </th>
                                        <th className="py-1.5 px-3 text-left text-[#505052] font-semibold uppercase tracking-wider">
                                          Suburb
                                        </th>
                                        <th className="py-1.5 px-3 text-left text-[#505052] font-semibold uppercase tracking-wider">
                                          Postcode
                                        </th>
                                        <th className="py-1.5 px-3 text-left text-[#505052] font-semibold uppercase tracking-wider">
                                          Channel
                                        </th>
                                        <th className="py-1.5 px-3 text-left text-[#505052] font-semibold uppercase tracking-wider">
                                          Territory
                                        </th>
                                        <th className="py-1.5 px-3 text-left text-[#505052] font-semibold uppercase tracking-wider">
                                          Last Transaction
                                        </th>
                                      </tr>
                                    </thead>
                                    <tbody>
                                      {drillRows.map((dc, idx) => (
                                        <tr
                                          key={`rep-${r.id}-c-${idx}`}
                                          className="border-b border-[#F0F0F0] last:border-b-0 hover:bg-[#F5F4F2]"
                                        >
                                          <td className="py-1.5 px-3 text-[#1F1F1F]">{dc.customer_name || '\u2014'}</td>
                                          <td className="py-1.5 px-3 text-[#505052]">{dc.suburb || '\u2014'}</td>
                                          <td className="py-1.5 px-3 text-[#505052] font-mono">{dc.postcode || '\u2014'}</td>
                                          <td className="py-1.5 px-3 text-[#505052]">{dc.channel || '\u2014'}</td>
                                          <td className="py-1.5 px-3 text-[#505052]">{dc.territory_name || '\u2014'}</td>
                                          <td className="py-1.5 px-3 text-[#505052] font-mono">{dc.last_txn_date || '\u2014'}</td>
                                        </tr>
                                      ))}
                                    </tbody>
                                  </table>
                                </div>
                              )}
                            </td>
                          </tr>
                        );
                      }

                      return rows;
                    })
                  )}
                </tbody>
              </table>
            </div>

            {/* Footer */}
            <div className="p-4 bg-[#FAF9F7] border-t border-[#EBEBEC]">
              <p className="text-[11px] text-[#8A8A8D]" style={font}>
                <strong>Read-only view.</strong> 31 canonical (DWS-active) representatives from
                the Access Representative master. Per-rep MAT (Moving Annual Total) sales + growth
                metrics surfaced from accdb. Append <code>?include_allchannel=true</code> to the
                <code> /api/reps </code>URL to also see all-channel reps observed only in
                customer records.
              </p>
            </div>
          </div>
        )}

        {/* ═══════════════════════════════════════════════════════════════ */}
        {/* TAB: Territories                                              */}
        {/* ═══════════════════════════════════════════════════════════════ */}
        {activeTab === 'territories' && (
          <div className="bg-white rounded-xl border border-[#EBEBEC] shadow-sm overflow-hidden">
            {/* Card Header */}
            <div className="p-5 border-b border-[#EBEBEC] flex items-center justify-between">
              <div>
                <h2 className="text-base text-[#1F1F1F] font-semibold flex items-center gap-2" style={headingFont}>
                  <MapIcon size={18} className="text-[#931220]" />
                  Territories
                  <InfoTooltip
                    text="Master territories. Customer count uses a case-insensitive match against the customer's territory name to surface drift. Unmatched drift shown below."
                    size={10}
                    className="inline-flex ml-1"
                  />
                </h2>
                <p className="text-xs text-[#8A8A8D] mt-0.5" style={font}>
                  {territoriesTotal} canonical territories
                  {unmatchedTerritories.length > 0 && (
                    <>
                      {' · '}
                      <span className="text-[#B42318]">
                        {unmatchedTerritories.length} drift value{unmatchedTerritories.length === 1 ? '' : 's'} in customers
                      </span>
                    </>
                  )}
                </p>
              </div>
              <div className="relative">
                <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-[#8A8A8D]" />
                <input
                  type="text"
                  value={territorySearch}
                  onChange={(e) => setTerritorySearch(e.target.value)}
                  placeholder="Search territories..."
                  className="pl-9 pr-3 py-2 bg-white border border-[#D8D9DA] rounded-lg text-sm text-[#1F1F1F] placeholder-[#8A8A8D] focus:outline-none focus:ring-2 focus:ring-[#931220]/20 focus:border-[#931220] w-64"
                  style={font}
                />
              </div>
            </div>

            {/* Territories Table */}
            <div className="overflow-x-auto">
              <table className="w-full text-xs" style={font}>
                <thead>
                  <tr className="border-b border-[#D8D9DA] bg-[#F5F4F2]">
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Territory Name
                    </th>
                    <th className="py-2 px-5 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Customers
                    </th>
                    <th className="py-2 px-5 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Reps Assigned
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Rep Names
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {territoriesLoading ? (
                    <tr>
                      <td colSpan={4} className="px-5 py-8 text-center text-[#8A8A8D]">
                        Loading territories...
                      </td>
                    </tr>
                  ) : territoryRows.length === 0 ? (
                    <tr>
                      <td colSpan={4} className="px-5 py-8 text-center text-[#8A8A8D]">
                        {territorySearch ? 'No territories match your search.' : 'No territories in the database yet.'}
                      </td>
                    </tr>
                  ) : (
                    territoryRows.map((t) => (
                      <tr key={t.id} className="border-b border-[#EBEBEC] hover:bg-[#FAF9F7]">
                        <td className="px-5 py-2.5 text-[#1F1F1F] font-medium">{t.name}</td>
                        <td className="px-5 py-2.5 text-[#1F1F1F] text-right font-mono">{t.customer_count}</td>
                        <td className="px-5 py-2.5 text-[#1F1F1F] text-right font-mono">{t.rep_count}</td>
                        <td className="px-5 py-2.5 text-[#505052] max-w-[420px]">
                          {t.rep_names.length > 0 ? (
                            <span className="truncate inline-block" title={t.rep_names.join(', ')}>
                              {t.rep_names.slice(0, 3).join(', ')}
                              {t.rep_names.length > 3 && (
                                <span className="ml-1.5 text-[10px] bg-[#F0F0F0] text-[#666] px-1.5 py-0.5 rounded-full">
                                  +{t.rep_names.length - 3}
                                </span>
                              )}
                            </span>
                          ) : (
                            <span className="text-[#8A8A8D]">{'\u2014'}</span>
                          )}
                        </td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>

            {/* Drift panel */}
            {unmatchedTerritories.length > 0 && (
              <div className="border-t border-[#EBEBEC] bg-[#FFFAF0]">
                <button
                  onClick={() => setShowUnmatched((v) => !v)}
                  className="w-full flex items-center justify-between px-5 py-3 text-left hover:bg-[#FFF4E0] transition-colors"
                  style={font}
                >
                  <div className="flex items-center gap-2">
                    <AlertTriangle size={14} className="text-[#B54708]" />
                    <span className="text-xs font-semibold text-[#B54708]">
                      Drift: {unmatchedTerritories.length} customer territory value{unmatchedTerritories.length === 1 ? '' : 's'} not in the master territory list
                    </span>
                  </div>
                  <ChevronRight
                    size={14}
                    className={`text-[#B54708] transition-transform ${showUnmatched ? 'rotate-90' : ''}`}
                  />
                </button>
                {showUnmatched && (
                  <div className="px-5 pb-4">
                    <table className="w-full text-xs" style={font}>
                      <thead>
                        <tr className="border-b border-[#F5DFA7]">
                          <th className="py-1.5 text-left text-[#B54708] font-semibold text-[11px] uppercase tracking-wider">
                            Customer territory_name
                          </th>
                          <th className="py-1.5 text-right text-[#B54708] font-semibold text-[11px] uppercase tracking-wider">
                            Customers affected
                          </th>
                        </tr>
                      </thead>
                      <tbody>
                        {unmatchedTerritories.map((u) => (
                          <tr key={u.name} className="border-b border-[#F5DFA7]/40">
                            <td className="py-1.5 text-[#1F1F1F] font-mono">{u.name}</td>
                            <td className="py-1.5 text-[#1F1F1F] text-right font-mono">{u.customer_count}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}
              </div>
            )}

            {/* Footer */}
            <div className="p-4 bg-[#FAF9F7] border-t border-[#EBEBEC]">
              <p className="text-[11px] text-[#8A8A8D]" style={font}>
                <strong>Read-only view.</strong> Canonical territories are the source of truth. Drift values in the panel above
                need case-normalisation or an admin-team merge decision.
              </p>
            </div>
          </div>
        )}

        {/* ═══════════════════════════════════════════════════════════════ */}
        {/* TAB: Unmatched Products (BUG-81)                              */}
        {/* ═══════════════════════════════════════════════════════════════ */}
        {activeTab === 'unmatched' && (
          <div className="bg-white rounded-xl border border-[#EBEBEC] shadow-sm overflow-hidden">
            {/* Card Header */}
            <div className="p-5 border-b border-[#EBEBEC]">
              <h2 className="text-base text-[#1F1F1F] font-semibold flex items-center gap-2" style={headingFont}>
                <HelpCircle size={18} className="text-[#B54708]" />
                Unmatched Products
                <InfoTooltip
                  text="DWS / ALM upload rows whose SKU code didn't match any existing sku. The row still lands in sales_transaction with sku_id=NULL so revenue isn't lost, but the product won't appear on the SKUs tab or roll into canonical reports until the owner maps it via the upload wizard."
                  size={10}
                  className="inline-flex ml-1"
                />
              </h2>
              <p className="text-xs text-[#8A8A8D] mt-0.5" style={font}>
                {unmatchedCodes.length} unique code{unmatchedCodes.length === 1 ? '' : 's'} from ETL dead-letter ·{' '}
                <span className={totalOrphanRows > 0 ? 'text-[#B42318] font-semibold' : ''}>
                  {totalOrphanRows} live orphan row{totalOrphanRows === 1 ? '' : 's'}
                </span>{' '}
                in sales_transaction
              </p>
            </div>

            {/* Orphan summary by source (if any) */}
            {orphanSummary.length > 0 && (
              <div className="px-5 py-3 bg-[#FEF6EE] border-b border-[#F5DFA7]">
                <div className="flex items-center gap-2 mb-2">
                  <AlertTriangle size={14} className="text-[#B54708]" />
                  <span className="text-xs font-semibold text-[#B54708]" style={font}>
                    Live orphan rows — sales_transaction.sku_id IS NULL
                  </span>
                </div>
                <table className="w-full text-xs" style={font}>
                  <thead>
                    <tr className="border-b border-[#F5DFA7]">
                      <th className="py-1.5 text-left text-[#B54708] font-semibold text-[11px] uppercase tracking-wider">
                        Source
                      </th>
                      <th className="py-1.5 text-right text-[#B54708] font-semibold text-[11px] uppercase tracking-wider">
                        Rows
                      </th>
                      <th className="py-1.5 text-left text-[#B54708] font-semibold text-[11px] uppercase tracking-wider px-3">
                        First Sale
                      </th>
                      <th className="py-1.5 text-left text-[#B54708] font-semibold text-[11px] uppercase tracking-wider">
                        Last Sale
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {orphanSummary.map((s) => (
                      <tr key={s.source_system} className="border-b border-[#F5DFA7]/40">
                        <td className="py-1.5 text-[#1F1F1F] font-mono">{s.source_system || '—'}</td>
                        <td className="py-1.5 text-[#1F1F1F] text-right font-mono">{s.orphan_count}</td>
                        <td className="py-1.5 text-[#505052] font-mono px-3">{s.first_sale || '—'}</td>
                        <td className="py-1.5 text-[#505052] font-mono">{s.last_sale || '—'}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
                {orphanSamples.length > 0 && (
                  <div className="mt-2">
                    <button
                      onClick={() => setShowOrphanSamples((v) => !v)}
                      className="text-[11px] font-semibold text-[#B54708] hover:underline"
                      style={font}
                    >
                      {showOrphanSamples ? 'Hide' : 'Show'} {orphanSamples.length} most recent orphan row
                      {orphanSamples.length === 1 ? '' : 's'} →
                    </button>
                    {showOrphanSamples && (
                      <table className="w-full text-xs mt-2" style={font}>
                        <thead>
                          <tr className="border-b border-[#F5DFA7]">
                            <th className="py-1 text-left text-[#B54708] font-semibold text-[10px] uppercase">Date</th>
                            <th className="py-1 text-left text-[#B54708] font-semibold text-[10px] uppercase px-3">Source</th>
                            <th className="py-1 text-left text-[#B54708] font-semibold text-[10px] uppercase">Customer</th>
                            <th className="py-1 text-right text-[#B54708] font-semibold text-[10px] uppercase px-3">Qty</th>
                            <th className="py-1 text-right text-[#B54708] font-semibold text-[10px] uppercase">Revenue</th>
                            <th className="py-1 text-left text-[#B54708] font-semibold text-[10px] uppercase px-3">Source Ref</th>
                          </tr>
                        </thead>
                        <tbody>
                          {orphanSamples.map((o) => (
                            <tr key={o.transaction_id} className="border-b border-[#F5DFA7]/40">
                              <td className="py-1 text-[#1F1F1F] font-mono">{o.sale_date}</td>
                              <td className="py-1 text-[#505052] font-mono px-3">{o.source_system}</td>
                              <td className="py-1 text-[#1F1F1F]">{o.customer_name || <span className="text-[#B42318]">—</span>}</td>
                              <td className="py-1 text-right font-mono px-3">{o.quantity}</td>
                              <td className="py-1 text-right font-mono">
                                {o.net_revenue !== null ? formatCurrency(o.net_revenue) : '—'}
                              </td>
                              <td className="py-1 text-[#8A8A8D] font-mono text-[10px] px-3 truncate max-w-[260px]" title={o.source_ref || ''}>
                                {o.source_ref || '—'}
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    )}
                  </div>
                )}
              </div>
            )}

            {/* Unmatched codes from dead_letter */}
            <div className="overflow-x-auto">
              <table className="w-full text-xs" style={font}>
                <thead>
                  <tr className="border-b border-[#D8D9DA] bg-[#F5F4F2]">
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      External Code
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Source
                    </th>
                    <th className="py-2 px-5 text-right text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Occurrences
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      First Seen
                    </th>
                    <th className="py-2 px-5 text-left text-[#505052] font-semibold text-[11px] uppercase tracking-wider">
                      Last Seen
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {unmatchedLoading ? (
                    <tr>
                      <td colSpan={5} className="px-5 py-8 text-center text-[#8A8A8D]">
                        Loading unmatched products...
                      </td>
                    </tr>
                  ) : unmatchedCodes.length === 0 ? (
                    <tr>
                      <td colSpan={5} className="px-5 py-8 text-center text-[#8A8A8D]">
                        {totalOrphanRows === 0
                          ? 'No unmatched products. All DWS and ALM SKU codes have matched successfully.'
                          : 'No dead-letter code entries — but live orphan rows exist (see panel above).'}
                      </td>
                    </tr>
                  ) : (
                    unmatchedCodes.map((u) => (
                      <tr key={`${u.source}-${u.external_code}`} className="border-b border-[#EBEBEC] hover:bg-[#FAF9F7]">
                        <td className="px-5 py-2.5 text-[#1F1F1F] font-mono font-medium">{u.external_code}</td>
                        <td className="px-5 py-2.5 text-[#505052] font-mono">{u.source}</td>
                        <td className="px-5 py-2.5 text-[#1F1F1F] text-right font-mono">{u.occurrences}</td>
                        <td className="px-5 py-2.5 text-[#505052] font-mono text-[11px]">
                          {u.first_seen ? u.first_seen.slice(0, 10) : '—'}
                        </td>
                        <td className="px-5 py-2.5 text-[#505052] font-mono text-[11px]">
                          {u.last_seen ? u.last_seen.slice(0, 10) : '—'}
                        </td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>

            {/* Footer */}
            <div className="p-4 bg-[#FAF9F7] border-t border-[#EBEBEC]">
              <p className="text-[11px] text-[#8A8A8D]" style={font}>
                <strong>Read-only view.</strong> Codes listed above were logged by the DWS / ALM import when the SKU lookup
                (direct code → fuzzy description match) returned no match. Revenue is still captured but the product won&apos;t
                appear on the SKUs tab until the code is mapped to a canonical sku. Use the upload wizard on a fresh file to
                map these — no auto-linking runs here.
              </p>
            </div>
          </div>
        )}
      </div>
    </AppLayout>
  );
}
