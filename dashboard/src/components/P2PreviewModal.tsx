'use client';

import { useEffect } from 'react';
import { X, TrendingUp, Package, FileSpreadsheet, CheckCircle } from 'lucide-react';

interface P2PreviewModalProps {
  feature: 'cashflow' | 'production' | 'legacy-reports';
  onClose: () => void;
}

// Demo mirror flag — genericize visible brand copy for prospects. Unset => live prod text.
const VIEW_ONLY = process.env.NEXT_PUBLIC_VIEW_ONLY === 'true';

const FEATURES = {
  cashflow: {
    title: 'Cashflow Forecasting',
    subtitle: VIEW_ONLY ? 'Forward-looking cash visibility for the business' : 'Forward-looking cash visibility for Moppity Wines',
    icon: <TrendingUp size={32} />,
    bullets: [
      '12–24 month forward cash projection based on real sales data',
      'Revenue forecast linked to actuals — auto-adjusts as invoices come in',
      'Forecast vs actuals variance tracking with alerts on big swings',
      'What-if scenarios for production decisions — see cash impact before committing',
    ],
    color: '#931220',
  },
  production: {
    title: 'Production Planning',
    subtitle: 'Bottling schedules, dry goods, and surplus/shortage tracking',
    icon: <Package size={32} />,
    bullets: [
      'Bulk wine inventory tracking — see what\'s in tanks ready to bottle',
      'Dry goods management — labels, bottles, corks, capsules by SKU',
      'Bottling schedule optimization — plan runs based on demand velocity',
      'Surplus/shortage flagging — know what to bottle before you run out',
    ],
    color: '#1B7A3D',
  },
  'legacy-reports': {
    title: 'Legacy Access Reports',
    subtitle: 'Browseable surface for the 14 preserved Access reports',
    icon: <FileSpreadsheet size={32} />,
    bullets: [
      'All 14 preserved Access tables browseable in one place — TerritoryDistributionPerformance, tblAnalysisReport, the 4 tblDistributionByRange tables, and the rest',
      'Drill view into each table with pagination, filters, and search',
      'Data already loaded in Postgres (739 rows) — Phase 2 surfaces the UI',
      'Phase 1 covers these via the 10 dashboard pages and AI Chat per the Pre-Read scope',
    ],
    color: '#7A5C1B',
  },
};

export default function P2PreviewModal({ feature, onClose }: P2PreviewModalProps) {
  const data = FEATURES[feature];

  useEffect(() => {
    function handleEsc(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose();
    }
    document.addEventListener('keydown', handleEsc);
    return () => document.removeEventListener('keydown', handleEsc);
  }, [onClose]);

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center"
      onClick={onClose}
    >
      {/* Backdrop */}
      <div className="absolute inset-0 bg-black/60 backdrop-blur-sm" />

      {/* Modal */}
      <div
        className="relative bg-white rounded-2xl shadow-2xl max-w-lg w-full mx-4 overflow-hidden"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div
          className="px-8 pt-8 pb-6"
          style={{ background: `linear-gradient(135deg, ${data.color}08, ${data.color}15)` }}
        >
          <button
            onClick={onClose}
            className="absolute top-4 right-4 text-[#505052]/50 hover:text-[#505052] transition-colors"
          >
            <X size={20} />
          </button>

          <div
            className="w-14 h-14 rounded-xl flex items-center justify-center mb-4"
            style={{ backgroundColor: `${data.color}15`, color: data.color }}
          >
            {data.icon}
          </div>

          <h2
            className="text-xl font-semibold text-[#1F1F1F]"
            style={{ fontFamily: 'Cardo, serif' }}
          >
            {data.title}
          </h2>
          <p
            className="text-sm text-[#505052] mt-1"
            style={{ fontFamily: 'Inter, sans-serif' }}
          >
            {data.subtitle}
          </p>
        </div>

        {/* Benefits */}
        <div className="px-8 py-6">
          <ul className="space-y-3">
            {data.bullets.map((bullet, i) => (
              <li key={i} className="flex items-start gap-3">
                <CheckCircle
                  size={16}
                  className="flex-shrink-0 mt-0.5"
                  style={{ color: data.color }}
                />
                <span
                  className="text-sm text-[#1F1F1F] leading-relaxed"
                  style={{ fontFamily: 'Inter, sans-serif' }}
                >
                  {bullet}
                </span>
              </li>
            ))}
          </ul>
        </div>

        {/* Footer */}
        <div className="px-8 pb-8">
          <div
            className="rounded-xl px-5 py-4 text-center"
            style={{ backgroundColor: `${data.color}08`, borderColor: `${data.color}20`, borderWidth: 1 }}
          >
            <p
              className="text-sm font-medium"
              style={{ fontFamily: 'Inter, sans-serif', color: data.color }}
            >
              This feature is available in Phase 2
            </p>
            <p
              className="text-xs text-[#505052] mt-1"
              style={{ fontFamily: 'Inter, sans-serif' }}
            >
              Built on the same data platform — ready when you are.
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
