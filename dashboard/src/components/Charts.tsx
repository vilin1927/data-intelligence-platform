'use client';

import { useState, useEffect, useRef } from 'react';
import {
  BarChart as RechartsBarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer,
  LineChart as RechartsLineChart,
  Line,
  AreaChart,
  Area,
} from 'recharts';

// AUD-07: Measure container width before rendering chart to prevent
// Recharts "width(-1) height(-1)" warnings from ResponsiveContainer
function ChartContainer({ height, children }: { height: number; children: (width: number) => React.ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(0);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => {
      const w = el.clientWidth;
      if (w > 0) setWidth(w);
    };
    measure();
    const ro = new ResizeObserver(() => measure());
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  return (
    <div ref={ref} style={{ width: '100%', height }}>
      {width > 0 && children(width)}
    </div>
  );
}

// Moppity brand colors for charts (from design system)
const COLORS = {
  primary: '#931220',
  secondary: '#BEB3AB',  // gold
  tertiary: '#1B7A3D',   // success green
  quaternary: '#1D4ED8', // info blue
  grid: '#E5E7EB',
  text: '#505052',
  background: '#FAF9F7',
};

const SERIES_COLORS = ['#931220', '#BEB3AB', '#1B7A3D', '#1D4ED8', '#6B7280', '#B54708'];

interface ChartProps {
  data: Record<string, unknown>[];
  height?: number;
}

interface BarChartProps extends ChartProps {
  dataKey: string;
  xAxisKey: string;
  color?: string;
  showGrid?: boolean;
  showLegend?: boolean;
}

interface LineChartProps extends ChartProps {
  dataKey: string;
  xAxisKey: string;
  color?: string;
  showGrid?: boolean;
  showArea?: boolean;
}

interface StackedBarChartProps extends ChartProps {
  xAxisKey: string;
  series: { key: string; name: string; color?: string }[];
  showGrid?: boolean;
  showLegend?: boolean;
}

interface MultiLineChartProps extends ChartProps {
  xAxisKey: string;
  series: { key: string; name: string; color?: string }[];
  showGrid?: boolean;
  showLegend?: boolean;
}

// Custom tooltip styling
const CustomTooltip = ({ active, payload, label }: { active?: boolean; payload?: Array<{ name: string; value: number; color: string }>; label?: string }) => {
  if (!active || !payload) return null;

  return (
    <div
      className="bg-white border border-[#D8D9DA] rounded-lg shadow-lg p-3"
      style={{ fontFamily: 'Inter, sans-serif' }}
    >
      <p className="text-sm font-medium text-[#1F1F1F] mb-1">{label}</p>
      {payload.map((entry, index) => (
        <p key={index} className="text-xs text-[#505052]">
          <span
            className="inline-block w-2 h-2 rounded-full mr-2"
            style={{ backgroundColor: entry.color }}
          />
          {entry.name}: <span className="font-medium">{typeof entry.value === 'number' ? entry.value.toLocaleString() : entry.value}</span>
        </p>
      ))}
    </div>
  );
};

// Simple Bar Chart
export function BarChart({
  data,
  dataKey,
  xAxisKey,
  color = COLORS.primary,
  height = 300,
  showGrid = true,
  showLegend = false,
}: BarChartProps) {
  return (
    <ChartContainer height={height}>
      {(w) => (
      <RechartsBarChart width={w} height={height} data={data} margin={{ top: 10, right: 10, left: 0, bottom: 0 }}>
        {showGrid && <CartesianGrid strokeDasharray="3 3" stroke={COLORS.grid} vertical={false} />}
        <XAxis dataKey={xAxisKey} tick={{ fontSize: 12, fill: COLORS.text }} axisLine={{ stroke: COLORS.grid }} tickLine={false} />
        <YAxis tick={{ fontSize: 12, fill: COLORS.text }} axisLine={false} tickLine={false} tickFormatter={(value) => typeof value === 'number' ? value.toLocaleString() : value} />
        <Tooltip content={<CustomTooltip />} />
        {showLegend && <Legend />}
        <Bar dataKey={dataKey} fill={color} radius={[4, 4, 0, 0]} />
      </RechartsBarChart>
      )}
    </ChartContainer>
  );
}

// Simple Line Chart
export function LineChart({
  data,
  dataKey,
  xAxisKey,
  color = COLORS.primary,
  height = 300,
  showGrid = true,
  showArea = false,
}: LineChartProps) {
  if (showArea) {
    return (
      <ChartContainer height={height}>
        {(w) => (
        <AreaChart width={w} height={height} data={data} margin={{ top: 10, right: 10, left: 0, bottom: 0 }}>
          {showGrid && <CartesianGrid strokeDasharray="3 3" stroke={COLORS.grid} vertical={false} />}
          <XAxis dataKey={xAxisKey} tick={{ fontSize: 12, fill: COLORS.text }} axisLine={{ stroke: COLORS.grid }} tickLine={false} />
          <YAxis tick={{ fontSize: 12, fill: COLORS.text }} axisLine={false} tickLine={false} tickFormatter={(value) => typeof value === 'number' ? value.toLocaleString() : value} />
          <Tooltip content={<CustomTooltip />} />
          <Area type="monotone" dataKey={dataKey} stroke={color} fill={color} fillOpacity={0.1} strokeWidth={2} />
        </AreaChart>
        )}
      </ChartContainer>
    );
  }

  return (
    <ChartContainer height={height}>
      {(w) => (
      <RechartsLineChart width={w} height={height} data={data} margin={{ top: 10, right: 10, left: 0, bottom: 0 }}>
        {showGrid && <CartesianGrid strokeDasharray="3 3" stroke={COLORS.grid} vertical={false} />}
        <XAxis dataKey={xAxisKey} tick={{ fontSize: 12, fill: COLORS.text }} axisLine={{ stroke: COLORS.grid }} tickLine={false} />
        <YAxis tick={{ fontSize: 12, fill: COLORS.text }} axisLine={false} tickLine={false} tickFormatter={(value) => typeof value === 'number' ? value.toLocaleString() : value} />
        <Tooltip content={<CustomTooltip />} />
        <Line type="monotone" dataKey={dataKey} stroke={color} strokeWidth={2} dot={{ fill: color, strokeWidth: 0, r: 4 }} activeDot={{ fill: color, strokeWidth: 0, r: 6 }} />
      </RechartsLineChart>
      )}
    </ChartContainer>
  );
}

// Stacked Bar Chart
export function StackedBarChart({
  data,
  xAxisKey,
  series,
  height = 300,
  showGrid = true,
  showLegend = true,
}: StackedBarChartProps) {
  return (
    <ChartContainer height={height}>
      {(w) => (
      <RechartsBarChart width={w} height={height} data={data} margin={{ top: 10, right: 10, left: 0, bottom: 0 }}>
        {showGrid && <CartesianGrid strokeDasharray="3 3" stroke={COLORS.grid} vertical={false} />}
        <XAxis dataKey={xAxisKey} tick={{ fontSize: 12, fill: COLORS.text }} axisLine={{ stroke: COLORS.grid }} tickLine={false} />
        <YAxis tick={{ fontSize: 12, fill: COLORS.text }} axisLine={false} tickLine={false} tickFormatter={(value) => typeof value === 'number' ? value.toLocaleString() : value} />
        <Tooltip content={<CustomTooltip />} />
        {showLegend && <Legend wrapperStyle={{ fontSize: 12, fontFamily: 'Inter, sans-serif' }} />}
        {series.map((s, index) => (
          <Bar key={s.key} dataKey={s.key} name={s.name} fill={s.color || SERIES_COLORS[index % SERIES_COLORS.length]} stackId="stack" radius={index === series.length - 1 ? [4, 4, 0, 0] : [0, 0, 0, 0]} />
        ))}
      </RechartsBarChart>
      )}
    </ChartContainer>
  );
}

// Multi-Line Chart
export function MultiLineChart({
  data,
  xAxisKey,
  series,
  height = 300,
  showGrid = true,
  showLegend = true,
}: MultiLineChartProps) {
  return (
    <ChartContainer height={height}>
      {(w) => (
      <RechartsLineChart width={w} height={height} data={data} margin={{ top: 10, right: 10, left: 0, bottom: 0 }}>
        {showGrid && <CartesianGrid strokeDasharray="3 3" stroke={COLORS.grid} vertical={false} />}
        <XAxis dataKey={xAxisKey} tick={{ fontSize: 12, fill: COLORS.text }} axisLine={{ stroke: COLORS.grid }} tickLine={false} />
        <YAxis tick={{ fontSize: 12, fill: COLORS.text }} axisLine={false} tickLine={false} tickFormatter={(value) => typeof value === 'number' ? value.toLocaleString() : value} />
        <Tooltip content={<CustomTooltip />} />
        {showLegend && <Legend wrapperStyle={{ fontSize: 12, fontFamily: 'Inter, sans-serif' }} />}
        {series.map((s, index) => (
          <Line key={s.key} type="monotone" dataKey={s.key} name={s.name} stroke={s.color || SERIES_COLORS[index % SERIES_COLORS.length]} strokeWidth={2} dot={{ fill: s.color || SERIES_COLORS[index % SERIES_COLORS.length], strokeWidth: 0, r: 3 }} activeDot={{ fill: s.color || SERIES_COLORS[index % SERIES_COLORS.length], strokeWidth: 0, r: 5 }} />
        ))}
      </RechartsLineChart>
      )}
    </ChartContainer>
  );
}
