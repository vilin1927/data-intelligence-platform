'use client';

import { useState, useMemo, ReactNode } from 'react';
import { ChevronUp, ChevronDown, ChevronsUpDown, Search, ChevronLeft, ChevronRight } from 'lucide-react';

export interface Column<T> {
  key: keyof T | string;
  header: string;
  sortable?: boolean;
  render?: (value: unknown, row: T) => ReactNode;
  className?: string;
}

interface DataTableProps<T> {
  data: T[];
  columns: Column<T>[];
  searchable?: boolean;
  searchKeys?: (keyof T)[];
  pageSize?: number;
  emptyMessage?: string;
}

type SortDirection = 'asc' | 'desc' | null;

interface SortState {
  key: string | null;
  direction: SortDirection;
}

export default function DataTable<T extends Record<string, unknown>>({
  data,
  columns,
  searchable = false,
  searchKeys = [],
  pageSize = 10,
  emptyMessage = 'No data available',
}: DataTableProps<T>) {
  const [search, setSearch] = useState('');
  const [sort, setSort] = useState<SortState>({ key: null, direction: null });
  const [currentPage, setCurrentPage] = useState(1);

  // Filter data based on search
  const filteredData = useMemo(() => {
    if (!search || searchKeys.length === 0) return data;

    const searchLower = search.toLowerCase();
    return data.filter((row) =>
      searchKeys.some((key) => {
        const value = row[key];
        if (value == null) return false;
        return String(value).toLowerCase().includes(searchLower);
      })
    );
  }, [data, search, searchKeys]);

  // Sort data
  const sortedData = useMemo(() => {
    if (!sort.key || !sort.direction) return filteredData;

    return [...filteredData].sort((a, b) => {
      const aVal = a[sort.key as keyof T];
      const bVal = b[sort.key as keyof T];

      if (aVal == null && bVal == null) return 0;
      if (aVal == null) return sort.direction === 'asc' ? 1 : -1;
      if (bVal == null) return sort.direction === 'asc' ? -1 : 1;

      if (typeof aVal === 'number' && typeof bVal === 'number') {
        return sort.direction === 'asc' ? aVal - bVal : bVal - aVal;
      }

      const aStr = String(aVal).toLowerCase();
      const bStr = String(bVal).toLowerCase();

      if (sort.direction === 'asc') {
        return aStr.localeCompare(bStr);
      }
      return bStr.localeCompare(aStr);
    });
  }, [filteredData, sort]);

  // Paginate data
  const totalPages = Math.ceil(sortedData.length / pageSize);
  const paginatedData = useMemo(() => {
    const start = (currentPage - 1) * pageSize;
    return sortedData.slice(start, start + pageSize);
  }, [sortedData, currentPage, pageSize]);

  // Reset page when search changes
  const handleSearch = (value: string) => {
    setSearch(value);
    setCurrentPage(1);
  };

  // Handle sort
  const handleSort = (key: string) => {
    setSort((prev) => {
      if (prev.key !== key) {
        return { key, direction: 'asc' };
      }
      if (prev.direction === 'asc') {
        return { key, direction: 'desc' };
      }
      return { key: null, direction: null };
    });
  };

  const getSortIcon = (key: string) => {
    if (sort.key !== key) {
      return <ChevronsUpDown size={14} className="text-[#8A8A8D]" />;
    }
    if (sort.direction === 'asc') {
      return <ChevronUp size={14} className="text-[#931220]" />;
    }
    return <ChevronDown size={14} className="text-[#931220]" />;
  };

  return (
    <div className="w-full" style={{ fontFamily: 'Inter, sans-serif' }}>
      {/* Search */}
      {searchable && (
        <div className="mb-4">
          <div className="relative">
            <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-[#8A8A8D]" />
            <input
              type="text"
              value={search}
              onChange={(e) => handleSearch(e.target.value)}
              placeholder="Search..."
              className="w-full max-w-xs pl-9 pr-4 py-2 text-sm border border-[#D8D9DA] rounded-lg focus:outline-none focus:ring-2 focus:ring-[#931220]/50 focus:border-[#931220]"
            />
          </div>
        </div>
      )}

      {/* Table */}
      <div className="overflow-x-auto border border-[#D8D9DA] rounded-lg">
        <table className="w-full">
          <thead>
            <tr className="bg-[#F5F4F2] border-b border-[#D8D9DA]">
              {columns.map((col) => (
                <th
                  key={String(col.key)}
                  className={`px-4 py-3 text-left text-xs font-semibold text-[#505052] uppercase tracking-wider ${col.className || ''}`}
                >
                  {col.sortable ? (
                    <button
                      onClick={() => handleSort(String(col.key))}
                      className="flex items-center gap-1 hover:text-[#1F1F1F] transition-colors"
                    >
                      {col.header}
                      {getSortIcon(String(col.key))}
                    </button>
                  ) : (
                    col.header
                  )}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {paginatedData.length === 0 ? (
              <tr>
                <td
                  colSpan={columns.length}
                  className="px-4 py-8 text-center text-[#505052]"
                >
                  {emptyMessage}
                </td>
              </tr>
            ) : (
              paginatedData.map((row, rowIndex) => (
                <tr
                  key={rowIndex}
                  className="border-b border-[#E8E9EA] last:border-b-0 hover:bg-[#FAF9F7] transition-colors"
                >
                  {columns.map((col) => {
                    const value = row[col.key as keyof T];
                    return (
                      <td
                        key={String(col.key)}
                        className={`px-4 py-3 text-sm text-[#1F1F1F] ${col.className || ''}`}
                      >
                        {col.render ? col.render(value, row) : String(value ?? '')}
                      </td>
                    );
                  })}
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      {/* Pagination */}
      {totalPages > 1 && (
        <div className="flex items-center justify-between mt-4">
          <p className="text-sm text-[#505052]">
            Showing {((currentPage - 1) * pageSize) + 1} to{' '}
            {Math.min(currentPage * pageSize, sortedData.length)} of{' '}
            {sortedData.length} results
          </p>
          <div className="flex items-center gap-2">
            <button
              onClick={() => setCurrentPage((p) => Math.max(1, p - 1))}
              disabled={currentPage === 1}
              className="p-2 rounded-lg border border-[#D8D9DA] hover:bg-[#F5F4F2] disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
            >
              <ChevronLeft size={16} />
            </button>
            <span className="text-sm text-[#505052]">
              Page {currentPage} of {totalPages}
            </span>
            <button
              onClick={() => setCurrentPage((p) => Math.min(totalPages, p + 1))}
              disabled={currentPage === totalPages}
              className="p-2 rounded-lg border border-[#D8D9DA] hover:bg-[#F5F4F2] disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
            >
              <ChevronRight size={16} />
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
