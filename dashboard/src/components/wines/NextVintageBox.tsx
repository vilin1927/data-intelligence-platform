'use client';

import InfoTooltip from '@/components/InfoTooltip';

/**
 * NextVintageBox — small callout on the Wine Profile detail view showing the
 * next-vintage-to-bottle for the SKU's canonical group.
 *
 * Data source is `canonical_sku.next_vintage` via /api/wines/vintage-breakdown.
 * The column does NOT yet exist in the schema — the API returns null today
 * and we render the "Not yet scheduled" placeholder. A post-delivery
 * clarification asks the owner to confirm whether the column should be added and
 * where the data comes from (manual entry vs Inventory module).
 */
export default function NextVintageBox({
  nextVintage,
}: {
  nextVintage: string | null;
}) {
  return (
    <div className="bg-white rounded-xl border border-[#D8D9DA] p-6 shadow-sm">
      <div className="flex items-center gap-1.5 mb-1">
        <h2
          className="text-sm font-semibold text-[#1F1F1F]"
          style={{ fontFamily: 'Cardo, serif' }}
        >
          Next Vintage to Bottle
        </h2>
        <InfoTooltip text="The next vintage of this wine that's planned for bottling. When no vintage has been scheduled yet, this box reads 'Not yet scheduled'." />
      </div>
      <p className="text-[10px] text-[#505052] mb-3">
        Planned next bottling for this wine
      </p>
      <div className="flex items-center gap-3">
        {nextVintage ? (
          <p
            className="text-2xl font-semibold text-[#1F1F1F]"
            style={{ fontFamily: 'Cardo, serif' }}
          >
            {nextVintage}
          </p>
        ) : (
          <div>
            <p
              className="text-base font-semibold text-[#505052]"
              style={{ fontFamily: 'Cardo, serif' }}
            >
              Not yet scheduled
            </p>
            <p className="text-[10px] text-[#505052]/70 mt-0.5">
              Awaiting bottling plan
            </p>
          </div>
        )}
      </div>
    </div>
  );
}
