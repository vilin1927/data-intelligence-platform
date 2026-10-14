'use client';

import { useState, type ComponentPropsWithoutRef } from 'react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { ChevronDown, ChevronRight, Database, TrendingUp, BarChart3, Package, Search, FileSpreadsheet, LayoutDashboard, DollarSign, Users, Map } from 'lucide-react';

/* ── Custom markdown components matching dashboard theme ── */
const mdComponents = {
  table: (props: ComponentPropsWithoutRef<'table'>) => (
    <div className="overflow-x-auto my-3 rounded-lg border border-[#E5E5E5]">
      <table className="w-full text-xs border-collapse" {...props} />
    </div>
  ),
  thead: (props: ComponentPropsWithoutRef<'thead'>) => (
    <thead className="bg-[#1F1F1F] text-white" {...props} />
  ),
  th: (props: ComponentPropsWithoutRef<'th'>) => (
    <th className="px-3 py-2 text-left text-xs font-semibold whitespace-nowrap" {...props} />
  ),
  td: (props: ComponentPropsWithoutRef<'td'>) => (
    <td className="px-3 py-1.5 text-xs text-[#1F1F1F] border-t border-[#E5E5E5] whitespace-nowrap" {...props} />
  ),
  tr: (props: ComponentPropsWithoutRef<'tr'>) => (
    <tr className="even:bg-[#FAFAFA] hover:bg-[#F0F0F0] transition-colors" {...props} />
  ),
  h2: (props: ComponentPropsWithoutRef<'h2'>) => (
    <h2 className="text-base font-bold text-[#1F1F1F] mt-3 mb-1.5" {...props} />
  ),
  h3: (props: ComponentPropsWithoutRef<'h3'>) => (
    <h3 className="text-sm font-bold text-[#1F1F1F] mt-3 mb-1" {...props} />
  ),
  p: (props: ComponentPropsWithoutRef<'p'>) => (
    <p className="my-1.5 text-sm leading-relaxed" {...props} />
  ),
  ul: (props: ComponentPropsWithoutRef<'ul'>) => (
    <ul className="my-1.5 ml-4 list-disc text-sm space-y-0.5" {...props} />
  ),
  ol: (props: ComponentPropsWithoutRef<'ol'>) => (
    <ol className="my-1.5 ml-4 list-decimal text-sm space-y-0.5" {...props} />
  ),
  li: (props: ComponentPropsWithoutRef<'li'>) => (
    <li className="text-sm leading-relaxed" {...props} />
  ),
  strong: (props: ComponentPropsWithoutRef<'strong'>) => (
    <strong className="font-semibold text-[#1F1F1F]" {...props} />
  ),
  hr: () => <hr className="my-3 border-[#E5E5E5]" />,
};

// Maps tool names to display labels and colors
const TOOL_META: Record<string, { label: string; color: string; icon: React.ReactNode }> = {
  get_margin_ranking: { label: 'Margin Analysis', color: 'bg-emerald-100 text-emerald-800', icon: <TrendingUp size={12} /> },
  get_sales_summary: { label: 'Sales Data', color: 'bg-blue-100 text-blue-800', icon: <BarChart3 size={12} /> },
  get_sales_by_customer: { label: 'Customer Data', color: 'bg-violet-100 text-violet-800', icon: <Users size={12} /> },
  get_sales_by_territory: { label: 'Territory Data', color: 'bg-amber-100 text-amber-800', icon: <Map size={12} /> },
  get_inventory_status: { label: 'Inventory', color: 'bg-orange-100 text-orange-800', icon: <Package size={12} /> },
  get_wine_profile: { label: 'Wine Profile', color: 'bg-rose-100 text-rose-800', icon: <Search size={12} /> },
  get_channel_comparison: { label: 'Channel Analysis', color: 'bg-cyan-100 text-cyan-800', icon: <BarChart3 size={12} /> },
  get_price_analysis: { label: 'Price Analysis', color: 'bg-pink-100 text-pink-800', icon: <DollarSign size={12} /> },
  get_dws_reconciliation: { label: 'DWS Reconciliation', color: 'bg-indigo-100 text-indigo-800', icon: <FileSpreadsheet size={12} /> },
  get_overview_kpis: { label: 'Overview', color: 'bg-teal-100 text-teal-800', icon: <LayoutDashboard size={12} /> },
  run_sql_query: { label: 'SQL Query', color: 'bg-gray-100 text-gray-800', icon: <Database size={12} /> },
};

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type MessagePart = any;

