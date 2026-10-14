'use client';

import { useState, useMemo, useCallback, useRef, useEffect } from 'react';
import MetricCard from './MetricCard';
import Badge from './Badge';
import {
  DollarSign,
  TrendingUp,
  Download,
  RotateCcw,
  Grape,
  AlertTriangle,
  CheckCircle,
  Loader2,
  Upload,
  X,
  ChevronDown,
  Table,
} from 'lucide-react';
import InfoTooltip from './InfoTooltip';

// ─── Types ───────────────────────────────────────────────────────────────

interface GrapeComponent {
  variety: string;
  region: string;
  vintage: number;
  color: string;
  proportion: number;
}

interface SkuData {
  sku_id: number;
  sku_code: string;
  item_description: string;
  variety: string | null;
  region: string | null;
  vintage: number | null;
  base_wholesale: number;
  transfer_cost: number;
  range_name: string | null;
  total_revenue_12m: number;
  total_qty_12m: number;
  grape_components: GrapeComponent[];
}

interface WhatIfRule {
  region: string | null;
  color: string | null;
  grade: number | null;
  variety: string | null;
  vintage: number;
  price_per_ton: number;
}

export interface WhatIfBaseData {
  skus: SkuData[];
  grape_price_rules: WhatIfRule[];
  regions: string[];
  varieties: string[];
  vintages: number[];
}

interface CalculatedSku extends SkuData {
  accounting_cogs: number;
  economic_cogs: number;
  gp_transfer: number;
  gp_wholesale: number;
  gp_pct_transfer: number;
  gp_pct_wholesale: number;
  avg_wholesale_price: number;
  delta_gp_pct: number;
  has_economic_price: boolean;
}

interface GrapePriceCalculatorProps {
  data: WhatIfBaseData;
}

// ─── Constants ───────────────────────────────────────────────────────────

const STYLES = ['Red', 'White', 'Rose', 'Sparkling'] as const;
type StyleOption = typeof STYLES[number];

// Cosmetic VIEW_ONLY demo flag — hides the persist controls (Save scenario /
// Apply to Data) that write beyond the local view. The calculator itself stays
// fully interactive. Unset on the live editor => buttons render as before.
const VIEW_ONLY = process.env.NEXT_PUBLIC_VIEW_ONLY === 'true';

const STYLE_TO_COLOR: Record<string, string> = {
  'Red': 'red',
  'White': 'white',
  'Rose': 'rose',
  'Sparkling': 'sparkling',
};

const RANGE_TO_GRADE: Record<string, number> = {
  'MOPPITY RESERVE': 1, 'COPPABELLA SIRIUS': 1, 'ATRIUS': 1,
  'COPPABELLA CREST': 2, 'BLOCK': 2, 'MOPPITY ESTATE': 2, 'MV EXCLUSIVE': 2,
  'LOCK & KEY': 3, 'Lock & Key': 3, 'COPPABELLA PROCELLA': 3,
  'OPPABELLA PROCELLA': 3, 'TWELVE SIGNS': 3, 'Cato': 3, 'Crafted': 3, 'OTHER': 3,
};

const COLUMN_TOOLTIPS: Record<string, string> = {
  'Wine': 'Product name, SKU code, variety and region',
  'Wholesale': 'Base wholesale price per case (AUD)',
  'Transfer': 'Transfer cost per case from Vinsight (accounting COGS)',
  'Econ COGS': 'Economic cost — calculated from your what-if grape prices',
  'GP% Transfer': 'Gross profit % using transfer price as cost basis',
  'GP% Wholesale': 'Gross profit % using actual average wholesale selling price',
  'Delta': 'Difference between Economic GP% (transfer) and Accounting GP%',
  'Revenue': 'Total revenue from this SKU in the last 12 months',
};

// ─── Cascade Logic ───────────────────────────────────────────────────────

function getEffectiveGrapePrice(
  rules: WhatIfRule[],
  region: string,
  color: string,
  grade: number | null,
  variety: string,
  vintage: number,
): number {
  const exactMatch = findBestRule(rules, region, color, grade, variety, vintage);
  if (exactMatch > 0) return exactMatch;

  const allVintages = Array.from(new Set(rules.map(r => r.vintage)));
  for (const v of allVintages) {
    if (v === vintage) continue;
    const fallback = findBestRule(rules, region, color, grade, variety, v);
    if (fallback > 0) return fallback;
  }

  return 0;
}

function findBestRule(
  rules: WhatIfRule[],
  region: string,
  color: string,
  grade: number | null,
  variety: string,
  vintage: number,
): number {
  const matching = rules.filter(rule =>
    rule.vintage === vintage &&
    (rule.region === null || rule.region === region) &&
    (rule.color === null || rule.color === color) &&
    (rule.grade === null || rule.grade === grade) &&
    (rule.variety === null || rule.variety === variety)
  );

  matching.sort((a, b) => {
    const score = (r: WhatIfRule) =>
      [r.region, r.color, r.grade, r.variety].filter(v => v !== null).length;
    return score(b) - score(a);
  });

  return matching.length > 0 ? matching[0].price_per_ton : 0;
}

function deriveGrade(rangeName: string | null): number | null {
  if (!rangeName) return null;
  return RANGE_TO_GRADE[rangeName] ?? null;
}

const TONNES_PER_CASE = 1 / 80;

function calculateEconomicCogs(
  rules: WhatIfRule[],
  components: GrapeComponent[],
  grade: number | null,
): { cogs: number; hasPrice: boolean } {
  let weightedPrice = 0;
  let hasAnyPrice = false;
  for (const comp of components) {
    const price = getEffectiveGrapePrice(
      rules, comp.region, comp.color, grade, comp.variety, comp.vintage
    );
    if (price > 0) hasAnyPrice = true;
    weightedPrice += price * comp.proportion;
  }
  return { cogs: weightedPrice * TONNES_PER_CASE, hasPrice: hasAnyPrice };
}

// ─── Multi-Select Dropdown ──────────────────────────────────────────────

interface MultiSelectProps {
  label: string;
  options: string[];
  selected: string[];
  onChange: (selected: string[]) => void;
  placeholder?: string;
}

