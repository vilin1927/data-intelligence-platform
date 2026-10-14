/**
 * Customer display helpers.
 *
 * Per the owner 2026-04-05 (extract-call-apr5-0041, JC-021/375/376): customer
 * display in reports must use the composite "NAME @ SUBURB" form. Same
 * business name can recur in different parts of Australia (e.g. Lantern
 * Rooms in Campbell vs another Lantern Rooms elsewhere), and the suburb
 * tag is what distinguishes the two physical accounts.
 *
 * Schema note: `canonical_customer.customer_name` is the cleaned form
 * WITHOUT a suburb tag; the suburb suffix lives in raw
 * `customer.customer_name` for ALM/DWS/Direct rows where the source
 * system embedded it. API queries that join through both tables should
 * therefore prefer the raw name (which carries the suffix) and fall
 * back to the canonical only when no raw is available — see
 * `dashboard/src/app/api/sales/route.ts` resolved CTE for the pattern.
 *
 * This module exists so future grids can normalise the display through a
 * single helper if/when canonical_customer gains its own suburb column.
 */

export function formatNameAtSuburb(
  name: string | null | undefined,
  suburb?: string | null,
): string {
  const base = (name ?? '').trim();
  const suburbStr = (suburb ?? '').trim();
  if (!base) return '';
  if (!suburbStr) return base;
  if (/\s@\s/.test(base)) return base;
  return `${base} @ ${suburbStr.toUpperCase()}`;
}

export function hasSuburbTag(name: string | null | undefined): boolean {
  if (!name) return false;
  return /\s@\s\S/.test(name);
}
