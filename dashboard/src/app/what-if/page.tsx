'use client';

import { useEffect, useState, useCallback } from 'react';
import { apiGet } from '@/lib/api';
import AppLayout from '@/components/AppLayout';
import GrapePriceCalculator, { WhatIfBaseData } from '@/components/GrapePriceCalculator';

export default function WhatIfPage() {
  const [data, setData] = useState<WhatIfBaseData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchData = useCallback(async () => {
    try {
      const res = await apiGet('/api/what-if');
      if (res.ok) {
        const json = await res.json();
        // Normalize — ensure dropdown arrays are always arrays even if API misses them
        const normalized: WhatIfBaseData = {
          skus: Array.isArray(json.skus) ? json.skus : [],
          grape_price_rules: Array.isArray(json.grape_price_rules) ? json.grape_price_rules : [],
          regions: Array.isArray(json.regions) ? json.regions : [],
          varieties: Array.isArray(json.varieties) ? json.varieties : [],
          vintages: Array.isArray(json.vintages) ? json.vintages : [],
        };
        setData(normalized);
        setError(null);
      } else {
        setError('Failed to load calculator data');
      }
    } catch {
      setError('Network error');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  return (
    <AppLayout>
      {loading ? (
        <div className="space-y-6">
          <div className="h-8 bg-gray-200 rounded w-64 animate-pulse" />
          <div className="grid grid-cols-4 gap-4">
            {[...Array(4)].map((_, i) => (
              <div key={i} className="bg-white rounded-xl border border-[#D8D9DA] p-6 animate-pulse">
                <div className="h-4 bg-gray-200 rounded w-24 mb-4" />
                <div className="h-8 bg-gray-200 rounded w-32" />
              </div>
            ))}
          </div>
        </div>
      ) : error ? (
        <div className="bg-red-50 border border-red-200 rounded-xl p-6 text-red-700">
          {error}
        </div>
      ) : data ? (
        <GrapePriceCalculator data={data} />
      ) : null}
    </AppLayout>
  );
}
