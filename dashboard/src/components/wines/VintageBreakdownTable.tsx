'use client';

import InfoTooltip from '@/components/InfoTooltip';

export interface VintageBreakdownRow {
  vintage_label: string;
  cases_sold: number;
  revenue: number;
}

const fmtMoney = (n: number) =>
  n >= 1_000_000
    ? `$${(n / 1_000_000).toFixed(1)}M`
    : n >= 1000
    ? `$${(n / 1000).toFixed(1)}K`
    : `$${n.toFixed(0)}`;

const fmtCases = (n: number) =>
  Number.isFinite(n) ? n.toLocaleString('en-AU', { maximumFractionDigits: 1 }) : '—';

/**
 * VintageBreakdownTable — past-13-months sales aggregate per vintage for the
 * SKU's canonical group. Sorted vintage descending; NV rows fall to the
 * bottom. Data from /api/wines/vintage-breakdown.
 */
export default function VintageBreakdownTable({
  rows,
}: {
  rows: VintageBreakdownRow[];
}) {
  return (
    <div className="bg-white rounded-xl border border-[#D8D9DA] p-6 shadow-sm">
      <div className="flex items-center gap-1.5 mb-1">
        <h2
          className="text-sm font-semibold text-[#1F1F1F]"
          style={{ fontFamily: 'Cardo, serif' }}
        >
          Vintage Breakdown
        </h2>
        <InfoTooltip text="Cases sold and revenue per vintage over the past 13 months for every SKU in the same canonical group (so vintage rows across DWS / ALM / Direct roll up correctly). NV = non-vintage rows." />
      </div>
      <p className="text-[10px] text-[#505052] mb-4">
        Cases sold and revenue per vintage — last 13 months
      </p>
      {rows.length > 0 ? (
        <div className="overflow-x-auto">
          <table className="w-full text-xs">
            <thead>
              <tr className="bg-[#1F1F1F] text-white">
                <th className="text-left px-3 py-2 rounded-tl-lg font-medium">Vintage</th>
                <th className="text-right px-3 py-2 font-medium">Cases Sold</th>
                <th className="text-right px-3 py-2 rounded-tr-lg font-medium">Revenue</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r, i) => (
                <tr
                  key={`${r.vintage_label}-${i}`}
                  className={`border-b border-[#F3F4F6] ${
                    i % 2 === 1 ? 'bg-[#FAF9F7]' : ''
                  }`}
                >
                  <td className="px-3 py-2 font-medium text-[#1F1F1F]">
                    {r.vintage_label}
                  </td>
                  <td className="px-3 py-2 text-right text-[#1F1F1F] tabular-nums">
                    {fmtCases(r.cases_sold)}
                  </td>
                  <td className="px-3 py-2 text-right text-[#1F1F1F] tabular-nums">
                    {fmtMoney(r.revenue)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <p className="text-xs text-[#505052]">No vintage sales in the last 13 months</p>
      )}
    </div>
  );
}