interface ChatMessageProps {
  role: 'user' | 'assistant';
  parts: MessagePart[];
}

function getToolName(part: MessagePart): string | null {
  if (!part || !part.type) return null;
  // v6 tool parts have type like "tool-get_margin_ranking"
  if (typeof part.type === 'string' && part.type.startsWith('tool-')) {
    return part.type.slice(5);
  }
  // Dynamic tool parts
  if (part.type === 'dynamic-tool' && part.toolName) {
    return part.toolName;
  }
  return null;
}

function SourceBadge({ toolName }: { toolName: string }) {
  const meta = TOOL_META[toolName] || { label: toolName, color: 'bg-gray-100 text-gray-700', icon: <Database size={12} /> };
  return (
    <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium ${meta.color}`}>
      {meta.icon}
      {meta.label}
    </span>
  );
}

function ToolResultDetail({ toolName, output }: { toolName: string; output: unknown }) {
  const [expanded, setExpanded] = useState(false);

  if (!output || typeof output !== 'object') return null;

  const data = output as Record<string, unknown>;
  if (data.error) {
    return (
      <div className="mt-1 text-xs text-red-600 bg-red-50 px-3 py-1.5 rounded">
        Error: {String(data.error)}
      </div>
    );
  }

  return (
    <div className="mt-1">
      <button
        onClick={() => setExpanded(!expanded)}
        className="flex items-center gap-1 text-xs text-[#505052] hover:text-[#1F1F1F] transition-colors"
      >
        {expanded ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
        <span>View data</span>
      </button>
      {expanded && (
        <pre className="mt-1 text-xs bg-[#F5F5F5] text-[#505052] p-3 rounded-lg overflow-x-auto max-h-64 overflow-y-auto">
          {JSON.stringify(output, null, 2)}
        </pre>
      )}
    </div>
  );
}

export default function ChatMessage({ role, parts }: ChatMessageProps) {
  const isUser = role === 'user';

  // Extract text content and tool parts
  const textParts = parts.filter((p: MessagePart) => p.type === 'text');
  const toolParts = parts.filter((p: MessagePart) => {
    const name = getToolName(p);
    return name !== null;
  });

  const textContent = textParts.map((p: MessagePart) => p.text || '').join('');

  // Unique tool names for source badges
  const toolNames = Array.from(new Set(toolParts.map((p: MessagePart) => getToolName(p)).filter(Boolean))) as string[];

  // Tool parts that have completed (have output)
  const completedTools = toolParts.filter((p: MessagePart) => p.state === 'result' || p.output !== undefined);

  return (
    <div className={`flex ${isUser ? 'justify-end' : 'justify-start'} mb-4`}>
      <div className="max-w-[85%]">
        {/* Message bubble */}
        <div
          className={`px-4 py-3 rounded-2xl text-sm leading-relaxed ${
            isUser
              ? 'bg-[#1F1F1F] text-white rounded-br-md'
              : 'bg-white text-[#1F1F1F] border border-[#E5E5E5] rounded-bl-md shadow-sm'
          }`}
          style={{ fontFamily: 'Inter, sans-serif' }}
        >
          {/* Source badges (assistant messages only, before content) */}
          {!isUser && toolNames.length > 0 && (
            <div className="flex flex-wrap gap-1.5 mb-2">
              {toolNames.map(name => (
                <SourceBadge key={name} toolName={name} />
              ))}
            </div>
          )}

          {/* Message content */}
          {textContent && (
            isUser ? (
              <div className="whitespace-pre-wrap">{textContent}</div>
            ) : (
              <div className="max-w-none">
                <ReactMarkdown remarkPlugins={[remarkGfm]} components={mdComponents}>{textContent}</ReactMarkdown>
              </div>
            )
          )}
        </div>

        {/* Tool result details (collapsible) */}
        {!isUser && completedTools.length > 0 && (
          <div className="mt-1 space-y-1 ml-1">
            {completedTools.map((p: MessagePart, i: number) => (
              <ToolResultDetail
                key={i}
                toolName={getToolName(p) || 'unknown'}
                output={p.output}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
