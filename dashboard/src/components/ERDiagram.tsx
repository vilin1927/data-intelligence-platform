'use client';

import { useState } from 'react';

interface TableInfo {
  table_name: string;
  row_count: number;
}

const PALETTE = {
  fact:      { fill: '#312e81', stroke: '#818cf8', text: '#e0e7ff', badge: 'Fact Table' },
  dimension: { fill: '#1e3a5f', stroke: '#60a5fa', text: '#dbeafe', badge: 'Dimension' },
  mapping:   { fill: '#451a03', stroke: '#f59e0b', text: '#fef3c7', badge: 'Mapping' },
  system:    { fill: '#022c22', stroke: '#34d399', text: '#d1fae5', badge: 'System' },
  reference: { fill: '#1e293b', stroke: '#94a3b8', text: '#e2e8f0', badge: 'Reference' },
};

type NodeType = keyof typeof PALETTE;

interface TNode {
  id: string;
  x: number;
  y: number;
  w: number;
  h: number;
  type: NodeType;
}

interface Edge {
  from: string;
  to: string;
  dashed?: boolean;
}

const NODES: TNode[] = [
  // Central fact table
  { id: 'sales_transaction',  x: 400, y: 238, w: 230, h: 48, type: 'fact' },
  // Primary dimensions (star pattern)
  { id: 'sku',                x: 100, y: 115, w: 150, h: 40, type: 'dimension' },
  { id: 'customer',           x: 790, y: 115, w: 150, h: 40, type: 'dimension' },
  { id: 'channel',            x: 80,  y: 305, w: 140, h: 36, type: 'dimension' },
  { id: 'territory',          x: 840, y: 305, w: 140, h: 36, type: 'dimension' },
  { id: 'representative',     x: 435, y: 365, w: 170, h: 36, type: 'dimension' },
  // Mapping tables
  { id: 'sku_code_map',       x: 255, y: 30,  w: 148, h: 32, type: 'mapping' },
  { id: 'customer_code_map',  x: 775, y: 30,  w: 190, h: 32, type: 'mapping' },
  // Reference tables
  { id: 'wine_range (VIEW)',  x: 35,  y: 30,  w: 140, h: 32, type: 'reference' },
  { id: 'sku_cogs',           x: 35,  y: 195, w: 128, h: 32, type: 'reference' },
  { id: 'award',              x: 255, y: 195, w: 108, h: 32, type: 'reference' },
  { id: 'entity',             x: 80,  y: 430, w: 120, h: 32, type: 'reference' },
  { id: 'month_end_snapshot', x: 260, y: 430, w: 185, h: 32, type: 'reference' },
  // System tables
  { id: 'etl_run_log',        x: 808, y: 395, w: 155, h: 32, type: 'system' },
  { id: 'etl_dead_letter',    x: 808, y: 445, w: 155, h: 32, type: 'system' },
];

const EDGES: Edge[] = [
  // Star schema: fact -> dimensions
  { from: 'sales_transaction', to: 'sku' },
  { from: 'sales_transaction', to: 'customer' },
  { from: 'sales_transaction', to: 'channel' },
  { from: 'sales_transaction', to: 'territory' },
  { from: 'sales_transaction', to: 'representative' },
  // SKU sub-relationships
  { from: 'sku', to: 'wine_range (VIEW)' },
  { from: 'sku_code_map', to: 'sku' },
  { from: 'sku_cogs', to: 'sku' },
  { from: 'award', to: 'sku' },
  // Customer sub-relationships
  { from: 'customer_code_map', to: 'customer' },
  // Cross-dimension FKs
  { from: 'customer', to: 'channel', dashed: true },
  { from: 'customer', to: 'territory', dashed: true },
  { from: 'representative', to: 'territory', dashed: true },
  // System
  { from: 'etl_dead_letter', to: 'etl_run_log' },
];

function edgePoint(
  cx: number, cy: number, w: number, h: number,
  tx: number, ty: number,
): [number, number] {
  const dx = tx - cx;
  const dy = ty - cy;
  if (dx === 0 && dy === 0) return [cx, cy];
  const sx = dx !== 0 ? (w / 2) / Math.abs(dx) : Infinity;
  const sy = dy !== 0 ? (h / 2) / Math.abs(dy) : Infinity;
  const s = Math.min(sx, sy);
  return [cx + dx * s, cy + dy * s];
}