function MultiSelect({ label, options, selected, onChange, placeholder }: MultiSelectProps) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  const allSelected = selected.length === options.length;
  const noneSelected = selected.length === 0;

  const toggleOption = (opt: string) => {
    if (selected.includes(opt)) {
      onChange(selected.filter(s => s !== opt));
    } else {
      onChange([...selected, opt]);
    }
  };

  const toggleAll = () => {
    if (allSelected) {
      onChange([]);
    } else {
      onChange([...options]);
    }
  };

  const displayText = noneSelected
    ? (placeholder || `All ${label}`)
    : allSelected
      ? `All ${label}`
      : selected.length <= 2
        ? selected.join(', ')
        : `${selected.length} selected`;

  return (
    <div ref={ref} className="relative">
      <label className="block text-[10px] font-medium text-[#505052] mb-1" style={{ fontFamily: 'Inter, sans-serif' }}>
        {label}
      </label>
      <button
        onClick={() => setOpen(!open)}
        className={`w-full flex items-center justify-between px-3 py-2 text-xs border rounded-lg transition-colors text-left ${
          open ? 'border-[#931220] ring-1 ring-[#931220]/30' : 'border-[#D8D9DA] hover:border-[#931220]/40'
        } bg-white text-[#1F1F1F]`}
        style={{ fontFamily: 'Inter, sans-serif' }}
      >
        <span className={noneSelected ? 'text-[#505052]/50' : ''}>{displayText}</span>
        <ChevronDown size={14} className={`text-[#505052] transition-transform ${open ? 'rotate-180' : ''}`} />
      </button>
      {open && (
        <div className="absolute z-50 mt-1 w-full bg-white border border-[#D8D9DA] rounded-lg shadow-lg max-h-52 overflow-y-auto">
          <button
            onClick={toggleAll}
            className="w-full px-3 py-1.5 text-left text-xs hover:bg-[#931220]/5 border-b border-[#D8D9DA]/50 flex items-center gap-2"
          >
            <span className={`w-3.5 h-3.5 rounded border flex items-center justify-center flex-shrink-0 ${
              allSelected ? 'bg-[#931220] border-[#931220]' : 'border-[#D8D9DA]'
            }`}>
              {allSelected && <CheckCircle size={10} className="text-white" />}
            </span>
            <span className="font-medium text-[#505052]">Select All</span>
          </button>
          {options.map(opt => {
            const isSelected = selected.includes(opt);
            return (
              <button
                key={opt}
                onClick={() => toggleOption(opt)}
                className="w-full px-3 py-1.5 text-left text-xs hover:bg-[#931220]/5 flex items-center gap-2"
              >
                <span className={`w-3.5 h-3.5 rounded border flex items-center justify-center flex-shrink-0 ${
                  isSelected ? 'bg-[#931220] border-[#931220]' : 'border-[#D8D9DA]'
                }`}>
                  {isSelected && <CheckCircle size={10} className="text-white" />}
                </span>
                <span className="text-[#1F1F1F]">{opt}</span>
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

// ─── Component ───────────────────────────────────────────────────────────

export default function GrapePriceCalculator({ data }: GrapePriceCalculatorProps) {
  const [whatIfRules, setWhatIfRules] = useState<WhatIfRule[]>(
    data.grape_price_rules.map(r => ({ ...r }))
  );
  // Multi-select filter state
  const [selectedRegions, setSelectedRegions] = useState<string[]>([...data.regions]);
  const [selectedStyles, setSelectedStyles] = useState<string[]>([...STYLES]);
  const [selectedVarieties, setSelectedVarieties] = useState<string[]>([...data.varieties]);
  const [selectedVintages, setSelectedVintages] = useState<string[]>(
    data.vintages.map(String)
  );
  // New grape price input
  const [newPriceInput, setNewPriceInput] = useState('');

  const [searchTerm, setSearchTerm] = useState('');
  const [sortKey, setSortKey] = useState<string>('total_revenue_12m');
  const [sortDesc, setSortDesc] = useState(true);
  const [showAll, setShowAll] = useState(false);
  const [showHowTo, setShowHowTo] = useState(true);
  const [resetKey, setResetKey] = useState(0);
  // W1: Selling price adjustment (global %)
  const [priceAdjustPct, setPriceAdjustPct] = useState(0);
  // W3: Scenario save/load
  const [scenarioName, setScenarioName] = useState('');
  const [showSaveModal, setShowSaveModal] = useState(false);
  // Apply to data state
  const [applyStatus, setApplyStatus] = useState<'idle' | 'loading' | 'success' | 'error'>('idle');
  const [applyResult, setApplyResult] = useState<{ sales_recalculated: number; overall_gp_pct: number } | null>(null);
  const [showApplyConfirm, setShowApplyConfirm] = useState(false);
  // Underpinning table visibility
  const [showUnderpinning, setShowUnderpinning] = useState(true);

  // Calculate margins for all SKUs
  const calculatedSkus = useMemo<CalculatedSku[]>(() => {
    const priceMult = 1 + priceAdjustPct / 100;
    return data.skus.map(sku => {
      const grade = deriveGrade(sku.range_name);
      let { cogs: economicCogs, hasPrice } = calculateEconomicCogs(whatIfRules, sku.grape_components, grade);
      // Fallback: if traceability components didn't match, try SKU metadata
      if (!hasPrice && sku.variety && sku.region) {
        const fallbackComp: GrapeComponent[] = [{
          variety: sku.variety,
          region: sku.region,
          vintage: sku.vintage || 2024,
          color: ['Chardonnay','Riesling','Sauvignon Blanc','Pinot Gris','Pinot Grigio','Moscato','Prosecco','Semillon'].some(w => (sku.variety||'').includes(w)) ? 'white' : 'red',
          proportion: 1.0,
        }];
        const fallback = calculateEconomicCogs(whatIfRules, fallbackComp, grade);
        if (fallback.hasPrice) { economicCogs = fallback.cogs; hasPrice = true; }
      }
      const accountingCogs = sku.transfer_cost || 0;
      const price = (sku.base_wholesale || 0) * priceMult;

      // GP using transfer price (accounting cost basis)
      const gpTransfer = price - economicCogs;
      const gpPctTransfer = price > 0 ? (gpTransfer / price) * 100 : 0;

      // GP using actual average wholesale price
      const avgWholesalePrice = sku.total_qty_12m > 0
        ? sku.total_revenue_12m / sku.total_qty_12m
        : price;
      const gpWholesale = avgWholesalePrice - economicCogs;
      const gpPctWholesale = avgWholesalePrice >= 1 ? (gpWholesale / avgWholesalePrice) * 100 : 0;

      const gpAccounting = price - accountingCogs;
      const gpPctAccounting = price > 0 ? (gpAccounting / price) * 100 : 0;

      return {
        ...sku,
        accounting_cogs: accountingCogs,
        economic_cogs: economicCogs,
        gp_transfer: gpTransfer,
        gp_wholesale: gpWholesale,
        gp_pct_transfer: Math.round(gpPctTransfer * 10) / 10,
        gp_pct_wholesale: Math.round(gpPctWholesale * 10) / 10,
        avg_wholesale_price: Math.round(avgWholesalePrice * 100) / 100,
        delta_gp_pct: Math.round((gpPctTransfer - gpPctAccounting) * 10) / 10,
        has_economic_price: hasPrice,
      };
    });
  }, [data.skus, whatIfRules, priceAdjustPct]);

  // Check if any economic prices are set
  const hasAnyEconomicPrice = calculatedSkus.some(s => s.has_economic_price);

  // Filter and sort SKUs
  const filteredSkus = useMemo(() => {
    let result = [...calculatedSkus];
    if (searchTerm) {
      const term = searchTerm.toLowerCase();
      result = result.filter(s =>
        s.item_description?.toLowerCase().includes(term) ||
        s.sku_code?.toLowerCase().includes(term) ||
        s.variety?.toLowerCase().includes(term)
      );
    }
    result.sort((a, b) => {
      if (sortKey === 'item_description') {
        const aStr = a.item_description || '';
        const bStr = b.item_description || '';
        return sortDesc ? bStr.localeCompare(aStr) : aStr.localeCompare(bStr);
      }
      const aVal = (a as unknown as Record<string, number>)[sortKey] ?? 0;
      const bVal = (b as unknown as Record<string, number>)[sortKey] ?? 0;
      return sortDesc ? bVal - aVal : aVal - bVal;
    });
    return result;
  }, [calculatedSkus, searchTerm, sortKey, sortDesc]);

  // Summary KPIs
  const summary = useMemo(() => {
    const skusWithRevenue = calculatedSkus.filter(s => s.total_revenue_12m > 0);
    const totalRevenue = skusWithRevenue.reduce((sum, s) => sum + s.total_revenue_12m, 0);
    const totalGpTransfer = skusWithRevenue.reduce((sum, s) => sum + (s.gp_pct_transfer * s.total_revenue_12m / 100), 0);
    const totalGpWholesale = skusWithRevenue.reduce((sum, s) => sum + (s.gp_pct_wholesale * s.total_revenue_12m / 100), 0);
    const avgMarginTransfer = totalRevenue > 0 ? (totalGpTransfer / totalRevenue) * 100 : 0;
    const avgMarginWholesale = totalRevenue > 0 ? (totalGpWholesale / totalRevenue) * 100 : 0;
    // Also compute accounting GP% for comparison
    const totalGpAcct = skusWithRevenue.reduce((sum, s) => {
      const price = (s.base_wholesale || 0) * (1 + priceAdjustPct / 100);
      const gpPctAcct = price > 0 ? ((price - s.accounting_cogs) / price) * 100 : 0;
      return sum + (gpPctAcct * s.total_revenue_12m / 100);
    }, 0);
    const avgMarginAccounting = totalRevenue > 0 ? (totalGpAcct / totalRevenue) * 100 : 0;
    return { totalRevenue, avgMarginTransfer, avgMarginWholesale, avgMarginAccounting };
  }, [calculatedSkus, priceAdjustPct]);

  // Apply the new grape price to selected combinations
  const applyGrapePrice = useCallback(() => {
    const price = parseFloat(newPriceInput);
    if (isNaN(price) || price <= 0) return;

    // Clamp to reasonable range
    const clampedPrice = Math.min(Math.max(price, 0), 10000);

    // Build rules for each combination of selected filters
    const regionsToApply = selectedRegions.length > 0 ? selectedRegions : [null];
    const stylesToApply = selectedStyles.length > 0 ? selectedStyles.map(s => STYLE_TO_COLOR[s] || null) : [null];
    const varietiesToApply = selectedVarieties.length > 0 && selectedVarieties.length < data.varieties.length ? selectedVarieties : [null];
    const vintagesToApply = selectedVintages.length > 0
      ? selectedVintages.map(v => parseInt(v))
      : data.vintages;

    setWhatIfRules(prev => {
      let updated = [...prev];

      for (const vintage of vintagesToApply) {
        for (const region of regionsToApply) {
          for (const color of stylesToApply) {
            for (const variety of varietiesToApply) {
              // Check if rule already exists
              const existIdx = updated.findIndex(r =>
                r.vintage === vintage &&
                r.region === (region as string | null) &&
                r.color === (color as string | null) &&
                r.variety === (variety as string | null)
              );

              const newRule: WhatIfRule = {
                region: region as string | null,
                color: color as string | null,
                grade: null,
                variety: variety as string | null,
                vintage,
                price_per_ton: clampedPrice,
              };

              if (existIdx >= 0) {
                updated[existIdx] = newRule;
              } else {
                updated = [...updated, newRule];
              }
            }
          }
        }
      }

      return updated;
    });

    setNewPriceInput('');
  }, [newPriceInput, selectedRegions, selectedStyles, selectedVarieties, selectedVintages, data.varieties, data.vintages]);

  const removeRule = useCallback((index: number) => {
    setWhatIfRules(prev => prev.filter((_, i) => i !== index));
  }, []);

  // Reset to Vinsight default prices
  const revertToVinsight = useCallback(() => {
    setWhatIfRules(data.grape_price_rules.map(r => ({ ...r })));
    setPriceAdjustPct(0);
    setResetKey(k => k + 1);
  }, [data.grape_price_rules]);

  // W3: Scenario save/load
  const savedScenarios = useMemo(() => {
    try {
      const raw = localStorage.getItem('moppity_whatif_scenarios');
      return raw ? JSON.parse(raw) as Array<{ name: string; rules: WhatIfRule[]; priceAdjust: number }> : [];
    } catch { return []; }
  }, [resetKey]);

  const saveScenario = useCallback((name: string) => {
    const scenarios = [...savedScenarios, { name, rules: whatIfRules, priceAdjust: priceAdjustPct }];
    localStorage.setItem('moppity_whatif_scenarios', JSON.stringify(scenarios));
    setShowSaveModal(false);
    setScenarioName('');
    setResetKey(k => k + 1);
  }, [savedScenarios, whatIfRules, priceAdjustPct]);

  const loadScenario = useCallback((index: number) => {
    const scenario = savedScenarios[index];
    if (scenario) {
      setWhatIfRules(scenario.rules);
      setPriceAdjustPct(scenario.priceAdjust || 0);
      setResetKey(k => k + 1);
    }
  }, [savedScenarios]);

  const deleteScenario = useCallback((index: number) => {
    const scenarios = savedScenarios.filter((_, i) => i !== index);
    localStorage.setItem('moppity_whatif_scenarios', JSON.stringify(scenarios));
    setResetKey(k => k + 1);
  }, [savedScenarios]);

  const applyToData = useCallback(async () => {
    setApplyStatus('loading');
    setApplyResult(null);
    try {
      const rules = whatIfRules
        .filter(r => r.price_per_ton > 0)
        .map(r => ({
          region: r.region,
          color: r.color,
          grade: r.grade,
          variety: r.variety,
          vintage: r.vintage,
          price_per_ton: r.price_per_ton,
        }));

      const res = await fetch('/api/what-if', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rules }),
      });

      if (!res.ok) throw new Error('Failed to apply');
      const result = await res.json();
      setApplyResult({
        sales_recalculated: result.sales_recalculated,
        overall_gp_pct: result.summary.overall_gp_pct,
      });
      setApplyStatus('success');
      setTimeout(() => setApplyStatus('idle'), 5000);
    } catch {
      setApplyStatus('error');
      setTimeout(() => setApplyStatus('idle'), 3000);
    }
    setShowApplyConfirm(false);
  }, [whatIfRules]);

  const exportCSV = useCallback(() => {
    const headers = ['SKU Code', 'Description', 'Variety', 'Region', 'Vintage', 'Wholesale Price', 'Transfer Cost', 'Economic COGS', 'GP% Transfer', 'GP% Wholesale', 'Delta GP%', 'Revenue 12m'];
    const rows = filteredSkus.map(s => [
      s.sku_code, `"${s.item_description}"`, s.variety, s.region, s.vintage,
      s.base_wholesale.toFixed(2), s.accounting_cogs.toFixed(2), s.economic_cogs.toFixed(2),
      s.gp_pct_transfer.toFixed(1), s.gp_pct_wholesale.toFixed(1), s.delta_gp_pct.toFixed(1),
      s.total_revenue_12m.toFixed(2),
    ]);
    const csv = [headers, ...rows].map(r => r.join(',')).join('\n');
    const blob = new Blob([csv], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `what-if-scenario-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  }, [filteredSkus]);

  const toggleSort = (key: string) => {
    if (sortKey === key) setSortDesc(!sortDesc);
    else { setSortKey(key); setSortDesc(true); }
  };

  const fmt = (v: number) => {
    if (v >= 1_000_000) return `$${(v / 1_000_000).toFixed(1)}M`;
    if (v >= 1_000) return `$${(v / 1_000).toFixed(1)}K`;
    return `$${v.toFixed(0)}`;
  };

  // Format rule source label
  const getRuleSource = (rule: WhatIfRule): 'user' | 'vinsight' => {
    const original = data.grape_price_rules.find(r =>
      r.vintage === rule.vintage &&
      r.region === rule.region &&
      r.color === rule.color &&
      r.grade === rule.grade &&
      r.variety === rule.variety &&
      r.price_per_ton === rule.price_per_ton
    );
    return original ? 'vinsight' : 'user';
  };

  const displayLimit = showAll ? filteredSkus.length : 50;

  // Check if rules have changed from original
  const rulesChanged = useMemo(() => {
    if (whatIfRules.length !== data.grape_price_rules.length) return true;
    return whatIfRules.some((r, i) => {
      const orig = data.grape_price_rules[i];
      if (!orig) return true;
      return r.price_per_ton !== orig.price_per_ton ||
        r.region !== orig.region ||
        r.color !== orig.color ||
        r.variety !== orig.variety ||
        r.vintage !== orig.vintage;
    });
  }, [whatIfRules, data.grape_price_rules]);

  return (
    <div className="space-y-4" style={{ fontSize: '13px' }}>
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-xl text-[#1F1F1F] font-semibold" style={{ fontFamily: 'Cardo, serif' }}>
            What-If Calculator
          </h1>
          <p className="text-[#505052] text-xs mt-0.5" style={{ fontFamily: 'Inter, sans-serif' }}>
            Adjust grape prices and see instant margin impact across all SKUs
          </p>
        </div>
        <div className="flex items-center gap-2">
          {rulesChanged && (
            <button onClick={revertToVinsight}
              className="flex items-center gap-1.5 px-3 py-1.5 text-xs text-[#931220] border border-[#931220]/30 rounded-lg hover:bg-[#931220]/5 transition-colors">
              <RotateCcw size={14} /> Revert to Vinsight Prices
            </button>
          )}
          {!VIEW_ONLY && (
            <button onClick={() => setShowSaveModal(true)}
              className="flex items-center gap-1.5 px-3 py-1.5 text-xs text-[#505052] border border-[#D8D9DA] rounded-lg hover:bg-gray-50 transition-colors">
              Save
            </button>
          )}
          <button onClick={exportCSV}
            className="flex items-center gap-1.5 px-3 py-1.5 text-xs text-white bg-[#931220] rounded-lg hover:bg-[#7a0f1a] transition-colors">
            <Download size={14} /> Export CSV
          </button>
          {!VIEW_ONLY && (
            <button onClick={() => setShowApplyConfirm(true)}
              disabled={applyStatus === 'loading'}
              className={`flex items-center gap-1.5 px-4 py-1.5 text-xs rounded-lg transition-colors ${
                applyStatus === 'success'
                  ? 'bg-emerald-600 text-white'
                  : applyStatus === 'loading'
                  ? 'bg-[#931220]/60 text-white cursor-wait'
                  : 'bg-[#931220] text-white hover:bg-[#7a0f1a]'
              }`}>
              {applyStatus === 'loading' ? <><Loader2 size={14} className="animate-spin" /> Applying...</>
                : applyStatus === 'success' ? <><CheckCircle size={14} /> Applied</>
                : <><Upload size={14} /> Apply to Data</>}
            </button>
          )}
        </div>
      </div>

      {/* Grape Price Input Panel — 4 dropdown multi-selects + price input */}
      <div className="bg-white rounded-xl border border-[#D8D9DA] p-4 shadow-sm" style={{ fontFamily: 'Inter, sans-serif' }}>
        <div className="flex items-center justify-between mb-3">
          <h2 className="text-sm font-semibold text-[#1F1F1F]" style={{ fontFamily: 'Cardo, serif' }}>
            Set Grape Prices
          </h2>
          <InfoTooltip text="Select region, style, variety and vintage, then enter a $/ton price. The price applies to all matching combinations. More specific rules override general ones." />
        </div>
        <div className="grid grid-cols-5 gap-3 items-end">
          <MultiSelect
            label="Region"
            options={data.regions}
            selected={selectedRegions}
            onChange={setSelectedRegions}
            placeholder="All Regions"
          />
          <MultiSelect
            label="Style"
            options={[...STYLES]}
            selected={selectedStyles}
            onChange={(vals) => setSelectedStyles(vals as StyleOption[])}
            placeholder="All Styles"
          />
          <MultiSelect
            label="Variety"
            options={data.varieties}
            selected={selectedVarieties}
            onChange={setSelectedVarieties}
            placeholder="All Varieties"
          />
          <MultiSelect
            label="Vintage"
            options={data.vintages.map(String)}
            selected={selectedVintages}
            onChange={setSelectedVintages}
            placeholder="All Vintages"
          />
          <div>
            <label className="block text-[10px] font-medium text-[#505052] mb-1">Price ($/ton)</label>
            <div className="flex gap-2">
              <div className="relative flex-1">
                <span className="absolute left-2.5 top-1/2 -translate-y-1/2 text-[#505052] text-xs">$</span>
                <input
                  type="number"
                  value={newPriceInput}
                  onChange={e => setNewPriceInput(e.target.value)}
                  onKeyDown={e => e.key === 'Enter' && applyGrapePrice()}
                  placeholder="2,000"
                  min={0}
                  max={10000}
                  className="w-full text-right text-xs border border-[#D8D9DA] rounded-lg px-3 py-2 pl-6 text-[#1F1F1F] placeholder-[#D8D9DA] focus:outline-none focus:ring-1 focus:ring-[#931220]/50 focus:border-[#931220]"
                />
              </div>
              <button
                onClick={applyGrapePrice}
                disabled={!newPriceInput || isNaN(parseFloat(newPriceInput)) || parseFloat(newPriceInput) <= 0}
                className="px-4 py-2 text-xs font-medium text-white bg-[#931220] rounded-lg hover:bg-[#7a0f1a] transition-colors disabled:opacity-40 disabled:cursor-not-allowed whitespace-nowrap"
              >
                Set Price
              </button>
            </div>
          </div>
        </div>

        {/* Selection summary chips */}
        <div className="flex flex-wrap items-center gap-1.5 mt-3">
          <span className="text-[10px] text-[#505052]/60">Applying to:</span>
          {selectedRegions.length > 0 && selectedRegions.length < data.regions.length && (
            selectedRegions.map(r => (
              <span key={r} className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-[#931220]/8 text-[#931220] text-[10px] font-medium border border-[#931220]/15">
                {r}
                <button onClick={() => setSelectedRegions(prev => prev.filter(x => x !== r))} className="hover:text-[#7a0f1a]">
                  <X size={10} />
                </button>
              </span>
            ))
          )}
          {selectedRegions.length === 0 || selectedRegions.length === data.regions.length ? (
            <span className="inline-flex items-center px-2 py-0.5 rounded-full bg-gray-100 text-[#505052] text-[10px]">All Regions</span>
          ) : null}
          {selectedStyles.length > 0 && selectedStyles.length < STYLES.length && (
            selectedStyles.map(s => (
              <span key={s} className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-[#931220]/8 text-[#931220] text-[10px] font-medium border border-[#931220]/15">
                {s}
                <button onClick={() => setSelectedStyles(prev => prev.filter(x => x !== s))} className="hover:text-[#7a0f1a]">
                  <X size={10} />
                </button>
              </span>
            ))
          )}
          {selectedStyles.length === 0 || selectedStyles.length === STYLES.length ? (
            <span className="inline-flex items-center px-2 py-0.5 rounded-full bg-gray-100 text-[#505052] text-[10px]">All Styles</span>
          ) : null}
          {selectedVintages.length > 0 && selectedVintages.length < data.vintages.length && (
            selectedVintages.map(v => (
              <span key={v} className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-[#931220]/8 text-[#931220] text-[10px] font-medium border border-[#931220]/15">
                {v}
                <button onClick={() => setSelectedVintages(prev => prev.filter(x => x !== v))} className="hover:text-[#7a0f1a]">
                  <X size={10} />
                </button>
              </span>
            ))
          )}
          {selectedVintages.length === 0 || selectedVintages.length === data.vintages.length ? (
            <span className="inline-flex items-center px-2 py-0.5 rounded-full bg-gray-100 text-[#505052] text-[10px]">All Vintages</span>
          ) : null}
        </div>
      </div>

      {/* W1: Selling price adjustment */}
      <div className="flex items-center gap-3 bg-white rounded-lg border border-[#D8D9DA] px-4 py-2" style={{ fontFamily: 'Inter, sans-serif' }}>
        <span className="text-xs text-[#505052]">Selling price adjustment:</span>
        <input type="range" min={-30} max={30} step={1} value={priceAdjustPct}
          onChange={e => setPriceAdjustPct(parseInt(e.target.value))}
          className="w-32 accent-[#931220]" />
        <span className={`text-xs font-medium min-w-[40px] ${priceAdjustPct > 0 ? 'text-[#1B7A3D]' : priceAdjustPct < 0 ? 'text-[#B42318]' : 'text-[#505052]'}`}>
          {priceAdjustPct > 0 ? '+' : ''}{priceAdjustPct}%
        </span>
        {priceAdjustPct !== 0 && (
          <button onClick={() => setPriceAdjustPct(0)} className="text-[10px] text-[#931220] hover:underline">Reset</button>
        )}
        <InfoTooltip text="Adjust the wholesale selling price globally. E.g. +10% simulates a 10% price increase across all wines. Affects GP% calculations in the table below." className="ml-auto" />
      </div>

      {/* W3: Save scenario modal */}
      {showSaveModal && (
        <div className="fixed inset-0 bg-black/30 z-50 flex items-center justify-center" onClick={() => setShowSaveModal(false)}>
          <div className="bg-white rounded-xl p-6 shadow-xl max-w-sm w-full" onClick={e => e.stopPropagation()}>
            <h3 className="text-sm font-semibold text-[#1F1F1F] mb-3" style={{ fontFamily: 'Cardo, serif' }}>Save Scenario</h3>
            <input type="text" value={scenarioName} onChange={e => setScenarioName(e.target.value)}
              placeholder="Scenario name (e.g. Optimistic 2024)"
              className="w-full text-xs border border-[#D8D9DA] rounded-lg px-3 py-2 mb-3" autoFocus />
            <div className="flex gap-2 justify-end">
              <button onClick={() => setShowSaveModal(false)} className="text-xs px-3 py-1.5 text-[#505052] hover:bg-gray-50 rounded-lg">Cancel</button>
              <button onClick={() => saveScenario(scenarioName || `Scenario ${savedScenarios.length + 1}`)}
                className="text-xs px-3 py-1.5 bg-[#931220] text-white rounded-lg hover:bg-[#7a0f1a]">Save</button>
            </div>
            {savedScenarios.length > 0 && (
              <div className="mt-4 border-t border-[#D8D9DA] pt-3">
                <p className="text-[10px] text-[#505052] mb-2">Saved scenarios:</p>
                {savedScenarios.map((s, i) => (
                  <div key={i} className="flex items-center justify-between py-1">
                    <button onClick={() => { loadScenario(i); setShowSaveModal(false); }}
                      className="text-xs text-[#1F1F1F] hover:text-[#931220]">{s.name}</button>
                    <button onClick={() => deleteScenario(i)} className="text-[10px] text-[#B42318] hover:underline">Delete</button>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      )}

      {/* Apply to Data confirmation modal */}
      {showApplyConfirm && (
        <div className="fixed inset-0 bg-black/30 z-50 flex items-center justify-center" onClick={() => setShowApplyConfirm(false)}>
          <div className="bg-white rounded-xl p-6 shadow-xl max-w-sm w-full" onClick={e => e.stopPropagation()}>
            <h3 className="text-sm font-semibold text-[#1F1F1F] mb-2" style={{ fontFamily: 'Cardo, serif' }}>Apply Grape Prices to All Reports</h3>
            <p className="text-xs text-[#505052] mb-4">
              This will update the economic COGS across all {whatIfRules.filter(r => r.price_per_ton > 0).length} price rules and recalculate margins for all historical sales. Overview, Margin Analysis, and all other pages will reflect these prices.
            </p>
            <div className="flex gap-2 justify-end">
              <button onClick={() => setShowApplyConfirm(false)} className="text-xs px-3 py-1.5 text-[#505052] hover:bg-gray-50 rounded-lg">Cancel</button>
              <button onClick={applyToData}
                className="text-xs px-4 py-1.5 bg-[#931220] text-white rounded-lg hover:bg-[#7a0f1a]">Confirm &amp; Apply</button>
            </div>
          </div>
        </div>
      )}

      {/* Apply success banner */}
      {applyStatus === 'success' && applyResult && (
        <div className="bg-emerald-50 border border-emerald-200 rounded-lg px-4 py-2.5 flex items-center gap-2">
          <CheckCircle size={16} className="text-emerald-600 flex-shrink-0" />
          <span className="text-xs text-emerald-800">
            Applied — {applyResult.sales_recalculated.toLocaleString()} sales recalculated. Overall GP: {applyResult.overall_gp_pct}%
          </span>
        </div>
      )}

      {/* Warning when no economic prices set */}
      {!hasAnyEconomicPrice && (
        <div className="bg-amber-50 border border-amber-200 rounded-lg p-3 flex items-center gap-2">
          <AlertTriangle size={16} className="text-amber-600 flex-shrink-0" />
          <p className="text-xs text-amber-800" style={{ fontFamily: 'Inter, sans-serif' }}>
            Set grape prices above to see economic margins. Without prices, Economic COGS shows as $0.
          </p>
        </div>
      )}

      {/* KPI Summary */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3">
        <div className="relative">
          <MetricCard label="Total Revenue (12m)" value={fmt(summary.totalRevenue)} icon={<DollarSign size={18} />} />
          <InfoTooltip text="Sum of net revenue across all warehouses for the last 12 months." className="absolute top-3 right-3" />
        </div>
        <div className="relative">
          <MetricCard label="Avg GP% (Accounting)" value={`${summary.avgMarginAccounting.toFixed(1)}%`} icon={<TrendingUp size={18} />} />
          <InfoTooltip text="Revenue-weighted average gross profit using accounting COGS (transfer cost from Vinsight). This is what the books show." className="absolute top-3 right-3" />
        </div>
        <div className="relative">
          <MetricCard
            label="GP% (Transfer Price)"
            value={hasAnyEconomicPrice ? `${summary.avgMarginTransfer.toFixed(1)}%` : '--'}
            trend={hasAnyEconomicPrice && summary.avgMarginTransfer !== summary.avgMarginAccounting ? {
              value: Math.round(Math.abs(summary.avgMarginTransfer - summary.avgMarginAccounting) * 10) / 10,
              isPositive: summary.avgMarginTransfer > summary.avgMarginAccounting,
            } : undefined}
            icon={<Grape size={18} />}
          />
          <InfoTooltip text="Revenue-weighted GP% using economic grape prices against list wholesale price. Shows true margin at list price." className="absolute top-3 right-3" />
        </div>
        <div className="relative">
          <MetricCard
            label="GP% (Avg Wholesale)"
            value={hasAnyEconomicPrice ? `${summary.avgMarginWholesale.toFixed(1)}%` : '--'}
            trend={hasAnyEconomicPrice && summary.avgMarginWholesale !== summary.avgMarginAccounting ? {
              value: Math.round(Math.abs(summary.avgMarginWholesale - summary.avgMarginAccounting) * 10) / 10,
              isPositive: summary.avgMarginWholesale > summary.avgMarginAccounting,
            } : undefined}
            icon={<DollarSign size={18} />}
          />
          <InfoTooltip text="Revenue-weighted GP% using economic grape prices against actual average selling price (revenue / qty). Shows real-world margin." className="absolute top-3 right-3" />
        </div>
      </div>

      {/* How-to guide */}
      {showHowTo && (
        <div className="bg-[#931220]/5 border border-[#931220]/15 rounded-lg p-3 relative" style={{ fontFamily: 'Inter, sans-serif' }}>
          <button onClick={() => setShowHowTo(false)}
            className="absolute top-2 right-3 text-[#505052] hover:text-[#1F1F1F] text-sm leading-none">&times;</button>
          <h3 className="text-xs font-semibold text-[#1F1F1F] mb-1.5">How it works</h3>
          <div className="grid grid-cols-4 gap-3 text-[11px] text-[#505052]">
            <div><span className="font-medium text-[#1F1F1F]">1. Select filters</span><p className="mt-0.5">Pick region, style, variety, vintage</p></div>
            <div><span className="font-medium text-[#1F1F1F]">2. Enter price</span><p className="mt-0.5">$/ton for the selected combination</p></div>
            <div><span className="font-medium text-[#1F1F1F]">3. See impact</span><p className="mt-0.5">GP shown at transfer price &amp; avg wholesale</p></div>
            <div><span className="font-medium text-[#1F1F1F]">4. Apply</span><p className="mt-0.5">Push to all reports or revert to Vinsight</p></div>
          </div>
          <p className="text-[10px] text-[#505052]/60 mt-1.5">More specific rules (e.g. region + variety) override general ones (e.g. region only).</p>
        </div>
      )}

      {/* Underpinning Values Table */}
      <div className="bg-white rounded-xl border border-[#D8D9DA] shadow-sm">
        <button
          onClick={() => setShowUnderpinning(!showUnderpinning)}
          className="w-full flex items-center justify-between px-4 py-3 hover:bg-gray-50 transition-colors rounded-xl"
        >
          <div className="flex items-center gap-2">
            <Table size={16} className="text-[#931220]" />
            <h2 className="text-sm font-semibold text-[#1F1F1F]" style={{ fontFamily: 'Cardo, serif' }}>
              Active Grape Price Rules
            </h2>
            <span className="text-[10px] text-[#505052] bg-gray-100 rounded-full px-2 py-0.5">
              {whatIfRules.length} rules
            </span>
          </div>
          <ChevronDown size={16} className={`text-[#505052] transition-transform ${showUnderpinning ? 'rotate-180' : ''}`} />
        </button>
        {showUnderpinning && (
          <div className="px-4 pb-4">
            {whatIfRules.length === 0 ? (
              <p className="text-xs text-[#505052] py-3 text-center">No grape price rules set. Use the filters above to add prices.</p>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full" style={{ fontFamily: 'Inter, sans-serif', fontSize: '11px' }}>
                  <thead>
                    <tr className="border-b border-[#D8D9DA]">
                      <th className="py-2 px-2 text-left text-[#505052] font-medium">Region</th>
                      <th className="py-2 px-2 text-left text-[#505052] font-medium">Style</th>
                      <th className="py-2 px-2 text-left text-[#505052] font-medium">Variety</th>
                      <th className="py-2 px-2 text-center text-[#505052] font-medium">Vintage</th>
                      <th className="py-2 px-2 text-right text-[#505052] font-medium">$/ton</th>
                      <th className="py-2 px-2 text-center text-[#505052] font-medium">Source</th>
                      <th className="py-2 px-2 text-center text-[#505052] font-medium w-8"></th>
                    </tr>
                  </thead>
                  <tbody>
                    {whatIfRules
                      .map((rule, originalIndex) => ({ rule, originalIndex }))
                      .sort((a, b) => {
                        // Sort by vintage DESC, then region, then specificity
                        if (a.rule.vintage !== b.rule.vintage) return b.rule.vintage - a.rule.vintage;
                        const regionA = a.rule.region || '';
                        const regionB = b.rule.region || '';
                        if (regionA !== regionB) return regionA.localeCompare(regionB);
                        return 0;
                      })
                      .map(({ rule, originalIndex }) => {
                        const source = getRuleSource(rule);
                        return (
                          <tr key={originalIndex} className="border-b border-[#D8D9DA]/30 hover:bg-[#FAF9F7]">
                            <td className="py-1.5 px-2 text-[#1F1F1F]">{rule.region || <span className="text-[#D8D9DA]">All</span>}</td>
                            <td className="py-1.5 px-2 text-[#1F1F1F] capitalize">{rule.color || <span className="text-[#D8D9DA]">All</span>}</td>
                            <td className="py-1.5 px-2 text-[#1F1F1F]">{rule.variety || <span className="text-[#D8D9DA]">All</span>}</td>
                            <td className="py-1.5 px-2 text-center text-[#1F1F1F]">{rule.vintage}</td>
                            <td className="py-1.5 px-2 text-right text-[#1F1F1F] font-medium">${rule.price_per_ton.toLocaleString()}</td>
                            <td className="py-1.5 px-2 text-center">
                              <Badge variant={source === 'vinsight' ? 'neutral' : 'p2'}>
                                {source === 'vinsight' ? 'Vinsight' : 'User-set'}
                              </Badge>
                            </td>
                            <td className="py-1.5 px-2 text-center">
                              <button
                                onClick={() => removeRule(originalIndex)}
                                className="text-[#B42318]/50 hover:text-[#B42318] transition-colors"
                                title="Remove rule"
                              >
                                <X size={12} />
                              </button>
                            </td>
                          </tr>
                        );
                      })}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        )}
      </div>

      {/* SKU Impact Table */}
      <div className="bg-white rounded-xl border border-[#D8D9DA] p-4 shadow-sm">
        <div className="flex items-center justify-between mb-2">
          <div>
            <h2 className="text-sm font-semibold text-[#1F1F1F]" style={{ fontFamily: 'Cardo, serif' }}>
              SKU Margin Impact
            </h2>
            <p className="text-[10px] text-[#505052]/60 mt-0.5">Click column headers to sort. GP shown two ways: at list (transfer) price and at actual average wholesale price.</p>
          </div>
          <input type="text" placeholder="Search by name, SKU or variety..."
            value={searchTerm} onChange={e => setSearchTerm(e.target.value)}
            className="text-xs border border-[#D8D9DA] rounded-lg px-3 py-1.5 w-60 text-[#1F1F1F] placeholder-[#505052]/40" />
        </div>

        <div className="overflow-x-auto">
          <table className="w-full" style={{ fontFamily: 'Inter, sans-serif', fontSize: '12px' }}>
            <thead>
              <tr className="border-b border-[#D8D9DA]">
                {[
                  { label: 'Wine', key: 'item_description', align: 'left' as const },
                  { label: 'Wholesale', key: 'base_wholesale', align: 'right' as const },
                  { label: 'Transfer', key: 'accounting_cogs', align: 'right' as const },
                  { label: 'Econ COGS', key: 'economic_cogs', align: 'right' as const },
                  { label: 'GP% Transfer', key: 'gp_pct_transfer', align: 'right' as const },
                  { label: 'GP% Wholesale', key: 'gp_pct_wholesale', align: 'right' as const },
                  { label: 'Delta', key: 'delta_gp_pct', align: 'right' as const },
                  { label: 'Revenue', key: 'total_revenue_12m', align: 'right' as const },
                ].map(col => (
                  <th key={col.key}
                    className={`py-2 px-2 text-${col.align} text-[#505052] font-medium cursor-pointer hover:text-[#1F1F1F] select-none whitespace-nowrap`}
                    onClick={() => toggleSort(col.key)}
                  >
                    {col.label}
                    {col.label !== 'Wine' && COLUMN_TOOLTIPS[col.label] && (
                      <InfoTooltip text={COLUMN_TOOLTIPS[col.label]} size={10} className="inline-flex ml-0.5 align-middle" />
                    )}
                    {sortKey === col.key && <span className="ml-0.5">{sortDesc ? '\u2193' : '\u2191'}</span>}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {filteredSkus.slice(0, displayLimit).map(sku => (
                <tr key={sku.sku_id} className="border-b border-[#D8D9DA]/30 hover:bg-[#FAF9F7]">
                  <td className="py-2 px-2">
                    <div className="text-[#1F1F1F] font-medium" style={{ fontSize: '11px' }}>{sku.item_description}</div>
                    <div className="text-[#505052]/50" style={{ fontSize: '10px' }}>{sku.sku_code} &middot; {sku.variety} &middot; {sku.region}</div>
                  </td>
                  <td className="py-2 px-2 text-right text-[#1F1F1F]">${sku.base_wholesale.toFixed(2)}</td>
                  <td className="py-2 px-2 text-right text-[#505052]">${sku.accounting_cogs.toFixed(2)}</td>
                  <td className="py-2 px-2 text-right text-[#1F1F1F] font-medium">
                    {sku.has_economic_price ? `$${sku.economic_cogs.toFixed(2)}` : <span className="text-[#D8D9DA]">--</span>}
                  </td>
                  <td className="py-2 px-2 text-right">
                    {sku.has_economic_price ? (
                      <Badge variant={sku.gp_pct_transfer >= 40 ? 'success' : sku.gp_pct_transfer >= 25 ? 'warning' : 'error'}>
                        {sku.gp_pct_transfer}%
                      </Badge>
                    ) : <span className="text-[#D8D9DA] text-xs">--</span>}
                  </td>
                  <td className="py-2 px-2 text-right">
                    {sku.has_economic_price ? (
                      <Badge variant={sku.gp_pct_wholesale >= 40 ? 'success' : sku.gp_pct_wholesale >= 25 ? 'warning' : 'error'}>
                        {sku.gp_pct_wholesale}%
                      </Badge>
                    ) : <span className="text-[#D8D9DA] text-xs">--</span>}
                  </td>
                  <td className={`py-2 px-2 text-right font-medium ${sku.delta_gp_pct > 0 ? 'text-[#1B7A3D]' : sku.delta_gp_pct < 0 ? 'text-[#B42318]' : 'text-[#D8D9DA]'}`}>
                    {sku.has_economic_price ? `${sku.delta_gp_pct > 0 ? '+' : ''}${sku.delta_gp_pct}%` : '--'}
                  </td>
                  <td className="py-2 px-2 text-right text-[#505052]">
                    {sku.total_revenue_12m > 0 ? `$${(sku.total_revenue_12m / 1000).toFixed(1)}K` : '--'}
                  </td>
                </tr>
              ))}
              {filteredSkus.length === 0 && (
                <tr><td colSpan={8} className="py-6 text-center text-[#505052]">No matching SKUs</td></tr>
              )}
            </tbody>
          </table>
        </div>

        {/* Show All / Show Less button */}
        <div className="flex items-center justify-center gap-3 mt-3">
          {filteredSkus.length > 50 && (
            <button onClick={() => setShowAll(!showAll)}
              className="text-xs text-[#931220] hover:text-[#7a0f1a] font-medium">
              {showAll ? `Show Less (50 of ${filteredSkus.length})` : `Show All ${filteredSkus.length} SKUs`}
            </button>
          )}
          {!showAll && filteredSkus.length > 50 && (
            <span className="text-[10px] text-[#505052]/60">
              Showing {Math.min(50, filteredSkus.length)} of {filteredSkus.length}
            </span>
          )}
        </div>
      </div>
    </div>
  );
}