export default function ERDiagram({
  tables,
  loading,
}: {
  tables: TableInfo[];
  loading: boolean;
}) {
  const [hovered, setHovered] = useState<string | null>(null);

  const nodeMap = new Map(NODES.map((n) => [n.id, n]));

  const rowCount = (id: string): number | null => {
    const t = tables.find((tb) => tb.table_name === id);
    return t ? t.row_count : null;
  };

  const isRelated = (id: string): boolean => {
    if (!hovered) return true;
    if (id === hovered) return true;
    return EDGES.some(
      (e) =>
        (e.from === hovered && e.to === id) ||
        (e.to === hovered && e.from === id),
    );
  };

  return (
    <div>
      <h2 className="text-sm font-semibold text-slate-400 uppercase tracking-wider mb-4">
        Entity Relationships
      </h2>
      <div className="rounded-xl border border-slate-700/50 bg-slate-800/50 p-4 overflow-x-auto">
        {loading ? (
          <div className="h-64 bg-slate-700/30 rounded-lg animate-pulse" />
        ) : (
          <>
            <svg
              viewBox="0 0 1040 500"
              className="w-full"
              style={{ minWidth: '640px', maxHeight: '460px' }}
            >
              <defs>
                <marker
                  id="fk-arrow"
                  viewBox="0 0 10 6"
                  refX="9"
                  refY="3"
                  markerWidth="7"
                  markerHeight="5"
                  orient="auto-start-reverse"
                >
                  <path d="M0,0 L10,3 L0,6 Z" fill="#64748b" />
                </marker>
                <marker
                  id="fk-arrow-dim"
                  viewBox="0 0 10 6"
                  refX="9"
                  refY="3"
                  markerWidth="7"
                  markerHeight="5"
                  orient="auto-start-reverse"
                >
                  <path d="M0,0 L10,3 L0,6 Z" fill="#475569" />
                </marker>
              </defs>

              {/* Relationship lines */}
              {EDGES.map((edge, i) => {
                const from = nodeMap.get(edge.from);
                const to = nodeMap.get(edge.to);
                if (!from || !to) return null;

                const fcx = from.x + from.w / 2;
                const fcy = from.y + from.h / 2;
                const tcx = to.x + to.w / 2;
                const tcy = to.y + to.h / 2;
                const [x1, y1] = edgePoint(fcx, fcy, from.w, from.h, tcx, tcy);
                const [x2, y2] = edgePoint(tcx, tcy, to.w, to.h, fcx, fcy);

                const rel =
                  !hovered || edge.from === hovered || edge.to === hovered;

                return (
                  <line
                    key={i}
                    x1={x1}
                    y1={y1}
                    x2={x2}
                    y2={y2}
                    stroke={
                      rel
                        ? edge.dashed
                          ? '#475569'
                          : '#64748b'
                        : '#1e293b'
                    }
                    strokeWidth={edge.dashed ? 1 : 1.5}
                    strokeDasharray={edge.dashed ? '5 3' : undefined}
                    markerEnd={`url(#${edge.dashed ? 'fk-arrow-dim' : 'fk-arrow'})`}
                    opacity={rel ? (edge.dashed ? 0.5 : 0.8) : 0.1}
                    style={{ transition: 'opacity 200ms' }}
                  />
                );
              })}

              {/* Table nodes */}
              {NODES.map((node) => {
                const pal = PALETTE[node.type];
                const rel = isRelated(node.id);
                const isHov = hovered === node.id;
                const count = rowCount(node.id);
                const showCount =
                  count !== null &&
                  (node.type === 'fact' || node.type === 'dimension');
                const nameOffsetY = showCount
                  ? node.h >= 40
                    ? -4
                    : -3
                  : 0;
                const countOffsetY = node.h >= 40 ? 9 : 7;
                const countFontSize = node.h >= 40 ? 8 : 7;

                return (
                  <g
                    key={node.id}
                    onMouseEnter={() => setHovered(node.id)}
                    onMouseLeave={() => setHovered(null)}
                    style={{ cursor: 'default', transition: 'opacity 200ms' }}
                    opacity={rel ? 1 : 0.15}
                  >
                    <rect
                      x={node.x}
                      y={node.y}
                      width={node.w}
                      height={node.h}
                      rx={6}
                      fill={pal.fill}
                      stroke={isHov ? '#f1f5f9' : pal.stroke}
                      strokeWidth={isHov ? 2 : 1}
                    />
                    <text
                      x={node.x + node.w / 2}
                      y={node.y + node.h / 2 + nameOffsetY}
                      textAnchor="middle"
                      dominantBaseline="middle"
                      fill={pal.text}
                      fontSize={node.type === 'fact' ? 11.5 : 9.5}
                      fontWeight={node.type === 'fact' ? 600 : 500}
                      fontFamily="ui-monospace, SFMono-Regular, monospace"
                    >
                      {node.id}
                    </text>
                    {showCount && (
                      <text
                        x={node.x + node.w / 2}
                        y={node.y + node.h / 2 + countOffsetY}
                        textAnchor="middle"
                        dominantBaseline="middle"
                        fill={pal.stroke}
                        fontSize={countFontSize}
                        fontFamily="ui-sans-serif, system-ui, sans-serif"
                      >
                        {count!.toLocaleString()} rows
                      </text>
                    )}
                  </g>
                );
              })}

              {/* Legend */}
              {Object.entries(PALETTE).map(([type, pal], i) => (
                <g key={type} transform={`translate(${i * 130 + 190}, 485)`}>
                  <rect
                    x={0}
                    y={0}
                    width={10}
                    height={10}
                    rx={2}
                    fill={pal.fill}
                    stroke={pal.stroke}
                    strokeWidth={1}
                  />
                  <text
                    x={14}
                    y={9}
                    fill="#94a3b8"
                    fontSize={9}
                    fontFamily="ui-sans-serif, system-ui, sans-serif"
                  >
                    {pal.badge}
                  </text>
                </g>
              ))}
            </svg>
            <p className="text-xs text-slate-500 text-center mt-2">
              Hover a table to highlight its relationships. Arrows show FK
              direction. Dashed lines = secondary FKs.
            </p>
          </>
        )}
      </div>
    </div>
  );
}
